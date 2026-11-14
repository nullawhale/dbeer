package mariadb

import (
	"context"
	"encoding/base64"
	"fmt"
	"strconv"
	"strings"
	"testing"
	"time"

	"dbeer/helper/internal/protocol"
	wire "github.com/go-mysql-org/go-mysql/mysql"
)

func rowCell(value string) protocol.CellValue { return protocol.CellValue{Kind: "text", Value: &value} }

func rowFixture(t *testing.T, s *Session, definition string) (string, string) {
	t.Helper()
	name := fmt.Sprintf("g1_row_%d", time.Now().UnixNano())
	qualified := QuoteIdentifier(dataIntegrationSettings(t).Database) + "." + QuoteIdentifier(name)
	dataRun(t, s, "CREATE TABLE "+qualified+definition)
	t.Cleanup(func() {
		dataRun(t, s, "DROP TEMPORARY TABLE IF EXISTS "+qualified)
		dataRun(t, s, "DROP TABLE IF EXISTS "+qualified)
	})
	return name, qualified
}

func rowRequest(t *testing.T, s *Session, name string, ids ...int) protocol.ChangesRequest {
	t.Helper()
	schema := dataIntegrationSettings(t).Database
	r, err := s.work.client.Execute(`SELECT COLUMN_NAME,COLUMN_TYPE FROM information_schema.COLUMNS WHERE BINARY TABLE_SCHEMA=BINARY ? AND BINARY TABLE_NAME=BINARY ? ORDER BY ORDINAL_POSITION`, schema, name)
	if err != nil {
		t.Fatal("native fixture columns unavailable")
	}
	request := protocol.ChangesRequest{Schema: schema, Table: name}
	for i := range r.Values {
		n, _ := r.GetString(i, 0)
		native, _ := r.GetString(i, 1)
		request.Columns = append(request.Columns, protocol.SnapshotColumn{Name: strings.Clone(n), NativeType: strings.Clone(native), Engine: "mariadb"})
	}
	r.Close()
	execution := s.newChangeExecution(context.Background())
	defer execution.finish()
	metadata, err := s.editMetadata(execution, request)
	if err != nil {
		t.Fatal("native fixture row metadata refused")
	}
	projection := []string{}
	for _, c := range metadata.columns {
		projection = append(projection, MariaDBStableProjection(c.name, c.dataType))
	}
	kinds := storageKinds(metadata)
	projection = append(projection, MariaDBStorageProjections(MariaDBStorageColumns(kinds), kinds)...)
	for _, id := range ids {
		r, err := s.work.client.Execute("SELECT "+strings.Join(projection, ",")+" FROM "+metadata.qualified+" WHERE id=?", id)
		if err != nil || r.RowNumber() != 1 {
			t.Fatal("native fixture original row unavailable")
		}
		change := protocol.RowChange{Kind: "update"}
		for i, c := range metadata.columns {
			v := r.Values[0][i]
			cell := protocol.CellValue{Kind: "null"}
			if v.Type != wire.FieldValueTypeNull {
				cell.Kind = "text"
				var value string
				if c.binary {
					cell.Kind = "binary"
					value = base64.StdEncoding.EncodeToString(v.AsString())
				} else {
					switch v.Type {
					case wire.FieldValueTypeString:
						value = string(v.AsString())
					case wire.FieldValueTypeUnsigned:
						value = strconv.FormatUint(v.AsUint64(), 10)
					case wire.FieldValueTypeSigned:
						value = strconv.FormatInt(v.AsInt64(), 10)
					case wire.FieldValueTypeFloat:
						value = strconv.FormatFloat(v.AsFloat64(), 'g', -1, 64)
					}
				}
				value = strings.Clone(value)
				cell.Value = &value
			}
			change.Original = append(change.Original, cell)
		}
		change.StorageToken, err = MariaDBStorageToken(r.Values[0][len(metadata.columns):])
		r.Close()
		if err != nil {
			t.Fatal("native fixture token unavailable")
		}
		request.Changes = append(request.Changes, change)
	}
	return request
}

func rowState(t *testing.T, s *Session) string {
	t.Helper()
	r, err := s.work.client.Execute(mariaDBWriteStateSQL)
	if err != nil {
		t.Fatal("native state observation failed")
	}
	defer r.Close()
	values := []string{}
	for i := range r.Fields {
		v, err := r.GetString(0, i)
		if err != nil {
			t.Fatal("native state observation incomplete")
		}
		values = append(values, strings.Clone(v))
	}
	return strings.Join(values, "\n")
}

func rowApply(t *testing.T, s *Session, request protocol.ChangesRequest) protocol.Response {
	t.Helper()
	return s.ExecuteChanges(context.Background(), protocol.Command{Type: "changes.apply", RequestID: "apply", SessionID: "owner", QueryID: "query", Changes: &request})
}

