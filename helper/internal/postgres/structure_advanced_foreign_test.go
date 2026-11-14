package postgres

import (
	"context"
	"dbeer/helper/internal/tableedit"
	"testing"
)

func TestStructureAdvancedForeignAndParentRemovalLive(t *testing.T) {
	f := newChangeFixture(t)
	s := &Session{conn: f.conn}
	ctx := context.Background()
	store := &tableedit.Store{}
	f.exec("CREATE TABLE " + f.table("ref_plain") + "(id integer PRIMARY KEY)")
	f.exec("INSERT INTO " + f.table("ref_plain") + " VALUES(1),(2),(101),(102)")
	f.exec("CREATE TABLE " + f.table("ref_parts") + "(id integer PRIMARY KEY) PARTITION BY RANGE(id)")
	f.exec("CREATE TABLE " + f.table("ref_a") + " PARTITION OF " + f.table("ref_parts") + " FOR VALUES FROM (0) TO (100)")
	f.exec("CREATE TABLE " + f.table("ref_b") + " PARTITION OF " + f.table("ref_parts") + " FOR VALUES FROM (100) TO (200)")
	f.exec("INSERT INTO " + f.table("ref_parts") + " VALUES(1),(2),(101),(102)")
	for _, kind := range []string{"rls", "typed", "inheritance", "parts", "ordinary"} {
		for _, reference := range []string{"ref_plain", "ref_parts"} {
			t.Run(kind+"_"+reference, func(t *testing.T) {
				name := "source_" + kind + "_" + reference
				switch kind {
				case "typed":
					f.exec("CREATE TYPE " + f.table(name+"_type") + " AS (id integer,ref integer)")
					f.exec("CREATE TABLE " + f.table(name) + " OF " + f.table(name+"_type"))
				case "parts":
					f.exec("CREATE TABLE " + f.table(name) + "(id integer,ref integer) PARTITION BY RANGE(id)")
					f.exec("CREATE TABLE " + f.table(name+"_a") + " PARTITION OF " + f.table(name) + " FOR VALUES FROM (0) TO (100)")
					f.exec("CREATE TABLE " + f.table(name+"_b") + " PARTITION OF " + f.table(name) + " FOR VALUES FROM (100) TO (200)")
				default:
					f.exec("CREATE TABLE " + f.table(name) + "(id integer,ref integer)")
				}
				if kind == "inheritance" {
					f.exec("CREATE TABLE " + f.table(name+"_child") + "() INHERITS (" + f.table(name) + ")")
				}
				if kind == "rls" {
					f.exec("ALTER TABLE " + f.table(name) + " ENABLE ROW LEVEL SECURITY")
					f.exec("ALTER TABLE " + f.table(name) + " FORCE ROW LEVEL SECURITY")
					f.exec("CREATE POLICY retained_policy ON " + f.table(name) + " USING (id>0) WITH CHECK (ref>0)")
				}
				f.exec("INSERT INTO " + f.table(name) + " VALUES(1,1),(101,101)")
				target := tableedit.Target{Schema: f.schema, Table: name}
				ref := tableedit.Target{Schema: f.schema, Table: reference}
				key := tableedit.KeyEdit{Action: "add", Kind: "foreign", Name: "reviewed_fk", Columns: []string{"ref"}, Reference: &ref, ReferenceColumns: []string{"id"}, OnUpdate: "NO ACTION", OnDelete: "RESTRICT"}
				authoringApply(t, s, store, target, tableedit.Draft{AuthoringVersion: 2, Columns: []tableedit.Column{}, Keys: []tableedit.KeyEdit{key}})
				b, e := store.Load(ctx, s, target)
				if e != nil {
					t.Fatal(e)
				}
				if kind != "ordinary" || reference == "ref_parts" {
					p, e := store.PreviewContext(ctx, s, b.Baseline.ID, tableedit.Draft{AuthoringVersion: 2, AllowDestructive: true, Columns: []tableedit.Column{}, Keys: []tableedit.KeyEdit{{Action: "drop", Kind: "foreign", Name: "reviewed_fk"}}})
					if e != nil {
						t.Fatal(e)
					}
					if p.Plan.AdvancedProof == nil {
						t.Fatal("foreign-key proof absent")
					}
				}
				authoringApply(t, s, store, target, tableedit.Draft{AuthoringVersion: 2, AllowDestructive: true, Columns: []tableedit.Column{}, Keys: []tableedit.KeyEdit{{Action: "drop", Kind: "foreign", Name: "reviewed_fk"}}})
			})
		}
	}
	for _, kind := range []string{"rls", "parts"} {
		t.Run("SelfForeignKey_"+kind, func(t *testing.T) {
			name := "self_" + kind
			f.exec("CREATE TABLE " + f.table(name) + "(id integer PRIMARY KEY,ref integer)" + map[string]string{"parts": " PARTITION BY RANGE(id)"}[kind])
			if kind == "parts" {
				f.exec("CREATE TABLE " + f.table(name+"_a") + " PARTITION OF " + f.table(name) + " FOR VALUES FROM(0) TO(100)")
				f.exec("CREATE TABLE " + f.table(name+"_b") + " PARTITION OF " + f.table(name) + " FOR VALUES FROM(100) TO(200)")
			} else {
				f.exec("ALTER TABLE " + f.table(name) + " ENABLE ROW LEVEL SECURITY")
				f.exec("ALTER TABLE " + f.table(name) + " FORCE ROW LEVEL SECURITY")
				f.exec("CREATE POLICY retained ON " + f.table(name) + " USING(id>0)")
			}
			f.exec("INSERT INTO " + f.table(name) + " VALUES(1,1),(101,1)")
			target := tableedit.Target{Schema: f.schema, Table: name}
			key := tableedit.KeyEdit{Action: "add", Kind: "foreign", Name: "self_fk", Columns: []string{"ref"}, Reference: &target, ReferenceColumns: []string{"id"}, OnUpdate: "NO ACTION", OnDelete: "RESTRICT"}
			authoringApply(t, s, store, target, tableedit.Draft{AuthoringVersion: 2, Columns: []tableedit.Column{}, Keys: []tableedit.KeyEdit{key}})
			authoringApply(t, s, store, target, tableedit.Draft{AuthoringVersion: 2, AllowDestructive: true, Columns: []tableedit.Column{}, Keys: []tableedit.KeyEdit{{Action: "drop", Kind: "foreign", Name: "self_fk"}}})
		})
	}
	t.Run("ParentIndexAndKeyRemoval", func(t *testing.T) {
		target := tableedit.Target{Schema: f.schema, Table: "ref_parts"}
		authoringApply(t, s, store, target, tableedit.Draft{AuthoringVersion: 2, Columns: []tableedit.Column{}, Indexes: []tableedit.IndexEdit{{Action: "add", Name: "drop_parent_idx", Columns: []string{"id"}}}})
		authoringApply(t, s, store, target, tableedit.Draft{AuthoringVersion: 2, AllowDestructive: true, Columns: []tableedit.Column{}, Indexes: []tableedit.IndexEdit{{Action: "drop", Name: "drop_parent_idx"}}})
		var key string
		if s.conn.QueryRow(ctx, `SELECT conname FROM pg_catalog.pg_constraint WHERE conrelid=$1::pg_catalog.regclass AND contype='p'`, f.table("ref_parts")).Scan(&key) != nil {
			t.Fatal("parent key absent")
		}
		authoringApply(t, s, store, target, tableedit.Draft{AuthoringVersion: 2, AllowDestructive: true, Columns: []tableedit.Column{}, Keys: []tableedit.KeyEdit{{Action: "drop", Kind: "primary", Name: key}}})
	})
}
