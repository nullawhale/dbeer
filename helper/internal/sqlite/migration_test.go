package sqlite

import (
	"context"
	"dbeer/helper/internal/tableedit"
	"testing"
)

func TestMigrationSQLitePreservesStorageClassesAndOriginalSettings(t *testing.T) {
	s := toolSession(t)
	ctx := context.Background()
	toolExec(t, s, "PRAGMA foreign_keys=ON")
	toolExec(t, s, "CREATE TABLE first(id INTEGER PRIMARY KEY, value ANY) STRICT")
	toolExec(t, s, "CREATE TABLE second(id INTEGER PRIMARY KEY AUTOINCREMENT, retained BLOB)")
	toolExec(t, s, "INSERT INTO first VALUES(1,NULL),(2,''),(3,'NULL'),(4,9007199254740993),(5,X'00ff')")
	toolExec(t, s, "INSERT INTO second(id,retained) VALUES(7,X'00ff'),(9,X'')")
	d := tableedit.MigrationDraft{Version: 1, Objects: []tableedit.MigrationObject{}, Repairs: []tableedit.MigrationRepair{}}
	for _, name := range []string{"first", "second"} {
		d.Objects = append(d.Objects, tableedit.MigrationObject{ID: name, Target: tableedit.Target{Schema: "main", Table: name}, After: []string{}, Draft: tableedit.Draft{AuthoringVersion: 5, AllowDestructive: true, Columns: []tableedit.Column{}, Reconstruct: true}})
	}
	store := &tableedit.MigrationStore{}
	p, err := store.Preview(ctx, s, d)
	if err != nil {
		t.Fatal(err)
	}
	if !p.Plan.Steps[0].Atomic || !p.Plan.Steps[1].Atomic {
		t.Fatal("SQLite reconstruction units lost atomic boundary")
	}
	out, err := store.Apply(ctx, s, tableedit.Apply{PlanID: p.Plan.ID, Digest: p.Plan.Digest, ExecutionID: "sqlite_migration"})
	if err != nil || out.Outcome.State != "applied" {
		t.Fatalf("SQLite migration failed: %#v %v", out.Outcome, err)
	}
	rows, _, err := s.query(ctx, "SELECT typeof(value),quote(value) FROM first ORDER BY id")
	if err != nil || len(rows) != 5 || cellText(rows[0][0]) != "null" || cellText(rows[1][1]) != "''" || cellText(rows[2][1]) != "'NULL'" || cellText(rows[3][1]) != "9007199254740993" || cellText(rows[4][1]) != "X'00FF'" {
		t.Fatal("SQLite migration changed exact native values")
	}
	setting, _, err := s.query(ctx, "PRAGMA foreign_keys")
	if err != nil || cellInt(setting[0][0]) != 1 {
		t.Fatal("dedicated-session foreign_keys setting was not restored")
	}
	toolExec(t, s, "INSERT INTO second(retained) VALUES(X'01')")
	seq, _, err := s.query(ctx, "SELECT max(id) FROM second")
	if err != nil || cellInt(seq[0][0]) != 10 {
		t.Fatal("AUTOINCREMENT state changed")
	}
}
func TestMigrationSQLitePartialCancellationRetainsUnstartedIntent(t *testing.T) {
	s := toolSession(t)
	ctx, cancel := context.WithCancel(context.Background())
	defer cancel()
	for _, name := range []string{"first", "second"} {
		toolExec(t, s, "CREATE TABLE "+quote(name)+"(id INTEGER)")
	}
	d := tableedit.MigrationDraft{Version: 1, Objects: []tableedit.MigrationObject{}, Repairs: []tableedit.MigrationRepair{}}
	for _, name := range []string{"first", "second"} {
		d.Objects = append(d.Objects, tableedit.MigrationObject{ID: name, Target: tableedit.Target{Schema: "main", Table: name}, After: []string{}, Draft: tableedit.Draft{Columns: []tableedit.Column{{Name: "added", Type: tableedit.DataType{Kind: "integer"}, Nullable: true, Default: tableedit.Default{Kind: "none"}}}}})
	}
	store := &tableedit.MigrationStore{}
	p, err := store.Preview(ctx, s, d)
	if err != nil {
		t.Fatal(err)
	}
	s.structureAfterStep = func(_ int) { cancel() }
	out, err := store.Apply(ctx, s, tableedit.Apply{PlanID: p.Plan.ID, Digest: p.Plan.Digest, ExecutionID: "cancelled"})
	if err != nil || out.Outcome.Steps[1].State != "notStarted" || !out.Outcome.ReconciliationRequired || out.Draft == nil {
		t.Fatal("cancelled SQLite intent or atomic rollback evidence was lost")
	}
	if _, err = store.Preview(context.Background(), s, d); err == nil {
		t.Fatal("cancelled intent bypassed reconciliation")
	}
}
