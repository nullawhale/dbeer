package sqlite

import (
	"context"
	"testing"

	"dbeer/helper/internal/tableedit"
)

func sqliteDropPreview(t *testing.T, s *Session, store *tableedit.Store, d tableedit.Draft) *tableedit.Plan {
	t.Helper()
	b, err := store.Load(context.Background(), s, tableedit.Target{Schema: "main", Table: "records"})
	if err != nil {
		t.Fatal(err)
	}
	p, err := store.PreviewContext(context.Background(), s, b.Baseline.ID, d)
	if err != nil {
		t.Fatal(err)
	}
	return p.Plan
}
func TestSQLiteDestructiveColumnValidationAndExactRemainingValues(t *testing.T) {
	s := toolSession(t)
	toolExec(t, s, "CREATE TABLE records(id INTEGER PRIMARY KEY, removed TEXT, retained BLOB)")
	toolExec(t, s, "INSERT INTO records VALUES(7,'drop',X'00FF'),(9,NULL,X'')")
	store := &tableedit.Store{}
	d := tableedit.Draft{AuthoringVersion: 4, Columns: []tableedit.Column{}, Changes: []tableedit.ColumnChange{{Name: "removed", Drop: true}}, AllowDestructive: true}
	p := sqliteDropPreview(t, s, store, d)
	if len(p.SQL) != 1 || !p.Destructive || len(p.Consequences) == 0 || len(p.ValidationChecks) != 1 {
		t.Fatal("incomplete drop review")
	}
	rows, _, err := s.query(context.Background(), "SELECT removed FROM records ORDER BY id")
	if err != nil || len(rows) != 2 {
		t.Fatal("Preview changed source values")
	}
	a := tableedit.Apply{PlanID: p.ID, Digest: p.Digest, ExecutionID: "validation"}
	v, err := store.Validate(context.Background(), s, a)
	if err != nil || v.Validation.State != "completed" || *v.Validation.Checks[0].InvalidRows != "2" {
		t.Fatalf("validation failed: %#v %v", v.Validation, err)
	}
	a.ExecutionID = "drop"
	out, err := store.Apply(context.Background(), s, a)
	if err != nil || out.Outcome.State != "applied" {
		t.Fatalf("drop failed: %#v %v", out.Outcome, err)
	}
	rows, _, err = s.query(context.Background(), "SELECT id,typeof(retained),hex(retained) FROM records ORDER BY id")
	if err != nil || cellInt(rows[0][0]) != 7 || cellText(rows[0][1]) != "blob" || cellText(rows[0][2]) != "00FF" || cellText(rows[1][2]) != "" {
		t.Fatal("remaining native values changed")
	}
	if _, err := store.Apply(context.Background(), s, a); err == nil {
		t.Fatal("DROP replayed")
	}
}
func TestSQLiteDestructiveTableDropAndDependencies(t *testing.T) {
	s := toolSession(t)
	toolExec(t, s, "CREATE TABLE records(id INTEGER PRIMARY KEY, value TEXT)")
	toolExec(t, s, "CREATE INDEX value_index ON records(value)")
	toolExec(t, s, "INSERT INTO records VALUES(1,'data')")
	store := &tableedit.Store{}
	d := tableedit.Draft{AuthoringVersion: 4, Columns: []tableedit.Column{}, DropTable: true, AllowDestructive: true}
	p := sqliteDropPreview(t, s, store, d)
	a := tableedit.Apply{PlanID: p.ID, Digest: p.Digest, ExecutionID: "drop"}
	out, err := store.Apply(context.Background(), s, a)
	if err != nil || out.Outcome.State != "applied" || !out.Outcome.DroppedTarget || out.Outcome.Observed != nil || out.Outcome.RefreshError != "" {
		t.Fatalf("acknowledged drop was not retained: %#v %v", out.Outcome, err)
	}
	toolExec(t, s, "CREATE TABLE records(id INTEGER PRIMARY KEY,value TEXT)")
	toolExec(t, s, "CREATE TABLE child(id INTEGER REFERENCES records(id))")
	b, err := store.Load(context.Background(), s, tableedit.Target{Schema: "main", Table: "records"})
	if err != nil {
		t.Fatal(err)
	}
	if _, err := store.PreviewContext(context.Background(), s, b.Baseline.ID, d); err == nil {
		t.Fatal("incoming FK silently removed")
	}
}
func TestSQLiteDestructiveDependencyAndVersionedIntentGuards(t *testing.T) {
	for _, dependent := range []string{"CREATE VIEW dependent AS SELECT value FROM records", "CREATE TRIGGER dependent AFTER UPDATE ON records BEGIN SELECT new.value; END", "CREATE INDEX dependent ON records(value)", "CREATE TABLE child(id INTEGER REFERENCES records(value))"} {
		t.Run(dependent, func(t *testing.T) {
			s := toolSession(t)
			toolExec(t, s, "CREATE TABLE records(id INTEGER,value TEXT,keep TEXT)")
			toolExec(t, s, dependent)
			b, err := s.StructureLoad(context.Background(), tableedit.Target{Schema: "main", Table: "records"})
			if err != nil {
				t.Fatal(err)
			}
			d := tableedit.Draft{AuthoringVersion: 4, Columns: []tableedit.Column{}, Changes: []tableedit.ColumnChange{{Name: "value", Drop: true}}, AllowDestructive: true}
			if _, err := s.StructurePrepare(context.Background(), b, d); err == nil {
				t.Fatal("dependent object silently damaged")
			}
		})
	}
	s := toolSession(t)
	toolExec(t, s, "CREATE TABLE records(id INTEGER,value TEXT)")
	toolExec(t, s, "CREATE TEMP VIEW temporary_dependency AS SELECT value FROM main.records")
	b, err := s.StructureLoad(context.Background(), tableedit.Target{Schema: "main", Table: "records"})
	if err != nil {
		t.Fatal(err)
	}
	d := tableedit.Draft{AuthoringVersion: 4, Columns: []tableedit.Column{}, DropTable: true, AllowDestructive: true}
	if _, err := s.StructurePrepare(context.Background(), b, d); err == nil {
		t.Fatal("temporary dependent view ignored")
	}
}
