package mariadb

import (
	"context"
	"fmt"
	"strings"
	"testing"
	"time"

	"dbeer/helper/internal/protocol"
	"dbeer/helper/internal/resultsource"
	wire "github.com/go-mysql-org/go-mysql/mysql"
)

func TestMariaDBSourceNativeOriginUsesEveryKeyAndColumn(t *testing.T) {
	selection, reason := resultsource.Parse("SELECT t.* FROM `fixture`.`items` t WHERE id=1", "mariadb")
	if reason != "" {
		t.Fatal("native provenance grammar rejected simple select")
	}
	for _, sql := range []string{"SELECT * FROM fixture.items /*M! UNION SELECT * FROM fixture.other */", "SELECT * FROM fixture.items JOIN fixture.other USING(id)", "SELECT id+1 FROM fixture.items"} {
		if _, reason := resultsource.Parse(sql, "mariadb"); reason == "" {
			t.Fatal("ambiguous or executable provenance accepted")
		}
	}
	fields := []*wire.Field{{Schema: []byte("fixture"), OrgTable: []byte("items"), OrgName: []byte("id"), Type: wire.MYSQL_TYPE_LONG, Charset: 63}, {Schema: []byte("fixture"), OrgTable: []byte("items"), OrgName: []byte("payload"), Type: wire.MYSQL_TYPE_VAR_STRING, Charset: 45}}
	schema, table, ok := mariadbResultOrigin(selection, fields)
	if !ok || schema != "fixture" || table != "items" {
		t.Fatal("native origin changed")
	}
	source := mariadbSourceForFields(schema, table, fields, []mariadbSourceColumn{{name: "id", nativeType: "int(11)", dataType: "int", primaryKey: 1}, {name: "payload", nativeType: "varchar(40)", dataType: "varchar"}})
	if source.Schema != "fixture" || source.Table != "items" || len(source.Columns) != 2 || source.Columns[0].PrimaryKey != 1 || source.ReadOnlyReason == "" || source.Columns[1].Editable {
		t.Fatal("read-only SQL provenance lost its exact identity or exposed deferred editing")
	}
	fields[1].OrgName = []byte("id")
	if s := mariadbSourceForFields(schema, table, fields, []mariadbSourceColumn{{name: "id", nativeType: "int(11)", dataType: "int", primaryKey: 1}, {name: "payload", nativeType: "varchar(40)", dataType: "varchar"}}); len(s.Columns) != 0 || s.ReadOnlyReason == "" {
		t.Fatal("repeated wire origin accepted")
	}
}
func TestMariaDBSourceNativeLiveRowsAndTemporaryShadow(t *testing.T) {
	s := dataIntegrationSession(t)
	settings := dataIntegrationSettings(t)
	name := fmt.Sprintf("g1_origin_%d", time.Now().UnixNano())
	qualified := QuoteIdentifier(settings.Database) + "." + QuoteIdentifier(name)
	dataRun(t, s, "CREATE TABLE "+qualified+"(id INT PRIMARY KEY,payload VARCHAR(40),amount DECIMAL(65,38),j JSON,derived INT AS(id*2) PERSISTENT) ENGINE=InnoDB")
	t.Cleanup(func() {
		dataRun(t, s, "DROP TEMPORARY TABLE IF EXISTS "+qualified)
		dataRun(t, s, "DROP TABLE IF EXISTS "+qualified)
	})
	dataRun(t, s, "INSERT INTO "+qualified+"(id,payload,amount,j) VALUES(1,'NULL',0.12345678901234567890123456789012345678,'{\"a\":1, \"a\":2}'),(2,'',NULL,NULL)")
	read := func(sql string) protocol.Response {
		t.Helper()
		r := s.Execute(context.Background(), protocol.Command{Type: "execute", SQL: sql})
		if r.Type != "query.result" {
			t.Fatalf("native provenance failed: %s/%s", r.Category, r.SQLState)
		}
		return r
	}
	observed := read("SELECT t.* FROM " + qualified + " t ORDER BY id")
	if len(observed.Rows) != 2 || observed.Source == nil || observed.Source.Schema != settings.Database || observed.Source.Table != name || len(observed.Source.Columns) != 5 || observed.Source.Columns[0].PrimaryKey != 1 || !observed.Source.Columns[4].Generated || observed.Source.ReadOnlyReason == "" {
		t.Fatal("nonempty native SQL result lost exact source facts or exposed deferred editing")
	}
	request := protocol.ChangesRequest{Schema: settings.Database, Table: name, Columns: []protocol.SnapshotColumn{}, Changes: []protocol.RowChange{{Kind: "update", Original: []protocol.CellValue{}, Values: []protocol.ColumnAssignment{{Column: "payload", Value: rowCell("")}}}}}
	for i, column := range observed.Source.Columns {
		request.Columns = append(request.Columns, protocol.SnapshotColumn{Name: column.Name, NativeType: column.NativeType, Engine: "mariadb"})
		cell := protocol.CellValue{Kind: "null"}
		if observed.Rows[0][i] != nil {
			cell.Kind = "text"
			cell.Value = observed.Rows[0][i]
			if observed.Columns[i].Encoding == "base64" {
				cell.Kind = "binary"
			}
		}
		request.Changes[0].Original = append(request.Changes[0].Original, cell)
	}
	applied := s.ExecuteChanges(context.Background(), protocol.Command{Type: "changes.apply", Changes: &request})
	if applied.Type != "query.result" {
		t.Fatalf("native provenance original did not reach reviewed row implementation: %s/%s", applied.Category, applied.SQLState)
	}
	retained := read("SELECT * FROM " + qualified + " ORDER BY id")
	if retained.Rows[0][1] == nil || *retained.Rows[0][1] != "" || retained.Rows[0][2] == nil || *retained.Rows[0][2] != "0.12345678901234567890123456789012345678" || retained.Rows[0][3] == nil || *retained.Rows[0][3] != "{\"a\":1, \"a\":2}" {
		t.Fatal("native source-row edit changed retained exact values")
	}
	projected := read("SELECT payload FROM " + qualified)
	if projected.Source == nil || projected.Source.Table != "" || projected.Source.ReadOnlyReason == "" {
		t.Fatal("incomplete key authorized source row")
	}
	for _, setting := range []string{"character_set_client", "character_set_connection", "character_set_results"} {
		dataRun(t, s, "SET SESSION "+setting+"=latin1")
		encoded := read("SELECT * FROM " + qualified)
		if encoded.Source == nil || encoded.Source.Table != "" || !strings.Contains(encoded.Source.ReadOnlyReason, "utf8mb4") {
			t.Fatal("changed source metadata encoding retained provenance authority")
		}
		dataRun(t, s, "SET SESSION "+setting+"=utf8mb4")
	}
	dataRun(t, s, "CREATE TEMPORARY TABLE "+qualified+"(id INT PRIMARY KEY,payload VARCHAR(40))")
	dataRun(t, s, "INSERT INTO "+qualified+" VALUES(99,'temporary')")
	shadow := read("SELECT * FROM " + qualified)
	if len(shadow.Rows) != 1 || shadow.Source == nil || shadow.Source.Table != "" || !strings.Contains(shadow.Source.ReadOnlyReason, "Temporary") {
		t.Fatal("permanent catalog authorized another session's temporary shadow")
	}
}
