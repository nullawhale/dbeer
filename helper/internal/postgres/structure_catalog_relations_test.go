package postgres

import (
	"context"
	"dbeer/helper/internal/tableedit"
	"testing"
)

func TestStructureAdvancedCatalogRelationShadowsLive(t *testing.T) {
	f := newChangeFixture(t)
	ctx := context.Background()
	f.exec("CREATE TABLE " + f.table("relation_shadow") + "(id integer,payload text)")
	f.exec("ALTER TABLE " + f.table("relation_shadow") + " ENABLE ROW LEVEL SECURITY")
	f.exec("CREATE INDEX relation_shadow_idx ON " + f.table("relation_shadow") + "((id+1)) WHERE id>0")
	f.exec("INSERT INTO " + f.table("relation_shadow") + " VALUES(1,''),(2,'NULL'),(3,NULL)")
	f.exec("CREATE SEQUENCE " + f.table("relation_shadow_calls"))
	f.exec("CREATE FUNCTION " + f.table("relation_shadow_rows") + "() RETURNS SETOF pg_catalog.pg_operator LANGUAGE plpgsql VOLATILE AS $$BEGIN PERFORM pg_catalog.nextval('" + f.schema + ".relation_shadow_calls'::pg_catalog.regclass); RETURN QUERY SELECT * FROM pg_catalog.pg_operator; END$$")
	f.exec("CREATE VIEW " + f.table("pg_operator") + " AS SELECT * FROM " + f.table("relation_shadow_rows") + "()")
	f.exec("CREATE OPERATOR CLASS " + f.table("shadow_int4_ops") + " FOR TYPE pg_catalog.int4 USING btree AS OPERATOR 1 pg_catalog.<(pg_catalog.int4,pg_catalog.int4),OPERATOR 2 pg_catalog.<=(pg_catalog.int4,pg_catalog.int4),OPERATOR 3 pg_catalog.=(pg_catalog.int4,pg_catalog.int4),OPERATOR 4 pg_catalog.>=(pg_catalog.int4,pg_catalog.int4),OPERATOR 5 pg_catalog.>(pg_catalog.int4,pg_catalog.int4),FUNCTION 1 pg_catalog.btint4cmp(pg_catalog.int4,pg_catalog.int4)")
	if _, err := f.conn.Exec(ctx, "SET search_path TO \""+f.schema+"\",pg_catalog"); err != nil {
		t.Fatal("fixture context setup failed")
	}
	var path string
	if f.conn.QueryRow(ctx, "SELECT pg_catalog.current_setting('search_path')").Scan(&path) != nil {
		t.Fatal("fixture context unavailable")
	}
	var count int
	if f.conn.QueryRow(ctx, "SELECT pg_catalog.count(*) FROM pg_operator").Scan(&count) != nil || count == 0 {
		t.Fatal("unqualified relation positive control did not read the shadow view")
	}
	var calls int64
	if f.observer.QueryRow(ctx, "SELECT last_value FROM "+f.table("relation_shadow_calls")).Scan(&calls) != nil || calls < 1 {
		t.Fatal("shadow view positive control did not invoke the fixture routine")
	}
	s := &Session{conn: f.conn}
	store := &tableedit.Store{}
	target := tableedit.Target{Schema: f.schema, Table: "relation_shadow"}
	b, err := store.Load(ctx, s, target)
	if err != nil || b.Baseline.Advanced == nil || len(b.Baseline.Indexes) != 1 || b.Baseline.Indexes[0].Definition == nil || b.Baseline.Indexes[0].Definition.Predicate == nil {
		t.Fatal("advanced partial/expression-index metadata was not captured")
	}
	column := "id"
	definition := tableedit.IndexDefinition{Method: "btree", Terms: []tableedit.IndexTerm{{Column: &column, Opclass: &tableedit.TypeReference{Schema: f.schema, Name: "shadow_int4_ops"}}}}
	p, err := store.PreviewContext(ctx, s, b.Baseline.ID, tableedit.Draft{AuthoringVersion: 3, Columns: []tableedit.Column{}, Indexes: []tableedit.IndexEdit{{Action: "add", Name: "not_dispatched", Definition: &definition}}})
	if err != nil || len(p.Plan.IndexGuards) == 0 {
		t.Fatal("qualified custom operator-class catalog proof was not captured")
	}
	literal := "NULL"
	authoringApply(t, s, store, target, tableedit.Draft{AuthoringVersion: 2, Columns: []tableedit.Column{}, Changes: []tableedit.ColumnChange{{Name: "payload", Default: &tableedit.Default{Kind: "text", Value: &literal}}}})
	var afterCalls int64
	if f.observer.QueryRow(ctx, "SELECT last_value FROM "+f.table("relation_shadow_calls")).Scan(&afterCalls) != nil || afterCalls != calls {
		t.Fatal("metadata followed an unqualified catalog relation into user code")
	}
	var afterPath string
	if f.conn.QueryRow(ctx, "SELECT pg_catalog.current_setting('search_path')").Scan(&afterPath) != nil || afterPath != path || s.TransactionStatus() != "idle" {
		t.Fatal("catalog guard changed context or transaction state")
	}
}
