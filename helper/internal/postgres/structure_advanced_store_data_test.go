package postgres

import (
	"context"
	"dbeer/helper/internal/tableedit"
	"fmt"
	"github.com/jackc/pgx/v5"
	"strings"
	"testing"
)

func pgAdvancedStoreApply(t *testing.T, a *Session, target tableedit.Target, d tableedit.Draft, scope string) {
	t.Helper()
	ctx := context.Background()
	store := &tableedit.Store{}
	b, e := store.Load(ctx, a, target)
	if e != nil {
		t.Fatal(e)
	}
	p, e := store.PreviewContext(ctx, a, b.Baseline.ID, d)
	if e != nil {
		t.Fatal(e)
	}
	if scope != "" {
		if len(p.Plan.SQL) != 1 || !strings.HasPrefix(p.Plan.SQL[0], scope) {
			t.Fatal("normal Preview did not disclose the exact native target scope")
		}
	}
	o, e := store.Apply(ctx, a, tableedit.Apply{PlanID: p.Plan.ID, Digest: p.Plan.Digest, ExecutionID: tableedit.Token()})
	if e != nil {
		t.Fatal(e)
	}
	if o.Outcome.State != "applied" || o.Outcome.Observed == nil {
		t.Fatalf("normal Store outcome mismatch: %s steps=%v", o.Outcome.State, o.Outcome.Steps)
	}
	for _, step := range o.Outcome.Steps {
		if step.Message != "" {
			t.Fatal(step.Message)
		}
	}
}
func TestStructureAdvancedStoreLocalGenerationLive(t *testing.T) {
	f := newChangeFixture(t)
	ctx := context.Background()
	a := &Session{conn: f.conn}
	var version int
	if f.conn.QueryRow(ctx, "SELECT pg_catalog.current_setting('server_version_num')::pg_catalog.int4").Scan(&version) != nil {
		t.Fatal("native version unavailable")
	}
	for _, kind := range []string{"rls", "inheritance", "unlogged", "partitionParent", "partitionLeaf"} {
		t.Run(kind, func(t *testing.T) {
			name := "candidate_gen_" + kind
			prefix := "CREATE TABLE "
			if kind == "unlogged" {
				prefix = "CREATE UNLOGGED TABLE "
			}
			if kind == "typed" {
				f.exec("CREATE TYPE " + f.table(name+"_type") + " AS(id integer,base integer,derived integer,payload text,amount numeric(20,4),bytes bytea)")
				f.exec("CREATE TABLE " + f.table(name) + " OF " + f.table(name+"_type") + "(id WITH OPTIONS NOT NULL,derived WITH OPTIONS GENERATED ALWAYS AS(base*2) STORED)")
			} else {
				tail := ""
				if kind == "partitionParent" || kind == "partitionLeaf" {
					tail = " PARTITION BY RANGE(id)"
				}
				f.exec(prefix + f.table(name) + "(id integer NOT NULL,base integer,derived integer GENERATED ALWAYS AS(base*2) STORED,payload text,amount numeric(20,4),bytes bytea)" + tail)
				if tail != "" {
					f.exec("CREATE TABLE " + f.table(name+"_leaf") + " PARTITION OF " + f.table(name) + " FOR VALUES FROM(0)TO(100)")
				}
			}
			if kind == "rls" {
				f.exec("ALTER TABLE " + f.table(name) + " ENABLE ROW LEVEL SECURITY")
				f.exec("ALTER TABLE " + f.table(name) + " FORCE ROW LEVEL SECURITY")
			}
			if kind == "inheritance" {
				f.exec("CREATE TABLE " + f.table(name+"_child") + "() INHERITS(" + f.table(name) + ")")
				f.exec("INSERT INTO " + f.table(name+"_child") + "(id,base,payload,amount,bytes) VALUES(2,7,'NULL',1234567890123456.1234,'\\x00ff')")
			}
			f.exec("INSERT INTO " + f.table(name) + "(id,base,payload,amount,bytes) VALUES(1,6,'',1234567890123456.1234,'\\x00ff')")
			targetName := name
			if kind == "partitionLeaf" {
				targetName = name + "_leaf"
			}
			target := tableedit.Target{Schema: f.schema, Table: targetName}
			generation := tableedit.Generation{Storage: "none"}
			if version >= 170000 {
				generation = tableedit.Generation{Storage: "stored", Expression: "base * 3"}
			}
			draft := tableedit.Draft{AuthoringVersion: 2, Columns: []tableedit.Column{}, Changes: []tableedit.ColumnChange{{Name: "derived", Generated: &generation}}}
			if version < 170000 && kind == "partitionLeaf" {
				store := &tableedit.Store{}
				b, err := store.Load(ctx, a, target)
				if err != nil {
					t.Fatal(err)
				}
				if _, err = store.PreviewContext(ctx, a, b.Baseline.ID, draft); err == nil || !strings.Contains(err.Error(), "declaring ancestor") {
					t.Fatal("inherited generation removal was not refused before DDL")
				}
				return
			}
			only := "ONLY "
			if version < 170000 && (kind == "inheritance" || kind == "partitionParent") {
				only = ""
			}
			pgAdvancedStoreApply(t, a, target, draft, "ALTER TABLE "+only+f.table(targetName)+" ALTER COLUMN ")
			var root int
			want := 12
			if version >= 170000 {
				want = 18
			}
			rowTable := targetName
			if kind == "partitionParent" {
				rowTable = name + "_leaf"
				want = 12
			}
			if f.observer.QueryRow(ctx, "SELECT derived FROM ONLY "+f.table(rowTable)).Scan(&root) != nil || root != want {
				t.Fatal("selected root generation result was not retained")
			}
			if kind == "inheritance" {
				var child int
				if f.observer.QueryRow(ctx, "SELECT derived FROM ONLY "+f.table(name+"_child")).Scan(&child) != nil || child != 14 {
					t.Fatal("local generation changed descendant values")
				}
			}
		})
	}
}
func TestStructureAdvancedStoreNativeReconstructionLive(t *testing.T) {
	f := newChangeFixture(t)
	a := &Session{conn: f.conn}
	f.exec("CREATE UNLOGGED TABLE " + f.table("candidate_rewrite") + "(id integer,payload text)")
	f.exec("INSERT INTO " + f.table("candidate_rewrite") + " VALUES(1,''),(1,''),(2,'NULL'),(3,NULL)")
	pgAdvancedStoreApply(t, a, tableedit.Target{Schema: f.schema, Table: "candidate_rewrite"}, tableedit.Draft{AuthoringVersion: 5, Columns: []tableedit.Column{}, Reconstruct: true, AllowDestructive: true}, "")
}

