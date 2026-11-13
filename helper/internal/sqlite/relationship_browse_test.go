package sqlite

import (
	"context"
	"dbeer/helper/internal/protocol"
	"encoding/base64"
	"testing"
)

func TestSQLiteIncomingScopeUsesParentAffinityCollationAndExactStorage(t *testing.T) {
	s, _ := openCore(t, false)
	runCore(t, s, `CREATE TABLE integer_parent(id INTEGER PRIMARY KEY)`)
	runCore(t, s, `CREATE TABLE text_child(id INTEGER PRIMARY KEY,parent_key TEXT REFERENCES integer_parent(id))`)
	runCore(t, s, `INSERT INTO integer_parent VALUES(1)`)
	runCore(t, s, `INSERT INTO text_child VALUES(1,'001'),(2,NULL)`)
	runCore(t, s, `CREATE TABLE nocase_parent(id TEXT COLLATE NOCASE PRIMARY KEY NOT NULL)`)
	runCore(t, s, `CREATE TABLE binary_child(id INTEGER PRIMARY KEY,parent_key TEXT REFERENCES nocase_parent(id))`)
	runCore(t, s, `INSERT INTO nocase_parent VALUES('ABC')`)
	runCore(t, s, `INSERT INTO binary_child VALUES(1,'abc'),(2,NULL)`)
	runCore(t, s, `CREATE TABLE text_parent(id TEXT PRIMARY KEY NOT NULL)`)
	runCore(t, s, `CREATE TABLE integer_child(id INTEGER PRIMARY KEY,parent_key INTEGER REFERENCES text_parent(id))`)
	runCore(t, s, `INSERT INTO text_parent VALUES('01')`)
	runCore(t, s, `PRAGMA foreign_keys=OFF`)
	runCore(t, s, `INSERT INTO integer_child VALUES(1,1)`)
	runCore(t, s, `PRAGMA foreign_keys=ON`)
	runCore(t, s, `CREATE TABLE composite_parent(a INTEGER NOT NULL,b BLOB NOT NULL,PRIMARY KEY(a,b))`)
	runCore(t, s, `CREATE TABLE composite_child(id INTEGER PRIMARY KEY,x TEXT,y BLOB,FOREIGN KEY(x,y) REFERENCES composite_parent(a,b))`)
	runCore(t, s, `INSERT INTO composite_parent VALUES(9223372036854775807,X'00ff')`)
	runCore(t, s, `INSERT INTO composite_child VALUES(1,'9223372036854775807',X'00ff'),(2,NULL,X'00ff'),(3,'9223372036854775807',NULL)`)
	textValue := func(v string) protocol.SQLiteValue {
		return protocol.SQLiteValue{Type: "text", Value: base64.StdEncoding.EncodeToString([]byte(v))}
	}
	for _, test := range []struct {
		parent, child string
		columns       []protocol.SQLiteRelationshipPair
		want          int
	}{
		{"integer_parent", "text_child", []protocol.SQLiteRelationshipPair{{Source: "parent_key", Target: "id", Position: 1, Value: protocol.SQLiteValue{Type: "integer", Value: "1"}}}, 1},
		{"nocase_parent", "binary_child", []protocol.SQLiteRelationshipPair{{Source: "parent_key", Target: "id", Position: 1, Value: textValue("ABC")}}, 1},
		{"text_parent", "integer_child", []protocol.SQLiteRelationshipPair{{Source: "parent_key", Target: "id", Position: 1, Value: textValue("01")}}, 0},
		{"composite_parent", "composite_child", []protocol.SQLiteRelationshipPair{{Source: "x", Target: "a", Position: 1, Value: protocol.SQLiteValue{Type: "integer", Value: "9223372036854775807"}}, {Source: "y", Target: "b", Position: 2, Value: protocol.SQLiteValue{Type: "blob", Value: "AP8="}}}, 1},
	} {
		scope := protocol.SQLiteRelationshipScope{Child: protocol.CatalogRelationTarget{Schema: "main", Name: test.child}, Parent: protocol.CatalogRelationTarget{Schema: "main", Name: test.parent}, Name: "fk_0", Columns: test.columns}
		request := protocol.CatalogRequest{Kind: "browse", Schema: "main", Object: test.child, ObjectKind: "table", RelationshipScope: &scope}
		reply := s.Execute(context.Background(), protocol.Command{Type: "catalog", RequestID: "r", QueryID: "q", Catalog: &request})
		if reply.Type != "query.result" || len(reply.Rows) != test.want {
			t.Fatalf("parent comparison semantics failed for %s", test.child)
		}
		changed := scope
		changed.Columns = append([]protocol.SQLiteRelationshipPair{}, scope.Columns...)
		changed.Columns[0].Target = "missing"
		request.RelationshipScope = &changed
		if r := s.Execute(context.Background(), protocol.Command{Type: "catalog", RequestID: "r", QueryID: "q", Catalog: &request}); r.Type != "error" {
			t.Fatal("stale mapping was accepted")
		}
	}
}