func TestMariaDBRowsNativeLiveExactValuesDefaultsAndState(t *testing.T) {
	s := dataIntegrationSession(t)
	name, qualified := rowFixture(t, s, "(id BIGINT AUTO_INCREMENT PRIMARY KEY,u BIGINT UNSIGNED,amount DECIMAL(65,38),payload LONGTEXT,j JSON,b VARBINARY(16),f FLOAT,d DOUBLE,t TIMESTAMP(6) NULL,e ENUM('','a'),s SET('','a'),g BIGINT AS(nn*2) PERSISTENT,n INT DEFAULT 7,nn INT NOT NULL) ENGINE=InnoDB")
	dataRun(t, s, "INSERT INTO "+qualified+"(id,u,amount,payload,j,b,f,d,t,e,s,n,nn) VALUES(1,18446744073709551615,0.12345678901234567890123456789012345678,'NULL','{\"a\":1, \"a\":2}',X'00FF',1.25,1.0000000000000002,'2024-10-27 00:30:00.123456',1,1,3,9),(2,0,NULL,'',NULL,X'',NULL,NULL,NULL,NULL,NULL,3,9)")
	dataRun(t, s, "SET SESSION sql_mode='',time_zone='Europe/Berlin',explicit_defaults_for_timestamp=0")
	before := rowState(t, s)
	request := rowRequest(t, s, name, 1)
	request.Changes[0].Values = []protocol.ColumnAssignment{{Column: "payload", Value: rowCell("")}, {Column: "n", Value: protocol.CellValue{Kind: "default"}}}
	preview := s.ExecuteChanges(context.Background(), protocol.Command{Type: "changes.preview", Changes: &request})
	if preview.Type != "query.result" || len(preview.Rows) != 1 || !strings.HasPrefix(*preview.Rows[0][1], "SET STATEMENT sql_mode='") || !strings.Contains(*preview.Rows[0][1], "time_zone='+00:00'") {
		t.Fatal("native exact row preview did not disclose bounded conversion scope")
	}
	if rowState(t, s) != before || *dataRun(t, s, "SELECT n FROM "+qualified+" WHERE id=1").Rows[0][0] != "3" {
		t.Fatal("native Preview changed data or retained session state")
	}
	if r := rowApply(t, s, request); r.Type != "query.result" || r.CommandTag != "APPLY 1" || s.TransactionStatus() != "idle" {
		if r.Category == "validation" {
			t.Fatal("native exact row Apply refused: " + r.Message)
		}
		t.Fatalf("native exact row Apply failed: %s/%s", r.Category, r.SQLState)
	}
	if rowState(t, s) != before {
		t.Fatal("native Apply retained changed conversion settings")
	}
	actual := dataRun(t, s, "SELECT u,amount,payload,j,HEX(b),g,n,nn FROM "+qualified+" WHERE id=1")
	expected := []string{"18446744073709551615", "0.12345678901234567890123456789012345678", "", "{\"a\":1, \"a\":2}", "00FF", "18", "7", "9"}
	for i, value := range expected {
		if actual.Rows[0][i] == nil || *actual.Rows[0][i] != value {
			t.Fatal("native Apply changed an exact retained or assigned value")
		}
	}
	request = rowRequest(t, s, name, 1)
	request.Changes[0].Values = []protocol.ColumnAssignment{{Column: "nn", Value: protocol.CellValue{Kind: "null"}}}
	if r := rowApply(t, s, request); r.Type != "error" || r.Category != "validation" || rowState(t, s) != before {
		t.Fatal("nonnullable NULL was coerced instead of refused")
	}
	request = rowRequest(t, s, name)
	request.Changes = []protocol.RowChange{{Kind: "insert", Values: []protocol.ColumnAssignment{{Column: "id", Value: rowCell("0")}, {Column: "nn", Value: rowCell("4")}}}}
	if r := rowApply(t, s, request); r.Type != "query.result" || *dataRun(t, s, "SELECT COUNT(*) FROM "+qualified+" WHERE id=0").Rows[0][0] != "1" {
		t.Fatal("explicit zero auto-increment key was silently generated instead")
	}
}

