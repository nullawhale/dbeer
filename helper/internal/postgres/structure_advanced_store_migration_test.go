package postgres

import (
	"context"
	"reflect"
	"strings"
	"testing"

	"dbeer/helper/internal/tableedit"
)

func TestStructureAdvancedStoreSelectedRepairMigrationLive(t *testing.T) {
	for _, mode := range []string{"replaceBoth", "permanentDrop", "unlogged", "nativeCluster", "unselected", "stalePolicy", "staleOwner", "lateOwnerProperty"} {
		t.Run(mode, func(t *testing.T) {
			f := newChangeFixture(t)
			ctx := context.Background()
			s := &Session{conn: f.conn}
			persistence := ""
			if mode == "unlogged" {
				persistence = "UNLOGGED "
			}
			f.exec("CREATE " + persistence + "TABLE " + f.table("secured") + "(id integer PRIMARY KEY,payload text,n numeric(30,4),b bytea)")
			f.exec("ALTER TABLE " + f.table("secured") + " ENABLE ROW LEVEL SECURITY")
			f.exec("ALTER TABLE " + f.table("secured") + " FORCE ROW LEVEL SECURITY")
			f.exec("CREATE POLICY retained ON " + f.table("secured") + " USING(id>0) WITH CHECK(id>0)")
			f.exec("INSERT INTO " + f.table("secured") + " VALUES(1,'',12345678901234567890.1234,decode('00ff','hex')),(2,'NULL',NULL,NULL),(3,NULL,-123.4000,decode('ff00','hex'))")
			target := tableedit.Target{Schema: f.schema, Table: "secured"}
			repairs := []tableedit.MigrationRepair{}
			for _, name := range []string{"owner_one", "owner_two"} {
				f.exec("CREATE " + persistence + "TABLE " + f.table(name) + "(ref integer,payload text,CONSTRAINT selected FOREIGN KEY(ref) REFERENCES " + f.table("secured") + "(id))")
				f.exec("INSERT INTO " + f.table(name) + " VALUES(1,''),(1,''),(NULL,'NULL'),(NULL,NULL)")
				if mode == "unselected" && name == "owner_two" {
					continue
				}
				replacement := &tableedit.KeyEdit{Action: "add", Kind: "foreign", Name: "selected", Columns: []string{"ref"}, Reference: &target, ReferenceColumns: []string{"id"}, OnUpdate: "NO ACTION", OnDelete: "NO ACTION"}
				repair := tableedit.MigrationRepair{ID: "repair_" + name, Target: tableedit.Target{Schema: f.schema, Table: name}, Key: "selected", Action: "replace", Replacement: replacement}
				if mode == "permanentDrop" {
					repair.Action = "drop"
					repair.Replacement = nil
				}
				repairs = append(repairs, repair)
			}
			before, err := s.StructureLoad(ctx, target)
			if err != nil {
				t.Fatal(err)
			}
			originalRows := func() [][]any {
				rows, err := f.observer.Query(ctx, "SELECT id::pg_catalog.text,payload,n::pg_catalog.text,pg_catalog.encode(b,'hex') FROM "+f.table("secured")+" ORDER BY id")
				if err != nil {
					t.Fatal("migration retained rows unavailable")
				}
				out := [][]any{}
				for rows.Next() {
					v, err := rows.Values()
					if err != nil {
						rows.Close()
						t.Fatal("migration retained row invalid")
					}
					out = append(out, v)
				}
				rows.Close()
				if rows.Err() != nil {
					t.Fatal("migration retained rows incomplete")
				}
				return out
			}
			rowsBefore := originalRows()
			draft := tableedit.MigrationDraft{Version: 1, Objects: []tableedit.MigrationObject{{ID: "reorder", Target: target, Draft: tableedit.Draft{AuthoringVersion: 5, AllowDestructive: true, Columns: []tableedit.Column{}, ColumnOrder: []string{"payload", "n", "b", "id"}, Reconstruct: true}, After: []string{}}}, Repairs: repairs}
			if mode == "nativeCluster" {
				draft.Objects[0].Draft.ColumnOrder = []string{"id", "payload", "n", "b"}
			}
			store := &tableedit.MigrationStore{}
			preview, err := store.Preview(ctx, s, draft)
			if mode == "unselected" {
				if err == nil {
					t.Fatal("unselected outside foreign key was admitted")
				}
				return
			}
			if err != nil {
				t.Fatal(err)
			}
			objectUnits := 0
			copyStatements := 0
			for _, unit := range preview.Plan.Steps {
				if unit.Phase == "object" {
					objectUnits++
					copyStatements = len(unit.SQL)
					if !unit.Atomic {
						t.Fatal("advanced reconstruction transaction was not disclosed as atomic")
					}
					for _, sql := range unit.SQL {
						if strings.Contains(sql, "DROP CONSTRAINT") || strings.Contains(sql, "CASCADE") {
							t.Fatal("copy unit silently removed an outside dependency")
						}
					}
				}
			}
			if objectUnits != 1 || copyStatements < 3 {
				t.Fatal("migration omitted the exact generic copy unit")
			}
			if mode == "stalePolicy" {
				f.exec("ALTER POLICY retained ON " + f.table("secured") + " USING(id>1)")
			}
			if mode == "staleOwner" {
				f.exec("COMMENT ON COLUMN " + f.table("owner_one") + ".payload IS 'external metadata drift'")
			}
			mutated := false
			var mutationError error
			if mode == "lateOwnerProperty" {
				s.afterStructureStep = func(i int) {
					if !mutated && i == copyStatements-2 {
						mutated = true
						_, mutationError = f.conn.Exec(ctx, "COMMENT ON COLUMN "+f.table("owner_one")+".payload IS 'late metadata drift'")
					}
				}
			}
			apply := tableedit.Apply{PlanID: preview.Plan.ID, Digest: preview.Plan.Digest, ExecutionID: tableedit.Token()}
			result, err := store.Apply(ctx, s, apply)
			if err != nil {
				t.Fatal(err)
			}
			if mutationError != nil {
				t.Fatal("owned late metadata control failed")
			}
			if mode == "stalePolicy" || mode == "staleOwner" {
				if result.Outcome.State != "failed" || result.Outcome.Steps[0].State != "notStarted" {
					t.Fatal("late captured metadata drift dispatched a repair")
				}
			} else if mode == "lateOwnerProperty" {
				if !mutated || result.Outcome.State != "partiallyApplied" {
					t.Fatal("late outside-owner property mutation did not stop the migration")
				}
				observed, err := s.StructureLoad(ctx, target)
				if err != nil || observed.Identity != before.Identity {
					t.Fatal("failed copy replaced its original source")
				}
			} else {
				if result.Outcome.State != "applied" {
					for _, unit := range result.Outcome.Steps {
						if unit.State != "applied" {
							t.Fatalf("normal selected-repair migration stopped: state=%s unit=%s message=%s", result.Outcome.State, unit.ID, unit.Message)
						}
					}
					t.Fatal("normal migration did not complete")
				}
				if !reflect.DeepEqual(rowsBefore, originalRows()) {
					t.Fatal("selected-repair reconstruction changed exact values")
				}
				observed, err := s.StructureLoad(ctx, target)
				if err != nil || (observed.Identity == before.Identity) != (mode == "nativeCluster") {
					t.Fatal("normal migration did not observe the reviewed relation identity transition")
				}
				for _, name := range []string{"owner_one", "owner_two"} {
					owner, err := s.StructureLoad(ctx, tableedit.Target{Schema: f.schema, Table: name})
					if err != nil {
						t.Fatal(err)
					}
					found := false
					for _, key := range owner.Keys {
						found = found || key.Kind == "foreign" && key.Name == "selected"
					}
					if found == (mode == "permanentDrop") {
						t.Fatal("selected foreign-key restoration/permanent removal mismatch")
					}
					var count int
					if f.observer.QueryRow(ctx, "SELECT count(*) FROM "+f.table(name)).Scan(&count) != nil || count != 4 {
						t.Fatal("outside owner rows or duplicates changed")
					}
				}
			}
			if _, err = store.Apply(ctx, s, tableedit.Apply{PlanID: apply.PlanID, Digest: apply.Digest, ExecutionID: tableedit.Token()}); err == nil {
				t.Fatal("migration retained replay authority")
			}
		})
	}
}

