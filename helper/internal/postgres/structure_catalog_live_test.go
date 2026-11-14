package postgres

import (
	"context"
	"dbeer/helper/internal/tableedit"
	"fmt"
	"testing"
)

func TestStructureAdvancedCatalogOperatorsLive(t *testing.T) {
	f := newChangeFixture(t)
	ctx := context.Background()
	f.exec("CREATE SEQUENCE " + f.table("catalog_operator_calls"))
	for i, spec := range []struct{ typ, op string }{
		{"pg_catalog.name", "="}, {"pg_catalog.text", "="}, {"pg_catalog.oid", "="}, {`pg_catalog."char"`, "="},
		{"pg_catalog.int2", "="}, {"pg_catalog.int4", "="}, {"pg_catalog.int4", ">"}, {"pg_catalog.oid", "<"},
		{"pg_catalog.text", "||"},
	} {
		name := fmt.Sprintf("catalog_shadow_%d", i)
		result := "pg_catalog.bool"
		if spec.op == "||" {
			result = "pg_catalog.text"
		}
		f.exec("CREATE FUNCTION " + f.table(name) + "(" + spec.typ + "," + spec.typ + ") RETURNS " + result + " LANGUAGE plpgsql VOLATILE AS $$BEGIN PERFORM pg_catalog.nextval('" + f.schema + ".catalog_operator_calls'::pg_catalog.regclass); RETURN $1 OPERATOR(pg_catalog." + spec.op + ") $2; END$$")
		f.exec("CREATE OPERATOR " + f.schema + "." + spec.op + " (LEFTARG=" + spec.typ + ",RIGHTARG=" + spec.typ + ",FUNCTION=" + f.table(name) + ")")
	}
	f.exec("CREATE TABLE " + f.table("plain") + "(id integer,payload text)")
	f.exec("CREATE TABLE " + f.table("secured") + "(id integer,payload text)")
	f.exec("ALTER TABLE " + f.table("secured") + " ENABLE ROW LEVEL SECURITY")
	f.exec("ALTER TABLE " + f.table("secured") + " FORCE ROW LEVEL SECURITY")
	f.exec("CREATE POLICY retained ON " + f.table("secured") + " USING (id>0)")
	f.exec("CREATE TABLE " + f.table("parent") + "(id integer,payload text)")
	f.exec("CREATE TABLE " + f.table("child") + "() INHERITS (" + f.table("parent") + ")")
	f.exec("CREATE TABLE " + f.table("partition_root") + "(id integer,payload text) PARTITION BY RANGE(id)")
	f.exec("CREATE TABLE " + f.table("partition_leaf") + " PARTITION OF " + f.table("partition_root") + " FOR VALUES FROM(0) TO(100)")
	f.exec("CREATE UNLOGGED TABLE " + f.table("unlogged") + "(id integer,payload text)")
	for _, name := range []string{"plain", "secured", "child", "partition_leaf", "unlogged"} {
		f.exec("INSERT INTO " + f.table(name) + " VALUES(1,''),(2,'NULL'),(3,NULL)")
	}
	if _, err := f.conn.Exec(ctx, "SET search_path TO \""+f.schema+"\",pg_catalog"); err != nil {
		t.Fatal("fixture search path setup failed")
	}
	var path string
	if f.conn.QueryRow(ctx, "SELECT pg_catalog.current_setting('search_path')").Scan(&path) != nil {
		t.Fatal("fixture context unavailable")
	}
	var a, b, c bool
	if f.conn.QueryRow(ctx, `SELECT 'r'::pg_catalog."char" IN ('r','p'),1::pg_catalog.int4=ANY(ARRAY[1,2]),'x'::pg_catalog.name='x'::pg_catalog.name`).Scan(&a, &b, &c) != nil || !a || !b || !c {
		t.Fatal("unqualified implicit and symbolic operator positive controls failed")
	}
	var calls int64
	if f.observer.QueryRow(ctx, "SELECT last_value FROM "+f.table("catalog_operator_calls")).Scan(&calls) != nil || calls < 3 {
		t.Fatal("shadow operators did not execute positive controls")
	}
	s := &Session{conn: f.conn}
	for _, name := range []string{"plain", "secured", "parent", "child", "partition_root", "partition_leaf", "unlogged"} {
		t.Run(name, func(t *testing.T) {
			store := &tableedit.Store{}
			value := "NULL"
			authoringApply(t, s, store, tableedit.Target{Schema: f.schema, Table: name}, tableedit.Draft{AuthoringVersion: 2, Columns: []tableedit.Column{}, Changes: []tableedit.ColumnChange{{Name: "payload", Default: &tableedit.Default{Kind: "text", Value: &value}}}})
		})
	}
	var afterCalls int64
	if f.observer.QueryRow(ctx, "SELECT last_value FROM "+f.table("catalog_operator_calls")).Scan(&afterCalls) != nil || afterCalls != calls {
		t.Fatal("catalog observation or native authoring invoked a user-defined shadow operator")
	}
	var afterPath string
	if f.conn.QueryRow(ctx, "SELECT pg_catalog.current_setting('search_path')").Scan(&afterPath) != nil || afterPath != path || s.TransactionStatus() != "idle" {
		t.Fatal("catalog observation mutated search_path or transaction state")
	}
}