func TestStructureAdvancedStoreIdentityKindsLive(t *testing.T) {
	fixture := newChangeFixture(t)
	ctx := context.Background()
	a := &Session{conn: fixture.conn}
	for _, kind := range []string{"rls", "inheritance", "unlogged", "partitionParent", "partitionLeaf", "typed"} {
		t.Run(kind, func(t *testing.T) {
			copy := *fixture
			copy.t = t
			f := &copy
			name := "candidate_identity_" + kind
			if kind == "typed" {
				f.exec("CREATE TYPE " + f.table(name+"_type") + " AS(id integer,payload text)")
				f.exec("CREATE TABLE " + f.table(name) + " OF " + f.table(name+"_type") + "(id WITH OPTIONS NOT NULL)")
			} else {
				prefix := "CREATE TABLE "
				if kind == "unlogged" {
					prefix = "CREATE UNLOGGED TABLE "
				}
				tail := ""
				if kind == "partitionParent" || kind == "partitionLeaf" {
					tail = " PARTITION BY RANGE(id)"
				}
				f.exec(prefix + f.table(name) + "(id integer NOT NULL,payload text)" + tail)
			}
			if kind == "rls" {
				f.exec("ALTER TABLE " + f.table(name) + " ENABLE ROW LEVEL SECURITY")
				f.exec("ALTER TABLE " + f.table(name) + " FORCE ROW LEVEL SECURITY")
			}
			if kind == "inheritance" {
				f.exec("CREATE TABLE " + f.table(name+"_child") + "() INHERITS(" + f.table(name) + ")")
				f.exec("INSERT INTO " + f.table(name+"_child") + " VALUES(2,'NULL')")
			}
			if kind == "partitionParent" || kind == "partitionLeaf" {
				f.exec("CREATE TABLE " + f.table(name+"_leaf") + " PARTITION OF " + f.table(name) + " FOR VALUES FROM(0)TO(100)")
			}
			f.exec("INSERT INTO " + f.table(name) + " VALUES(1,'')")
			targetName := name
			if kind == "partitionLeaf" {
				targetName = name + "_leaf"
			}
			target := tableedit.Target{Schema: f.schema, Table: targetName}
			observed, err := a.StructureLoad(ctx, target)
			if err != nil {
				t.Fatal(err)
			}
			scope := "ALTER TABLE ONLY " + f.table(targetName) + " ALTER COLUMN "
			if kind == "partitionParent" && observed.Facts.ServerVersion >= 170000 {
				scope = "ALTER TABLE " + f.table(name) + " ALTER COLUMN "
			}
			if kind == "partitionLeaf" && observed.Facts.ServerVersion >= 170000 {
				store := &tableedit.Store{}
				b, err := store.Load(ctx, a, target)
				if err != nil {
					t.Fatal(err)
				}
				identity := tableedit.Identity{Kind: "byDefault"}
				if _, err = store.PreviewContext(ctx, a, b.Baseline.ID, tableedit.Draft{AuthoringVersion: 2, Columns: []tableedit.Column{}, Changes: []tableedit.ColumnChange{{Name: "id", Identity: &identity}}}); err == nil || !strings.Contains(err.Error(), "42P16") {
					t.Fatal("native inherited identity ownership was not refused before DDL")
				}
				return
			}
			increment := "2"
			for _, identity := range []tableedit.Identity{{Kind: "byDefault"}, {Kind: "always", Increment: &increment}, {Kind: "none"}} {
				pgAdvancedStoreApply(t, a, target, tableedit.Draft{AuthoringVersion: 2, Columns: []tableedit.Column{}, Changes: []tableedit.ColumnChange{{Name: "id", Identity: &identity}}}, scope)
				rowTable := targetName
				if kind == "partitionParent" || kind == "partitionLeaf" {
					rowTable = name + "_leaf"
				}
				var id int
				if f.observer.QueryRow(ctx, "SELECT id FROM ONLY "+f.table(rowTable)).Scan(&id) != nil || id != 1 {
					t.Fatal("identity action changed an existing native value")
				}
			}
		})
	}
}