func TestStructureAdvancedMigrationMixedForeignUnitRejectedLive(t *testing.T) {
	f := newChangeFixture(t)
	ctx := context.Background()
	s := &Session{conn: f.conn}
	f.exec("CREATE TABLE " + f.table("secured") + "(id integer PRIMARY KEY)")
	f.exec("ALTER TABLE " + f.table("secured") + " ENABLE ROW LEVEL SECURITY")
	f.exec("CREATE POLICY retained ON " + f.table("secured") + " USING(id>0)")
	f.exec("CREATE TABLE " + f.table("owner") + "(ref integer,CONSTRAINT selected FOREIGN KEY(ref) REFERENCES " + f.table("secured") + "(id))")
	target := tableedit.Target{Schema: f.schema, Table: "owner"}
	before, err := s.StructureLoad(ctx, target)
	if err != nil {
		t.Fatal(err)
	}
	draft := tableedit.MigrationDraft{Version: 1, Objects: []tableedit.MigrationObject{{ID: "combined", Target: target, Draft: tableedit.Draft{AuthoringVersion: 3, AllowDestructive: true, Columns: []tableedit.Column{{Name: "extra", Type: tableedit.DataType{Kind: "integer"}, Nullable: true, Default: tableedit.Default{Kind: "none"}}}, Keys: []tableedit.KeyEdit{{Action: "drop", Kind: "foreign", Name: "selected"}}}, After: []string{}}}, Repairs: []tableedit.MigrationRepair{}}
	store := &tableedit.MigrationStore{}
	if _, err = store.Preview(ctx, s, draft); err == nil || !strings.Contains(err.Error(), "one explicit ADD or DROP") {
		t.Fatal("composite advanced FK migration did not refuse before any execution unit")
	}
	after, err := s.StructureLoad(ctx, target)
	if err != nil || before.Fingerprint != after.Fingerprint || store.Status().Plan != nil || store.Status().Outcome != nil {
		t.Fatal("refused composite migration changed metadata or retained Apply authority")
	}
}
