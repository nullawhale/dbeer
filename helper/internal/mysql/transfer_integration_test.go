package mysql

import (
	"context"
	"encoding/base64"
	"fmt"
	"io"
	"math"
	"strconv"
	"testing"
	"time"

	dt "dbeer/helper/internal/datatransfer"
	"dbeer/helper/internal/protocol"
)

func transferText(value string) protocol.CellValue {
	return protocol.CellValue{Kind: "text", Value: &value}
}
func transferRows(rows [][]protocol.CellValue) dt.RowReader {
	index := 0
	return func() ([]protocol.CellValue, error) {
		if index == len(rows) {
			return nil, io.EOF
		}
		row := rows[index]
		index++
		return row, nil
	}
}
func TestMySQLTransferCreatesExactRowsAndReportsCommittedEmptyTableOnFailure(t *testing.T) {
	session := integrationSession(t)
	settings := integrationSettings(t)
	ctx, cancel := context.WithTimeout(context.Background(), 10*time.Second)
	defer cancel()
	table := fmt.Sprintf("dbeer_transfer_%d", time.Now().UnixNano())
	defer run(t, session, "DROP TABLE IF EXISTS "+QuoteIdentifier(table))
	defer run(t, session, "DROP TABLE IF EXISTS "+QuoteIdentifier(table+"_failed"))
	columns := []protocol.TransferColumn{{SourceIndex: 0, Name: "exact", Type: "integer"}, {SourceIndex: 1, Name: "payload", Type: "binary"}, {SourceIndex: 2, Name: "note", Type: "text", Nullable: true}, {SourceIndex: 3, Name: "enabled", Type: "boolean"}}
	_, identity, err := session.TransferPreview(ctx, settings.Database, table, columns)
	if err != nil {
		t.Fatal("typed MySQL preview failed")
	}
	binary := base64.StdEncoding.EncodeToString([]byte{0, 0xff})
	rows := [][]protocol.CellValue{{transferText("9007199254740993"), {Kind: "binary", Value: &binary}, transferText(""), transferText("true")}, {transferText("-1"), {Kind: "binary", Value: &binary}, {Kind: "null"}, transferText("false")}}
	out, err := session.TransferApply(ctx, settings.Database, table, identity, columns, transferRows(rows), func(int64) {})
	if err != nil || !out.TableCreated || out.Rows != 2 || out.OutcomeUnknown {
		t.Fatal("typed MySQL table creation failed")
	}
	result, err := session.work.client.Execute("SELECT CAST(exact AS CHAR),HEX(payload),LENGTH(note),enabled FROM " + QuoteIdentifier(table) + " WHERE note IS NOT NULL")
	if err != nil {
		t.Fatal("cannot inspect typed MySQL fixture")
	}
	defer result.Close()
	exact, _ := result.GetString(0, 0)
	payload, _ := result.GetString(0, 1)
	length, _ := result.GetInt(0, 2)
	enabled, _ := result.GetInt(0, 3)
	if exact != "9007199254740993" || payload != "00FF" || length != 0 || enabled != 1 {
		t.Fatal("MySQL converted exact numeric, binary, empty text or boolean values")
	}
	if _, _, err = session.TransferPreview(ctx, settings.Database, table, columns); err == nil {
		t.Fatal("existing MySQL table could be overwritten")
	}
	failed := integrationSession(t)
	_, identity, err = failed.TransferPreview(ctx, settings.Database, table+"_failed", columns)
	if err != nil {
		t.Fatal("cannot prepare failed-rows fixture")
	}
	bad := [][]protocol.CellValue{{transferText("1"), {Kind: "binary", Value: &binary}, {Kind: "null"}, transferText("true")}, {transferText("bad"), {Kind: "binary", Value: &binary}, {Kind: "null"}, transferText("false")}}
	out, err = failed.TransferApply(ctx, settings.Database, table+"_failed", identity, columns, transferRows(bad), func(int64) {})
	if err == nil || !out.TableCreated || out.OutcomeUnknown {
		t.Fatal("implicit CREATE commit was hidden or falsely uncertain")
	}
	// The owner always closes a failed dedicated apply session. Closing rolls
	// back its uncommitted InnoDB rows while preserving the committed new table.
	failed.Close()
	result, err = session.work.client.Execute("SELECT COUNT(*) FROM " + QuoteIdentifier(table+"_failed"))
	if err != nil {
		t.Fatal("failed MySQL CREATE was not retained")
	}
	defer result.Close()
	count, _ := result.GetInt(0, 0)
	if count != 0 {
		t.Fatal("failed MySQL transfer committed partial rows")
	}
}
func TestMySQLTransferSnapshotPreservesUnsignedAndNoKeyTables(t *testing.T) {
	session := integrationSession(t)
	settings := integrationSettings(t)
	ctx, cancel := context.WithTimeout(context.Background(), 10*time.Second)
	defer cancel()
	table := fmt.Sprintf("dbeer_transfer_source_%d", time.Now().UnixNano())
	defer run(t, session, "DROP TABLE IF EXISTS "+QuoteIdentifier(table))
	run(t, session, "CREATE TABLE "+QuoteIdentifier(table)+" (id BIGINT UNSIGNED,note LONGTEXT,payload LONGBLOB,created TIMESTAMP(6)) ENGINE=InnoDB")
	run(t, session, "INSERT INTO "+QuoteIdentifier(table)+" VALUES (18446744073709551615,'NULL',X'00FF','2026-01-01 12:00:00'),(NULL,'',NULL,NULL)")
	description, err := session.TransferDescribe(ctx, settings.Database, table)
	if err != nil {
		t.Fatal("no-key MySQL table was not describable")
	}
	var rows [][]protocol.CellValue
	_, err = session.TransferCapture(ctx, settings.Database, table, description.Digest, func(row []protocol.CellValue) error { rows = append(rows, row); return nil })
	if err != nil || len(rows) != 2 || *rows[0][0].Value != "18446744073709551615" || rows[0][2].Kind != "binary" || rows[1][0].Kind != "null" || *rows[1][1].Value != "" {
		t.Fatal("MySQL source capture changed exact values or null/empty distinctions")
	}
}