func pgAdvancedStorePlainKind(t *testing.T, f *changeFixture, kind, name string) tableedit.Target {
	t.Helper()
	if kind == "typed" {
		f.exec("CREATE TYPE " + f.table(name+"_type") + " AS(id integer,payload text)")
		f.exec("CREATE TABLE " + f.table(name) + " OF " + f.table(name+"_type") + "(id WITH OPTIONS NOT NULL)")
	} else {
		prefix := "CREATE TABLE "
		if kind == "unlogged" {
			prefix = "CREATE UNLOGGED TABLE "
		}
		tail := ""
		if kind == "partitionParent" || kind == "partitionLeaf" {
			tail = " PARTITION BY RANGE(id)"
		}
		f.exec(prefix + f.table(name) + "(id integer NOT NULL,payload text)" + tail)
		if tail != "" {
			f.exec("CREATE TABLE " + f.table(name+"_a") + " PARTITION OF " + f.table(name) + " FOR VALUES FROM(0)TO(10)")
			f.exec("CREATE TABLE " + f.table(name+"_b") + " PARTITION OF " + f.table(name) + " FOR VALUES FROM(10)TO(100)")
		}
	}
	if kind == "rls" {
		f.exec("ALTER TABLE " + f.table(name) + " ENABLE ROW LEVEL SECURITY")
		f.exec("ALTER TABLE " + f.table(name) + " FORCE ROW LEVEL SECURITY")
		f.exec("CREATE POLICY retained_policy ON " + f.table(name) + " USING(id>0)")
	}
	if kind == "inheritance" {
		f.exec("CREATE TABLE " + f.table(name+"_a") + "() INHERITS(" + f.table(name) + ")")
		f.exec("CREATE TABLE " + f.table(name+"_b") + "() INHERITS(" + f.table(name+"_a") + ")")
		f.exec("INSERT INTO " + f.table(name+"_b") + " VALUES(11,'NULL')")
	}
	f.exec("COMMENT ON TABLE " + f.table(name) + " IS 'retained table'")
	f.exec("INSERT INTO " + f.table(name) + " VALUES(1,''),(2,NULL)")
	if kind == "partitionParent" || kind == "partitionLeaf" {
		f.exec("INSERT INTO " + f.table(name) + " VALUES(11,'NULL')")
	}
	if kind == "partitionLeaf" {
		return tableedit.Target{Schema: f.schema, Table: name + "_a"}
	}
	return tableedit.Target{Schema: f.schema, Table: name}
}
func TestStructureAdvancedStoreNativeKindReconstructionLive(t *testing.T) {
	fixture := newChangeFixture(t)
	a := &Session{conn: fixture.conn}
	for _, kind := range []string{"rls", "inheritance", "unlogged", "partitionParent", "partitionLeaf", "typed"} {
		t.Run(kind, func(t *testing.T) {
			copy := *fixture
			copy.t = t
			f := &copy
			target := pgAdvancedStorePlainKind(t, f, kind, "candidate_cluster_"+kind)
			before, err := a.StructureLoad(context.Background(), target)
			if err != nil {
				t.Fatal(err)
			}
			for id := range pgAdvancedDataDescendants(before) {
				cl := before.AdvancedEvidence.Rows[id+"/class"][0]
				if cl["relkind"] != "r" {
					continue
				}
				facts := before.AdvancedEvidence.Facts[id]
				qualified := pgx.Identifier{facts.Table.Ref.Schema, facts.Table.Ref.Name}.Sanitize()
				index := pgx.Identifier{facts.Table.Ref.Schema, "property_" + id}.Sanitize()
				f.exec("CREATE INDEX " + pgx.Identifier{"property_" + id}.Sanitize() + " ON " + qualified + "((id+1)) WITH(fillfactor=73)")
				f.exec("ALTER INDEX " + index + " ALTER COLUMN 1 SET STATISTICS 321")
				for _, toast := range before.AdvancedEvidence.Rows[id+"/toast"] {
					for _, raw := range toast["indexes"].([]any) {
						index := raw.(map[string]any)["class"].(map[string]any)
						f.exec("COMMENT ON INDEX " + pgx.Identifier{"pg_toast", fmt.Sprint(index["relname"])}.Sanitize() + " IS 'retained storage comment'")
					}
				}
			}
			before, err = a.StructureLoad(context.Background(), target)
			if err != nil {
				t.Fatal(err)
			}
			pgAdvancedStoreApply(t, a, target, tableedit.Draft{AuthoringVersion: 5, Columns: []tableedit.Column{}, Reconstruct: true, AllowDestructive: true}, "")
			after, err := a.StructureLoad(context.Background(), target)
			if err != nil || before.Identity != after.Identity {
				t.Fatal("native same-order reconstruction replaced its relation identity")
			}
		})
	}
}
func TestStructureAdvancedStoreBackfillKindsLive(t *testing.T) {
	fixture := newChangeFixture(t)
	a := &Session{conn: fixture.conn}
	ctx := context.Background()
	for _, kind := range []string{"rls", "inheritance", "unlogged", "partitionParent", "partitionLeaf", "typed"} {
		t.Run(kind, func(t *testing.T) {
			copy := *fixture
			copy.t = t
			f := &copy
			name := "candidate_backfill_" + kind
			target := pgAdvancedStorePlainKind(t, f, kind, name)
			draft := tableedit.Draft{AuthoringVersion: 5, AllowDestructive: true, Columns: []tableedit.Column{{Name: "required", Type: tableedit.DataType{Kind: "integer"}, Nullable: false, Default: tableedit.Default{Kind: "none"}}}, Backfills: []tableedit.Backfill{{Column: "required", Expression: "id + 100"}}}
			if kind == "typed" || kind == "partitionLeaf" {
				store := &tableedit.Store{}
				b, err := store.Load(ctx, a, target)
				if err != nil {
					t.Fatal(err)
				}
				if _, err = store.PreviewContext(ctx, a, b.Baseline.ID, draft); err == nil {
					t.Fatal("native bound-shape operation unexpectedly admitted local append")
				}
				return
			}
			pgAdvancedStoreApply(t, a, target, draft, "")
			rows, err := f.observer.Query(ctx, "SELECT id,required FROM "+f.table(name)+" ORDER BY id")
			if err != nil {
				t.Fatal("required values unavailable")
			}
			defer rows.Close()
			count := 0
			for rows.Next() {
				var id, value int
				if rows.Scan(&id, &value) != nil || value != id+100 {
					t.Fatal("required backfill values changed or remain nullable")
				}
				count++
			}
			if rows.Err() != nil || count < 2 {
				t.Fatal("nonempty required backfill proof was incomplete")
			}
		})
	}
}
