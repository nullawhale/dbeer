package mariadb

import (
	"context"
	"fmt"
	"strings"
	"testing"
	"time"

	"dbeer/helper/internal/protocol"
)

func TestMariaDBCatalogNativeObjectsDefaultsIndexesAndForeignKeysLive(t *testing.T) {
	s := dataIntegrationSession(t)
	settings := dataIntegrationSettings(t)
	prefix := fmt.Sprintf("g1_catalog_%d", time.Now().UnixNano())
	base, owner, view, sequence := prefix+"_base", prefix+"_owner", prefix+"_view", prefix+"_sequence"
	q := QuoteIdentifier
	for _, statement := range []string{
		"CREATE TABLE " + q(base) + "(id INT PRIMARY KEY,n INT,amount DECIMAL(65,38) DEFAULT 0.12345678901234567890123456789012345678,payload VARCHAR(40) DEFAULT 'NULL',json_payload JSON,derived INT GENERATED ALWAYS AS(n*2) PERSISTENT,CONSTRAINT " + q(prefix+"_json") + " CHECK(JSON_VALID(json_payload)),UNIQUE KEY pair_key(id,n),KEY ignored_key(n DESC)) ENGINE=InnoDB",
		"ALTER TABLE " + q(base) + " ALTER INDEX ignored_key IGNORED",
		"CREATE TABLE " + q(owner) + "(a INT,b INT,CONSTRAINT " + q(prefix+"_fk") + " FOREIGN KEY(a,b) REFERENCES " + q(base) + "(id,n)) ENGINE=InnoDB",
		"CREATE VIEW " + q(view) + " AS SELECT id,n FROM " + q(base),
		"CREATE SEQUENCE " + q(sequence) + " START WITH 7 INCREMENT BY 3",
	} {
		dataRun(t, s, statement)
	}
	t.Cleanup(func() {
		for _, statement := range []string{"DROP VIEW IF EXISTS " + q(view), "DROP TABLE IF EXISTS " + q(owner), "DROP TABLE IF EXISTS " + q(base), "DROP SEQUENCE IF EXISTS " + q(sequence)} {
			dataRun(t, s, statement)
		}
	})
	before := dataRun(t, s, "SELECT @@sql_mode,@@time_zone")
	read := func(kind, object, objectKind string) protocol.Response {
		t.Helper()
		r := s.Execute(context.Background(), protocol.Command{Type: "catalog", RequestID: "catalog", Catalog: &protocol.CatalogRequest{Kind: kind, Schema: settings.Database, Object: object, ObjectKind: objectKind}})
		if r.Type != "query.result" {
			t.Fatalf("native catalog read failed: kind=%s category=%s SQLSTATE=%s", kind, r.Category, r.SQLState)
		}
		if r.DisplayNotice != "" {
			t.Fatal("native catalog observation was incomplete")
		}
		return r
	}
	find := func(r protocol.Response, name string) []*string {
		t.Helper()
		for _, row := range r.Rows {
			if len(row) > 0 && row[0] != nil && *row[0] == name {
				return row
			}
		}
		t.Fatal("native catalog object was not returned")
		return nil
	}
	for _, test := range []struct{ kind, name string }{{"table", base}, {"view", view}, {"sequence", sequence}} {
		row := find(read("objects", "", test.kind), test.name)
		if len(row) != 4 || row[1] == nil || *row[1] != test.kind || row[3] == nil || *row[3] != test.name {
			t.Fatal("native object identity/kind was changed")
		}
		definition := read("definition", test.name, test.kind)
		if len(definition.Rows) != 1 || len(definition.Rows[0]) != 2 || definition.Rows[0][1] == nil || !strings.Contains(*definition.Rows[0][1], test.name) {
			t.Fatal("native definition missing")
		}
	}
	columns := read("columns", base, "table")
	payload := find(columns, "payload")
	if payload[3] == nil || *payload[3] != "'NULL'" {
		t.Fatal("native text NULL default was conflated with SQL NULL")
	}
	derived := find(columns, "derived")
	if derived[4] == nil || *derived[4] == "" {
		t.Fatal("native generated expression was omitted")
	}
	amount := find(columns, "amount")
	if amount[1] == nil || !strings.EqualFold(*amount[1], "decimal(65,38)") {
		t.Fatal("native decimal type scale changed")
	}
	index := find(read("indexes", base, "table"), "ignored_key")
	if index[2] == nil || !strings.Contains(*index[2], "IGNORED") || !strings.Contains(*index[2], " DESC") {
		t.Fatal("native ignored/descending index properties were omitted")
	}
	foreign := read("foreignKeys", owner, "table")
	if len(foreign.Rows) != 2 || *foreign.Rows[0][3] != "a" || *foreign.Rows[0][4] != "id" || *foreign.Rows[0][5] != "1" || *foreign.Rows[1][3] != "b" || *foreign.Rows[1][4] != "n" || *foreign.Rows[1][5] != "2" {
		t.Fatal("composite foreign-key order/group changed")
	}
	referencing := read("referencingTables", base, "table")
	if len(referencing.Rows) != 1 || len(referencing.Rows[0]) != 3 || referencing.Rows[0][1] == nil || *referencing.Rows[0][1] != owner {
		t.Fatal("incoming composite foreign key owner was lost or duplicated")
	}
	find(read("constraints", base, "table"), prefix+"_json")

	dataRun(t, s, "INSERT INTO "+q(base)+"(id,n,amount,payload,json_payload) VALUES(1,2,123456789012345678901234567.12345678901234567890123456789012345678,'NULL','{\"a\":1,\"a\":2}'),(2,3,NULL,'',NULL),(3,NULL,-0.00000000000000000000000000000000000001,NULL,'null')")
	browsed := s.Execute(context.Background(), protocol.Command{Type: "catalog", RequestID: "browse", Catalog: &protocol.CatalogRequest{Kind: "browse", Schema: settings.Database, Object: base, ObjectKind: "table", Sort: []protocol.CatalogSort{{Column: "id", Direction: "desc"}}}})
	if browsed.Type != "query.result" || len(browsed.Rows) != 3 || *browsed.Rows[0][0] != "3" || *browsed.Rows[2][0] != "1" || browsed.Source == nil || browsed.Source.ReadOnlyReason == "" {
		t.Fatal("native readonly browse lost exact ordering or implied editable source authority")
	}
	if browsed.Rows[0][3] != nil || browsed.Rows[1][3] == nil || *browsed.Rows[1][3] != "" || browsed.Rows[2][3] == nil || *browsed.Rows[2][3] != "NULL" || *browsed.Rows[2][2] != "123456789012345678901234567.12345678901234567890123456789012345678" || *browsed.Rows[2][4] != "{\"a\":1,\"a\":2}" {
		t.Fatal("browse changed NULL, empty, textNULL, decimal or native JSON text")
	}
	if !protocol.NativeMatrixValid(browsed.NativeValues, 3, len(browsed.Columns)) {
		t.Fatal("browse native envelope is invalid")
	}
	after := dataRun(t, s, "SELECT @@sql_mode,@@time_zone")
	for i := range before.Rows[0] {
		if before.Rows[0][i] == nil || after.Rows[0][i] == nil || *before.Rows[0][i] != *after.Rows[0][i] {
			t.Fatal("catalog reads changed existing session settings")
		}
	}
}
