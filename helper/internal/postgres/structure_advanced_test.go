package postgres

import (
	"context"
	"dbeer/helper/internal/tableedit"
	"testing"
)

func TestStructureAdvancedKindsLive(t *testing.T) {
	f := newChangeFixture(t)
	s := &Session{conn: f.conn}
	ctx := context.Background()
	store := &tableedit.Store{}
	f.exec("CREATE TABLE " + f.table("parent") + "(id integer, payload text, n numeric(30,4), b bytea)")
	f.exec("CREATE TABLE " + f.table("child") + "(local text) INHERITS (" + f.table("parent") + ")")
	f.exec("CREATE TABLE " + f.table("parts") + "(id integer, payload text, n numeric(30,4), b bytea) PARTITION BY RANGE(id)")
	f.exec("CREATE TABLE " + f.table("leaf") + " PARTITION OF " + f.table("parts") + " FOR VALUES FROM (0) TO (100)")
	f.exec("CREATE TABLE " + f.table("sibling") + " PARTITION OF " + f.table("parts") + " FOR VALUES FROM (100) TO (200)")
	f.exec("CREATE TYPE " + f.table("record_type") + " AS (id integer,payload text,n numeric(30,4),b bytea)")
	f.exec("CREATE TABLE " + f.table("typed_table") + " OF " + f.table("record_type"))
	f.exec("CREATE TABLE " + f.table("secured") + "(id integer, payload text, n numeric(30,4), b bytea)")
	f.exec("ALTER TABLE " + f.table("secured") + " ENABLE ROW LEVEL SECURITY")
	f.exec("ALTER TABLE " + f.table("secured") + " FORCE ROW LEVEL SECURITY")
	f.exec("CREATE POLICY exact_policy ON " + f.table("secured") + " USING (id>0) WITH CHECK (id>0)")
	for _, name := range []string{"parent", "child", "leaf", "sibling", "typed_table", "secured"} {
		ids := "1"
		second := "2"
		if name == "sibling" {
			ids = "101"
			second = "102"
		}
		f.exec("INSERT INTO " + f.table(name) + "(id,payload,n,b) VALUES (" + ids + ",'',12345678901234567890.1234,decode('00ff','hex')),(" + second + ",'NULL',NULL,NULL)")
		f.exec("COMMENT ON TABLE " + f.table(name) + " IS 'retained table comment'")
		f.exec("COMMENT ON COLUMN " + f.table(name) + ".payload IS 'retained column comment'")
	}
	val := "NULL"
	for _, name := range []string{"parent", "child", "parts", "leaf", "typed_table", "secured"} {
		t.Run(name+"Default", func(t *testing.T) {
			target := tableedit.Target{Schema: f.schema, Table: name}
			b, e := s.StructureLoad(ctx, target)
			if e != nil || b.Advanced == nil || !b.Advanced.Valid("postgresql") {
				t.Fatalf("advanced load: %v", e)
			}
			authoringApply(t, s, store, target, tableedit.Draft{AuthoringVersion: 2, Columns: []tableedit.Column{}, Changes: []tableedit.ColumnChange{{Name: "payload", Default: &tableedit.Default{Kind: "text", Value: &val}}}})
		})
	}
	for _, name := range []string{"secured", "typed_table", "child", "leaf"} {
		t.Run(name+"Index", func(t *testing.T) {
			authoringApply(t, s, store, tableedit.Target{Schema: f.schema, Table: name}, tableedit.Draft{AuthoringVersion: 2, Columns: []tableedit.Column{}, Indexes: []tableedit.IndexEdit{{Action: "add", Name: name + "_idx", Columns: []string{"payload"}}}})
		})
	}
	t.Run("PartitionParentIndex", func(t *testing.T) {
		authoringApply(t, s, store, tableedit.Target{Schema: f.schema, Table: "parts"}, tableedit.Draft{AuthoringVersion: 2, Columns: []tableedit.Column{}, Indexes: []tableedit.IndexEdit{{Action: "add", Name: "parent_payload_idx", Columns: []string{"payload"}}}})
	})
	t.Run("RLSAppendRenameNullable", func(t *testing.T) {
		target := tableedit.Target{Schema: f.schema, Table: "secured"}
		authoringApply(t, s, store, target, tableedit.Draft{AuthoringVersion: 2, Columns: []tableedit.Column{{Name: "new_local", Type: tableedit.DataType{Kind: "integer"}, Nullable: true, Default: tableedit.Default{Kind: "none"}}}})
		to := "renamed_id"
		authoringApply(t, s, store, target, tableedit.Draft{AuthoringVersion: 2, Columns: []tableedit.Column{}, Changes: []tableedit.ColumnChange{{Name: "id", RenameTo: &to}}})
	})
	t.Run("TypedShapeRejected", func(t *testing.T) {
		b, e := store.Load(ctx, s, tableedit.Target{Schema: f.schema, Table: "typed_table"})
		if e != nil {
			t.Fatal(e)
		}
		if _, e = store.PreviewContext(ctx, s, b.Baseline.ID, tableedit.Draft{AuthoringVersion: 2, Columns: []tableedit.Column{{Name: "illegal", Type: tableedit.DataType{Kind: "integer"}, Nullable: true, Default: tableedit.Default{Kind: "none"}}}}); e == nil {
			t.Fatal("typed shape admitted")
		}
	})

	t.Run("RLSLocalNullableWidenDrop", func(t *testing.T) {
		target := tableedit.Target{Schema: f.schema, Table: "secured"}
		required := false
		authoringApply(t, s, store, target, tableedit.Draft{AuthoringVersion: 2, Columns: []tableedit.Column{}, Changes: []tableedit.ColumnChange{{Name: "payload", Nullable: &required}}})
		authoringApply(t, s, store, target, tableedit.Draft{AuthoringVersion: 2, Columns: []tableedit.Column{}, Changes: []tableedit.ColumnChange{{Name: "new_local", Type: &tableedit.DataType{Kind: "bigint"}}}})
		authoringApply(t, s, store, target, tableedit.Draft{AuthoringVersion: 4, AllowDestructive: true, Columns: []tableedit.Column{}, Changes: []tableedit.ColumnChange{{Name: "new_local", Drop: true}}})
	})
	t.Run("TypedNullableAndUnique", func(t *testing.T) {
		target := tableedit.Target{Schema: f.schema, Table: "typed_table"}
		required := false
		authoringApply(t, s, store, target, tableedit.Draft{AuthoringVersion: 2, Columns: []tableedit.Column{}, Changes: []tableedit.ColumnChange{{Name: "id", Nullable: &required}}})
		authoringApply(t, s, store, target, tableedit.Draft{AuthoringVersion: 2, Columns: []tableedit.Column{}, Keys: []tableedit.KeyEdit{{Action: "add", Kind: "unique", Name: "typed_unique", Columns: []string{"id"}}}})
	})
	t.Run("PartitionParentUniqueAndPrimary", func(t *testing.T) {
		target := tableedit.Target{Schema: f.schema, Table: "parts"}
		authoringApply(t, s, store, target, tableedit.Draft{AuthoringVersion: 2, Columns: []tableedit.Column{}, Keys: []tableedit.KeyEdit{{Action: "add", Kind: "unique", Name: "parts_unique", Columns: []string{"id", "payload"}}}})
		authoringApply(t, s, store, target, tableedit.Draft{AuthoringVersion: 2, Columns: []tableedit.Column{}, Keys: []tableedit.KeyEdit{{Action: "add", Kind: "primary", Name: "parts_primary", Columns: []string{"id"}}}})
	})
	for _, name := range []string{"secured", "typed_table", "parent"} {
		t.Run(name+"TableRename", func(t *testing.T) {
			renamed := name + "_renamed"
			authoringApply(t, s, store, tableedit.Target{Schema: f.schema, Table: name}, tableedit.Draft{AuthoringVersion: 2, Columns: []tableedit.Column{}, RenameTable: &renamed})
		})
	}
	t.Run("PolicyDriftStopsBeforeDDL", func(t *testing.T) {
		target := tableedit.Target{Schema: f.schema, Table: "secured_renamed"}
		b, e := store.Load(ctx, s, target)
		if e != nil {
			t.Fatal(e)
		}
		p, e := store.PreviewContext(ctx, s, b.Baseline.ID, tableedit.Draft{AuthoringVersion: 2, Columns: []tableedit.Column{}, Changes: []tableedit.ColumnChange{{Name: "payload", Default: &tableedit.Default{Kind: "none"}}}})
		if e != nil {
			t.Fatal(e)
		}
		f.exec("ALTER POLICY exact_policy ON " + f.table(target.Table) + " USING (renamed_id>1)")
		o, e := store.Apply(ctx, s, tableedit.Apply{PlanID: p.Plan.ID, Digest: p.Plan.Digest, ExecutionID: tableedit.Token()})
		if e != nil || o.Outcome.State != "failed" || o.Outcome.Steps[0].State != "notStarted" {
			t.Fatal("late policy drift dispatched DDL")
		}
	})
	t.Run("NestedParentIndexes", func(t *testing.T) {
		f.exec("CREATE TABLE " + f.table("nested_root") + "(id integer,payload text) PARTITION BY RANGE(id)")
		f.exec("CREATE TABLE " + f.table("nested_mid") + " PARTITION OF " + f.table("nested_root") + " FOR VALUES FROM (0) TO (100) PARTITION BY HASH(id)")
		f.exec("CREATE TABLE " + f.table("nested_a") + " PARTITION OF " + f.table("nested_mid") + " FOR VALUES WITH (MODULUS 2,REMAINDER 0)")
		f.exec("CREATE TABLE " + f.table("nested_b") + " PARTITION OF " + f.table("nested_mid") + " FOR VALUES WITH (MODULUS 2,REMAINDER 1)")
		f.exec("INSERT INTO " + f.table("nested_root") + " VALUES (1,'NULL'),(2,'')")
		authoringApply(t, s, store, tableedit.Target{Schema: f.schema, Table: "nested_root"}, tableedit.Draft{AuthoringVersion: 2, Columns: []tableedit.Column{}, Indexes: []tableedit.IndexEdit{{Action: "add", Name: "nested_payload_idx", Columns: []string{"payload"}}}})
	})
	var count int
	var exact bool
	if f.observer.QueryRow(ctx, "SELECT count(*),bool_and(n=12345678901234567890.1234 OR n IS NULL) FROM "+f.table("parts")).Scan(&count, &exact) != nil || count != 4 || !exact {
		t.Fatal("partition rows changed")
	}
}
