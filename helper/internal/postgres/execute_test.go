package postgres

import (
	"encoding/json"
	"strings"
	"testing"
	"time"
	"unicode/utf8"

	"dbeer/helper/internal/protocol"
	"github.com/jackc/pgx/v5/pgconn"
)

func TestResultBudgetUsesEscapedJSONAndPreservesOutcome(t *testing.T) {
	command := protocol.Command{RequestID: strings.Repeat("r", protocol.MaxIDBytes), SessionID: strings.Repeat("s", protocol.MaxIDBytes), QueryID: strings.Repeat("q", protocol.MaxIDBytes)}
	fields := []pgconn.FieldDescription{{Name: "escaped <field>", DataTypeOID: 25}}
	collector := newResultCollector(command, fields, MaxResultBytes)
	// HTML characters occupy six bytes each in encoding/json, despite being
	// single-byte PostgreSQL text. Prefix storage must use the encoded size.
	value := []byte(strings.Repeat("<\n\"\\", 220_000))
	for range 10 {
		collector.add([][]byte{value})
	}
	response := collector.finish(pgconn.NewCommandTag("SELECT 10"), 123456789*time.Nanosecond, "transaction")
	frame, err := json.Marshal(response)
	if err != nil || len(frame) > MaxResultBytes || !response.Truncated || len(response.Rows) == 0 || len(response.Rows) >= 10 {
		t.Fatal("escaped JSON result did not respect its complete-message budget")
	}
	if response.RowCount != 10 || response.CommandTag != "SELECT 10" || response.TransactionStatus != "transaction" || response.DisplayedRowCount != len(response.Rows) {
		t.Fatal("display truncation changed the command outcome")
	}
	if *response.Rows[0][0] != string(value) {
		t.Fatal("saved text was changed")
	}
}

func TestResultOversizedRowAndMetadataHaveCompactSuccess(t *testing.T) {
	command := protocol.Command{RequestID: "r", SessionID: "s", QueryID: "q"}
	for _, metadata := range []bool{false, true} {
		name := "x"
		value := []byte(strings.Repeat("<", MaxResultBytes/6+1))
		if metadata {
			name = string(value)
			value = []byte("small")
		}
		collector := newResultCollector(command, []pgconn.FieldDescription{{Name: name, DataTypeOID: 25}}, MaxResultBytes)
		collector.add([][]byte{value})
		// Once one row does not fit, the saved result remains a prefix.
		collector.add([][]byte{[]byte("later small row")})
		response := collector.finish(pgconn.NewCommandTag("SELECT 2"), time.Millisecond, "idle")
		frame, err := json.Marshal(response)
		if err != nil || len(frame) > MaxResultBytes || !response.Truncated || len(response.Rows) != 0 || response.DisplayNotice == "" || response.RowCount != 2 || response.Type != "query.result" {
			t.Fatal("oversized display did not produce a compact successful outcome")
		}
		if metadata && len(response.Columns) != 0 {
			t.Fatal("oversized metadata was retained")
		}
	}
}

func TestResultRowLimitAndCopiedText(t *testing.T) {
	collector := newResultCollector(protocol.Command{RequestID: "r"}, []pgconn.FieldDescription{{Name: "x"}, {Name: "x"}}, MaxResultBytes)
	value := []byte("original")
	for range MaxResultRows + 5 {
		collector.add([][]byte{value, nil})
	}
	copy(value, "modified")
	response := collector.finish(pgconn.NewCommandTag("SELECT 1005"), 0, "idle")
	if len(response.Rows) != MaxResultRows || !response.Truncated || response.RowCount != 1005 || response.Rows[0][1] != nil || *response.Rows[0][0] != "original" || len(response.Columns) != 2 {
		t.Fatal("row limit, duplicate columns, nulls, or buffer ownership changed")
	}
}

func TestCopyGuardOnlyChecksInitialSQLKeyword(t *testing.T) {
	for sql, expected := range map[string]bool{
		"COPY t FROM STDIN":               true,
		"; /*empty*/ ; COPY t FROM STDIN": true,
		"-- comment\rCOPY t FROM STDIN":   true,
		"-- comment\r\nCOPY t FROM STDIN": true,
		" \n-- comment\n/* outer /* nested */ comment */ CoPy (SELECT 1) TO STDOUT": true,
		"copy\tt FROM STDIN":                   true,
		"COPY/*comment*/t FROM STDIN":          true,
		"SELECT 'COPY t FROM STDIN; SELECT 1'": false,
		"-- COPY t FROM STDIN\nSELECT 1":       false,
		"-- COPY t FROM STDIN\rSELECT 1":       false,
		"/* COPY */ SELECT $$COPY$$":           false,
		"/* unterminated COPY":                 false,
		"-- COPY":                              false,
		"copying":                              false,
		"copy_name":                            false,
		"copy$foo":                             false,
		"copyé":                                false,
		"\"copy\"":                             false,
		"":                                     false,
	} {
		if startsWithCopy(sql) != expected {
			t.Errorf("wrong COPY classification for %q", sql)
		}
	}
}

func TestSQLDiagnosticIsBoundedValidUTF8(t *testing.T) {
	message := boundedDiagnostic(strings.Repeat("é<\n", 100_000))
	frame, err := json.Marshal(protocol.Response{Type: "error", RequestID: "r", Category: "sql", Message: message})
	if !utf8.ValidString(message) || len(message) > 4100 || err != nil || len(frame) > MaxResultBytes {
		t.Fatal("server diagnostic is not bounded valid JSON")
	}
}
