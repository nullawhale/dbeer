package postgres

import (
	"context"
	"fmt"
	"reflect"
	"strings"
	"testing"

	"dbeer/helper/internal/tableedit"
	"github.com/jackc/pgx/v5"
)

func TestStructureAdvancedStoreRewritePropertiesLive(t *testing.T) {
	fixture := newChangeFixture(t)
	ctx := context.Background()
	a := &Session{conn: fixture.conn}
	for _, kind := range []string{"rls", "inheritance", "partitionParent", "partitionLeaf", "unlogged"} {
		t.Run(kind, func(t *testing.T) {
			copy := *fixture
			copy.t = t
			f := &copy
			name := "rewrite_props_" + kind
			prefix := "CREATE TABLE "
			if kind == "unlogged" {
				prefix = "CREATE UNLOGGED TABLE "
			}
			tail := ""
			if strings.HasPrefix(kind, "partition") {
				tail = " PARTITION BY RANGE(id)"
			}
			f.exec(prefix + f.table(name) + "(id integer NOT NULL,n integer,base integer,payload text,derived integer GENERATED ALWAYS AS(base*2) STORED)" + tail)
			if tail != "" {
				f.exec("CREATE TABLE " + f.table(name+"_a") + " PARTITION OF " + f.table(name) + " FOR VALUES FROM(0)TO(10)")
				f.exec("CREATE TABLE " + f.table(name+"_b") + " PARTITION OF " + f.table(name) + " FOR VALUES FROM(10)TO(100)")
			}
			if kind == "inheritance" {
				f.exec("CREATE TABLE " + f.table(name+"_child") + "() INHERITS(" + f.table(name) + ")")
				f.exec("INSERT INTO " + f.table(name+"_child") + "(id,n,base,payload) VALUES(12,-2147483648,7,'NULL')")
			}
			f.exec("INSERT INTO " + f.table(name) + "(id,n,base,payload) VALUES(1,2147483647,6,''),(2,NULL,5,NULL)")
			if tail != "" {
				f.exec("INSERT INTO " + f.table(name) + "(id,n,base,payload) VALUES(12,-2147483648,7,'NULL')")
			}
			if kind == "rls" {
				f.exec("ALTER TABLE " + f.table(name) + " ENABLE ROW LEVEL SECURITY")
				f.exec("ALTER TABLE " + f.table(name) + " FORCE ROW LEVEL SECURITY")
				f.exec("CREATE POLICY keep_rows ON " + f.table(name) + " USING(id>0)")
			}
			target := tableedit.Target{Schema: f.schema, Table: name}
			if kind == "partitionLeaf" {
				target.Table = name + "_a"
			}
			before, err := a.StructureLoad(ctx, target)
			if err != nil {
				t.Fatal(err)
			}
			for key, classes := range before.AdvancedEvidence.Rows {
				if !strings.HasSuffix(key, "/class") || len(classes) != 1 {
					continue
				}
				id := strings.TrimSuffix(key, "/class")
				facts := before.AdvancedEvidence.Facts[id]
				indexName := "rewrite_property_" + id
				index := pgx.Identifier{facts.Table.Ref.Schema, indexName}.Sanitize()
				qualified := pgx.Identifier{facts.Table.Ref.Schema, facts.Table.Ref.Name}.Sanitize()
				f.exec("CREATE INDEX " + pgx.Identifier{indexName}.Sanitize() + " ON " + qualified + "((length(payload))) WITH(fillfactor=73)")
				f.exec("ALTER INDEX " + index + " ALTER COLUMN 1 SET STATISTICS 321")
				for _, toast := range before.AdvancedEvidence.Rows[id+"/toast"] {
					for _, raw := range toast["indexes"].([]any) {
						cl := raw.(map[string]any)["class"].(map[string]any)
						f.exec("COMMENT ON INDEX " + pgx.Identifier{"pg_toast", fmt.Sprint(cl["relname"])}.Sanitize() + " IS 'retained rewrite storage'")
					}
				}
			}
			before, err = a.StructureLoad(ctx, target)
			if err != nil {
				t.Fatal(err)
			}
			observe := func() map[string][][]any {
				out := map[string][][]any{}
				for id, facts := range before.AdvancedEvidence.Facts {
					rows, err := f.observer.Query(ctx, "SELECT id,n::pg_catalog.text,payload,derived FROM ONLY "+pgx.Identifier{facts.Table.Ref.Schema, facts.Table.Ref.Name}.Sanitize()+" ORDER BY id")
					if err != nil {
						t.Fatal("retained row projection unavailable")
					}
					values := [][]any{}
					for rows.Next() {
						row, err := rows.Values()
						if err != nil {
							rows.Close()
							t.Fatal("retained row projection invalid")
						}
						values = append(values, row)
					}
					rows.Close()
					if rows.Err() != nil {
						t.Fatal("retained row projection incomplete")
					}
					out[id] = values
				}
				return out
			}
			original := observe()
			widenDraft := tableedit.Draft{AuthoringVersion: 2, Columns: []tableedit.Column{}, Changes: []tableedit.ColumnChange{{Name: "n", Type: &tableedit.DataType{Kind: "bigint"}}}}
			if kind == "partitionLeaf" {
				store := &tableedit.Store{}
				b, err := store.Load(ctx, a, target)
				if err != nil {
					t.Fatal(err)
				}
				if _, err = store.PreviewContext(ctx, a, b.Baseline.ID, widenDraft); err == nil || !strings.Contains(err.Error(), "declaring parent") {
					t.Fatal("attached partition type change was not refused before DDL")
				}
			} else {
				pgAdvancedStoreApply(t, a, target, widenDraft, "ALTER TABLE ")
			}
			if !reflect.DeepEqual(original, observe()) {
				t.Fatal("native widening changed exact retained values")
			}
			widened, err := a.StructureLoad(ctx, target)
			if err != nil {
				t.Fatal(err)
			}
			c := tableedit.Condition{Operation: tableedit.Operation{Kind: "changeColumn", Change: &tableedit.ColumnChange{Name: "n", Type: &tableedit.DataType{Kind: "bigint"}}}}
			mutated := widened
			mutated.AdvancedEvidence = tableedit.CloneAdvancedEvidence(widened.AdvancedEvidence)
			for _, row := range mutated.AdvancedEvidence.Rows[widened.Identity+"/indexAttributes"] {
				if fmt.Sprint(row["attstattarget"]) == "321" {
					row["attstattarget"] = float64(322)
					break
				}
			}
			if pgAdvancedPreservationError(before, mutated, c) == nil {
				t.Fatal("genuine index statistics were ignored during widening")
			}
			if widened.Facts.ServerVersion >= 170000 {
				pgAdvancedStoreApply(t, a, target, tableedit.Draft{AuthoringVersion: 2, Columns: []tableedit.Column{}, Changes: []tableedit.ColumnChange{{Name: "derived", Generated: &tableedit.Generation{Storage: "stored", Expression: "base * 3"}}}}, "ALTER TABLE ONLY ")
			}
		})
	}
}

