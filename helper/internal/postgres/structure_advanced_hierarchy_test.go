package postgres

import (
	"context"
	"dbeer/helper/internal/tableedit"
	"strings"
	"testing"
)

func TestStructureAdvancedRecursiveAndUnloggedLive(t *testing.T) {
	f := newChangeFixture(t)
	s := &Session{conn: f.conn}
	store := &tableedit.Store{}
	ctx := context.Background()
	for _, kind := range []string{"inheritance", "partition"} {
		t.Run(kind, func(t *testing.T) {
			name := "recursive_" + kind
			tail := ""
			if kind == "partition" {
				tail = " PARTITION BY RANGE(id)"
			}
			f.exec("CREATE TABLE " + f.table(name) + "(id integer,payload text)" + tail)
			if kind == "partition" {
				f.exec("CREATE TABLE " + f.table(name+"_a") + " PARTITION OF " + f.table(name) + " FOR VALUES FROM (0) TO (100)")
				f.exec("CREATE TABLE " + f.table(name+"_b") + " PARTITION OF " + f.table(name) + " FOR VALUES FROM (100) TO (200)")
			} else {
				f.exec("CREATE TABLE " + f.table(name+"_a") + "() INHERITS (" + f.table(name) + ")")
				f.exec("CREATE TABLE " + f.table(name+"_b") + "() INHERITS (" + f.table(name+"_a") + ")")
				f.exec("INSERT INTO " + f.table(name+"_b") + " VALUES(101,'NULL')")
			}
			f.exec("INSERT INTO " + f.table(name) + " VALUES(1,'')")
			target := tableedit.Target{Schema: f.schema, Table: name}
			authoringApply(t, s, store, target, tableedit.Draft{AuthoringVersion: 2, Columns: []tableedit.Column{{Name: "added", Type: tableedit.DataType{Kind: "integer"}, Nullable: true, Default: tableedit.Default{Kind: "none"}}}})
			f.exec("UPDATE " + f.table(name) + " SET added=7")
			required := false
			authoringApply(t, s, store, target, tableedit.Draft{AuthoringVersion: 2, Columns: []tableedit.Column{}, Changes: []tableedit.ColumnChange{{Name: "added", Nullable: &required}}})
			renamed := "renamed_added"
			authoringApply(t, s, store, target, tableedit.Draft{AuthoringVersion: 2, Columns: []tableedit.Column{}, Changes: []tableedit.ColumnChange{{Name: "added", RenameTo: &renamed}}})
			authoringApply(t, s, store, target, tableedit.Draft{AuthoringVersion: 2, Columns: []tableedit.Column{}, Changes: []tableedit.ColumnChange{{Name: renamed, Type: &tableedit.DataType{Kind: "bigint"}}}})
			authoringApply(t, s, store, target, tableedit.Draft{AuthoringVersion: 4, AllowDestructive: true, Columns: []tableedit.Column{}, Changes: []tableedit.ColumnChange{{Name: renamed, Drop: true}}})
		})
	}
	t.Run("MultipleInheritanceRetainedLocalColumn", func(t *testing.T) {
		f.exec("CREATE TABLE " + f.table("multi_a") + "(id integer,keep text)")
		f.exec("CREATE TABLE " + f.table("multi_b") + "(id integer)")
		f.exec("CREATE TABLE " + f.table("multi_child") + "() INHERITS (" + f.table("multi_a") + "," + f.table("multi_b") + ")")
		f.exec("CREATE TABLE " + f.table("multi_grandchild") + "() INHERITS (" + f.table("multi_child") + ")")
		f.exec("INSERT INTO " + f.table("multi_child") + " VALUES(7,'')")
		authoringApply(t, s, store, tableedit.Target{Schema: f.schema, Table: "multi_a"}, tableedit.Draft{AuthoringVersion: 4, AllowDestructive: true, Columns: []tableedit.Column{}, Changes: []tableedit.ColumnChange{{Name: "id", Drop: true}}})
		var value int
		if f.observer.QueryRow(ctx, "SELECT id FROM ONLY "+f.table("multi_child")).Scan(&value) != nil || value != 7 {
			t.Fatal("other-parent column data lost")
		}
	})
	t.Run("UnloggedNativeAndPersistenceDrift", func(t *testing.T) {
		f.exec("CREATE UNLOGGED TABLE " + f.table("unlogged_native") + "(id integer,payload text)")
		f.exec("INSERT INTO " + f.table("unlogged_native") + " VALUES(1,''),(2,'NULL')")
		target := tableedit.Target{Schema: f.schema, Table: "unlogged_native"}
		value := "NULL"
		authoringApply(t, s, store, target, tableedit.Draft{AuthoringVersion: 2, Columns: []tableedit.Column{}, Changes: []tableedit.ColumnChange{{Name: "payload", Default: &tableedit.Default{Kind: "text", Value: &value}}}})
		b, e := store.Load(ctx, s, target)
		if e != nil || b.Baseline.Advanced == nil {
			t.Fatal("unlogged kind absent")
		}
		p, e := store.PreviewContext(ctx, s, b.Baseline.ID, tableedit.Draft{AuthoringVersion: 2, Columns: []tableedit.Column{}, Indexes: []tableedit.IndexEdit{{Action: "add", Name: "unlogged_idx", Columns: []string{"payload"}}}})
		if e != nil {
			t.Fatal(e)
		}
		f.exec("ALTER TABLE " + f.table(target.Table) + " SET LOGGED")
		o, e := store.Apply(ctx, s, tableedit.Apply{PlanID: p.Plan.ID, Digest: p.Plan.Digest, ExecutionID: tableedit.Token()})
		if e != nil || o.Outcome.Steps[0].State != "notStarted" {
			t.Fatal("persistence drift dispatched DDL")
		}
		ordinary, e := s.StructureLoad(ctx, target)
		if e != nil || ordinary.Advanced != nil {
			t.Fatal("old permanent ordinary eligibility changed")
		}
	})
	t.Run("TemporaryOwnershipReason", func(t *testing.T) {
		f.exec("CREATE TEMP TABLE owned_temp(id integer)")
		var schema string
		if f.observer.QueryRow(ctx, `SELECT nspname FROM pg_catalog.pg_namespace WHERE oid=pg_catalog.pg_my_temp_schema()`).Scan(&schema) != nil {
			t.Fatal("temp namespace absent")
		}
		_, e := s.StructureLoad(ctx, tableedit.Target{Schema: schema, Table: "owned_temp"})
		if e == nil || !strings.Contains(e.Error(), "owning physical") {
			t.Fatal("temporary owning-session reason absent")
		}
	})
}