func TestMariaDBRowsNativeLiveConflictRollbackAndOwner(t *testing.T) {
	s, other := dataIntegrationSession(t), dataIntegrationSession(t)
	name, qualified := rowFixture(t, s, "(id INT PRIMARY KEY,payload VARCHAR(4),n TINYINT NOT NULL) ENGINE=InnoDB")
	dataRun(t, s, "INSERT INTO "+qualified+" VALUES(1,'one',1),(2,'two',2)")
	before := rowState(t, s)
	stale := rowRequest(t, s, name, 1)
	stale.Changes[0].Values = []protocol.ColumnAssignment{{Column: "n", Value: rowCell("3")}}
	dataRun(t, other, "UPDATE "+qualified+" SET payload='late' WHERE id=1")
	if r := rowApply(t, s, stale); r.Category != "conflict" || s.TransactionStatus() != "idle" {
		t.Fatal("changed original row did not refuse atomically")
	}
	batch := rowRequest(t, s, name, 1, 2)
	batch.Changes[0].Values = []protocol.ColumnAssignment{{Column: "n", Value: rowCell("4")}}
	batch.Changes[1].Values = []protocol.ColumnAssignment{{Column: "n", Value: rowCell("999")}}
	if r := rowApply(t, s, batch); r.Type != "error" || r.OutcomeUnknown || s.TransactionStatus() != "idle" {
		t.Fatal("invalid late row did not produce acknowledged rollback")
	}
	if *dataRun(t, s, "SELECT SUM(n) FROM "+qualified).Rows[0][0] != "3" || rowState(t, s) != before {
		t.Fatal("late invalid row retained an earlier write or changed session settings")
	}
	dataRun(t, s, "BEGIN")
	if r := rowApply(t, s, stale); r.Category != "validation" || s.TransactionStatus() != "transaction" {
		t.Fatal("row Apply used an existing SQL-tab transaction")
	}
	dataRun(t, s, "ROLLBACK")
}

func TestMariaDBRowsNativeLiveStorageDriftAndTargetRefusal(t *testing.T) {
	s, other := dataIntegrationSession(t), dataIntegrationSession(t)
	name, qualified := rowFixture(t, s, "(id INT PRIMARY KEY,payload VARCHAR(10),e ENUM('','a'),s SET('','a'),f FLOAT,d DOUBLE,t TIMESTAMP(6) NULL) ENGINE=InnoDB")
	dataRun(t, s, "SET SESSION sql_mode='',time_zone='+00:00'")
	dataRun(t, s, "INSERT INTO "+qualified+" VALUES(1,'retained',0,0,1.25,1.25,'2024-10-27 00:30:00.123456')")
	for _, assignment := range []string{"e=1", "s=1", "f=1.25000011920928955078125", "d=1.2500000000000002", "t='2024-10-27 01:30:00.123456'"} {
		request := rowRequest(t, s, name, 1)
		request.Changes[0].Values = []protocol.ColumnAssignment{{Column: "payload", Value: rowCell("changed")}}
		dataRun(t, other, "UPDATE "+qualified+" SET "+assignment+" WHERE id=1")
		if r := rowApply(t, s, request); r.Category != "conflict" || r.OutcomeUnknown {
			t.Fatal("changed native ordinal/mask/float/instant did not invalidate the original storage witness")
		}
		if *dataRun(t, s, "SELECT payload FROM "+qualified).Rows[0][0] != "retained" {
			t.Fatal("a stale native storage witness overwrote its row")
		}
	}
	request := rowRequest(t, s, name, 1)
	request.Changes[0].Values = []protocol.ColumnAssignment{{Column: "payload", Value: rowCell("shadow")}}
	dataRun(t, s, "CREATE TEMPORARY TABLE "+qualified+"(id INT PRIMARY KEY,payload VARCHAR(10)) ENGINE=InnoDB")
	dataRun(t, s, "INSERT INTO "+qualified+"(id,payload) VALUES(1,'temporary')")
	if r := rowApply(t, s, request); r.Category != "validation" || *dataRun(t, s, "SELECT payload FROM "+qualified).Rows[0][0] != "temporary" {
		t.Fatal("permanent metadata authorized a session-local temporary shadow")
	}
	dataRun(t, s, "DROP TEMPORARY TABLE "+qualified)
	for _, engine := range []string{"MyISAM", "Aria"} {
		dataRun(t, s, "ALTER TABLE "+qualified+" ENGINE="+engine)
		if r := rowApply(t, s, request); r.Category != "validation" || !strings.Contains(r.Message, "Nontransactional") {
			t.Fatal("nontransactional storage was promised atomic batch rollback")
		}
	}
}

func TestMariaDBRowsNativeLiveLegacyTimestampNullIsRefused(t *testing.T) {
	s := dataIntegrationSession(t)
	dataRun(t, s, "SET SESSION explicit_defaults_for_timestamp=0")
	name, qualified := rowFixture(t, s, "(id INT PRIMARY KEY,t TIMESTAMP(6) NOT NULL) ENGINE=InnoDB")
	dataRun(t, s, "INSERT INTO "+qualified+" VALUES(1,'2024-01-01 01:02:03.123456')")
	request := rowRequest(t, s, name, 1)
	request.Changes[0].Values = []protocol.ColumnAssignment{{Column: "t", Value: protocol.CellValue{Kind: "null"}}}
	before := rowState(t, s)
	if r := rowApply(t, s, request); r.Category != "validation" || rowState(t, s) != before || *dataRun(t, s, "SELECT t FROM "+qualified).Rows[0][0] != "2024-01-01 01:02:03.123456" {
		t.Fatal("legacy nonnullable TIMESTAMP NULL was converted into an unrequested automatic value")
	}
}