func TestStructureAdvancedStoreRewriteAfterExplicitRemovalLive(t *testing.T) {
	for _, mode := range []string{"dropIndex", "replaceIndex", "dropUnique", "partitionIndex", "partitionUnique"} {
		t.Run(mode, func(t *testing.T) {
			f := newChangeFixture(t)
			ctx := context.Background()
			s := &Session{conn: f.conn}
			store := &tableedit.Store{}
			tail := ""
			if strings.HasPrefix(mode, "partition") {
				tail = " PARTITION BY RANGE(id)"
			}
			f.exec("CREATE TABLE " + f.table("multi_rewrite") + "(id integer,n integer,payload text)" + tail)
			if tail != "" {
				f.exec("CREATE TABLE " + f.table("child") + " PARTITION OF " + f.table("multi_rewrite") + " FOR VALUES FROM(0)TO(100)")
			}
			f.exec("ALTER TABLE " + f.table("multi_rewrite") + " ENABLE ROW LEVEL SECURITY")
			f.exec("ALTER TABLE " + f.table("multi_rewrite") + " FORCE ROW LEVEL SECURITY")
			f.exec("CREATE POLICY keep_rows ON " + f.table("multi_rewrite") + " USING(true)")
			if strings.HasSuffix(mode, "Unique") {
				f.exec("ALTER TABLE " + f.table("multi_rewrite") + " ADD CONSTRAINT old_idx UNIQUE(id)")
			} else {
				f.exec("CREATE INDEX old_idx ON " + f.table("multi_rewrite") + "(id) WITH(fillfactor=73)")
			}
			f.exec("CREATE INDEX retained_idx ON " + f.table("multi_rewrite") + "((length(payload))) WITH(fillfactor=61)")
			f.exec("ALTER INDEX " + f.table("retained_idx") + " ALTER COLUMN 1 SET STATISTICS 321")
			f.exec("INSERT INTO " + f.table("multi_rewrite") + " VALUES(1,-2147483648,''),(2,2147483647,'NULL'),(3,NULL,NULL)")
			target := tableedit.Target{Schema: f.schema, Table: "multi_rewrite"}
			loaded, err := store.Load(ctx, s, target)
			if err != nil {
				t.Fatal(err)
			}
			draft := tableedit.Draft{AuthoringVersion: 4, AllowDestructive: true, Columns: []tableedit.Column{}, Changes: []tableedit.ColumnChange{{Name: "n", Type: &tableedit.DataType{Kind: "bigint"}}}}
			if strings.HasSuffix(mode, "Unique") {
				draft.Keys = []tableedit.KeyEdit{{Action: "drop", Kind: "unique", Name: "old_idx"}}
			} else {
				action := "drop"
				if mode == "replaceIndex" {
					action = "replace"
				}
				edit := tableedit.IndexEdit{Action: action, Name: "old_idx"}
				if action != "drop" {
					edit.Columns = []string{"id"}
				}
				draft.Indexes = []tableedit.IndexEdit{edit}
			}
			p, err := store.PreviewContext(ctx, s, loaded.Baseline.ID, draft)
			if err != nil {
				t.Fatal(err)
			}
			if len(p.Plan.Conditions) == 0 {
				t.Fatal("reviewed removal condition missing")
			}
			retained, err := pgAdvancedRestoreAfterOperations(*loaded.Baseline, []tableedit.Operation{p.Plan.Conditions[0].Operation})
			if err != nil {
				t.Fatal(err)
			}
			for _, row := range retained.AdvancedEvidence.Rows[loaded.Baseline.Identity+"/indexes"] {
				if row["class"].(map[string]any)["relname"] == "old_idx" {
					t.Fatal("explicitly removed native index remained in restoration inputs")
				}
			}
			alteration := false
			for _, unit := range p.Plan.SQL {
				if strings.HasPrefix(unit, "ALTER TABLE ") && strings.Contains(unit, " TYPE ") {
					alteration = true
					if strings.Contains(unit, "old_idx") || !strings.Contains(unit, "retained_idx") {
						t.Fatal("later ALTER restored a removed object or omitted retained properties")
					}
				}
			}
			if !alteration {
				t.Fatal("reviewed multi-unit conversion was not emitted")
			}
			out, err := store.Apply(ctx, s, tableedit.Apply{PlanID: p.Plan.ID, Digest: p.Plan.Digest, ExecutionID: tableedit.Token()})
			if err != nil || out.Outcome.State != "applied" {
				t.Fatalf("reviewed removal followed by widening failed: outcome=%v", out.Outcome)
			}
			for _, step := range out.Outcome.Steps {
				if step.State != "applied" || step.Message != "" {
					t.Fatal("reviewed multi-unit conversion did not complete")
				}
			}
			var values []string
			rows, err := f.observer.Query(ctx, "SELECT COALESCE(n::pg_catalog.text,'sql-null') FROM "+f.table("multi_rewrite")+" ORDER BY n NULLS LAST")
			if err != nil {
				t.Fatal("retained integers unavailable")
			}
			for rows.Next() {
				var value string
				if rows.Scan(&value) != nil {
					rows.Close()
					t.Fatal("retained integer invalid")
				}
				values = append(values, value)
			}
			rows.Close()
			if rows.Err() != nil || !reflect.DeepEqual(values, []string{"-2147483648", "2147483647", "sql-null"}) {
				t.Fatal("widening after removal changed exact retained values")
			}
			if mode == "replaceIndex" {
				var defaultOptions bool
				if f.observer.QueryRow(ctx, `SELECT c.reloptions IS NULL FROM pg_catalog.pg_class c JOIN pg_catalog.pg_namespace n ON n.oid=c.relnamespace WHERE n.nspname=$1 AND c.relname='old_idx'`, f.schema).Scan(&defaultOptions) != nil || !defaultOptions {
					t.Fatal("replacement inherited the removed index's old settings")
				}
			}
		})
	}
}