func TestMySQLTransferFloatingZeroMatchesStoredBinaryValue(t *testing.T) {
	session := integrationSession(t)
	settings := integrationSettings(t)
	ctx, cancel := context.WithTimeout(context.Background(), 10*time.Second)
	defer cancel()
	table := fmt.Sprintf("dbeer_transfer_zero_%d", time.Now().UnixNano())
	defer run(t, session, "DROP TABLE IF EXISTS "+QuoteIdentifier(table))
	run(t, session, "CREATE TABLE "+QuoteIdentifier(table)+" (value DOUBLE) ENGINE=InnoDB")
	insert, err := session.work.client.Execute("INSERT INTO "+QuoteIdentifier(table)+" VALUES (?)", math.Copysign(0, -1))
	if err != nil {
		t.Fatal("cannot bind floating zero fixture")
	}
	insert.Close()
	statement, err := session.work.client.Prepare("SELECT value FROM " + QuoteIdentifier(table))
	if err != nil {
		t.Fatal("cannot inspect stored floating zero")
	}
	result, err := statement.Execute()
	if err != nil {
		t.Fatal("cannot read binary floating zero")
	}
	stored, err := result.GetFloat(0, 0)
	result.Close()
	statement.Close()
	if err != nil {
		t.Fatal("invalid floating zero fixture")
	}
	description, err := session.TransferDescribe(ctx, settings.Database, table)
	if err != nil {
		t.Fatal("cannot describe floating zero fixture")
	}
	var copied float64
	_, err = session.TransferCapture(ctx, settings.Database, table, description.Digest, func(row []protocol.CellValue) error {
		if len(row) != 1 || row[0].Value == nil {
			return dt.ErrInvalid
		}
		var e error
		copied, e = strconv.ParseFloat(*row[0].Value, 64)
		return e
	})
	if err != nil || math.Float64bits(copied) != math.Float64bits(stored) {
		t.Fatal("floating zero copy differed from the stored binary value")
	}
}
