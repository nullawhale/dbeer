package postgres

import (
	"context"
	"errors"
	"testing"

	"dbeer/helper/internal/tableedit"
	"github.com/jackc/pgx/v5"
)

func pgMigrationReview(t *testing.T, s *Session, d tableedit.MigrationDraft) (*tableedit.MigrationStore, *tableedit.MigrationPlan) {
	t.Helper()
	store := &tableedit.MigrationStore{}
	reply, err := store.Preview(context.Background(), s, d)
	if err != nil {
		t.Fatal(err)
	}
	return store, reply.Plan
}
func pgMigrationApply(t *testing.T, s *Session, store *tableedit.MigrationStore, p *tableedit.MigrationPlan) *tableedit.MigrationOutcome {
	t.Helper()
	reply, err := store.Apply(context.Background(), s, tableedit.Apply{PlanID: p.ID, Digest: p.Digest, ExecutionID: "migration"})
	if err != nil {
		t.Fatal(err)
	}
	if reply.Outcome.State != "applied" {
		for _, step := range reply.Outcome.Steps {
			t.Logf("migration step %s state=%s message=%s", step.ID, step.State, step.Message)
			for _, statement := range step.Statements {
				t.Logf("statement state=%s message=%s", statement.State, statement.Message)
			}
		}
	}
	return reply.Outcome
}
func TestMigrationSelectedCrossSchemaRepairAndExplicitRenameLive(t *testing.T) {
	f := newChangeFixture(t)
	s := &Session{conn: f.conn}
	ctx := context.Background()
	other := f.schema + "_e5"
	f.exec("CREATE SCHEMA " + pgx.Identifier{other}.Sanitize())
	t.Cleanup(func() { _, _ = f.observer.Exec(ctx, "DROP SCHEMA "+pgx.Identifier{other}.Sanitize()+" CASCADE") })
	parent := tableedit.Target{Schema: f.schema, Table: "e5_parent"}
	child := tableedit.Target{Schema: other, Table: "e5_child"}
	renamed := "e5_renamed"
	column := "new_id"
	parentSQL := f.table(parent.Table)
	childSQL := pgx.Identifier{other, child.Table}.Sanitize()
	f.exec("CREATE TABLE " + parentSQL + "(id integer PRIMARY KEY, retained bytea)")
	f.exec("CREATE TABLE " + childSQL + "(parent_id integer, CONSTRAINT e5_selected FOREIGN KEY(parent_id) REFERENCES " + parentSQL + "(id))")
	f.exec("INSERT INTO " + parentSQL + " VALUES(7,decode('00ff','hex'))")
	f.exec("INSERT INTO " + childSQL + " VALUES(7),(NULL)")
	ref := tableedit.Target{Schema: f.schema, Table: renamed}
	replacement := tableedit.KeyEdit{Action: "add", Kind: "foreign", Name: "e5_selected", Columns: []string{"parent_id"}, Reference: &ref, ReferenceColumns: []string{column}, OnUpdate: "NO ACTION", OnDelete: "NO ACTION"}
	d := tableedit.MigrationDraft{Version: 1, Objects: []tableedit.MigrationObject{{ID: "parent", Target: parent, Draft: tableedit.Draft{AuthoringVersion: 2, Columns: []tableedit.Column{}, Changes: []tableedit.ColumnChange{{Name: "id", RenameTo: &column}}, RenameTable: &renamed}, After: []string{}}}, Repairs: []tableedit.MigrationRepair{{ID: "selected", Target: child, Key: "e5_selected", Action: "replace", Replacement: &replacement}}}
	without := d
	without.Repairs = []tableedit.MigrationRepair{}
	if _, err := (&tableedit.MigrationStore{}).Preview(ctx, s, without); err == nil {
		t.Fatal("unselected external FK owner was silently rewritten")
	}
	store, p := pgMigrationReview(t, s, d)
	if len(p.Steps) != 3 || len(p.Steps[1].Before) < 3 || len(p.Steps[1].Before[0].AfterSteps) != 1 {
		t.Fatal("repair order or expected intermediate structures missing")
	}
	var exists bool
	if f.observer.QueryRow(ctx, "SELECT to_regclass($1) IS NOT NULL", parentSQL).Scan(&exists) != nil || !exists {
		t.Fatal("Preview executed rename")
	}
	out := pgMigrationApply(t, s, store, p)
	if out.State != "applied" {
		t.Fatalf("rename migration stopped: %#v", out)
	}
	for _, step := range out.Steps {
		if step.Message != "" {
			t.Fatal(step.Message)
		}
		for _, x := range step.Statements {
			if x.Message != "" {
				t.Fatal(x.Message)
			}
		}
	}
	result, err := s.StructureLoad(ctx, ref)
	if err != nil || len(result.Facts.Incoming) != 1 || result.Facts.Incoming[0].Name != "e5_selected" || result.Facts.Incoming[0].Columns[0] != column {
		t.Fatal("explicit restored FK mapping missing")
	}
	var binary string
	if f.observer.QueryRow(ctx, "SELECT encode(retained,'hex') FROM "+f.table(renamed)+" WHERE "+pgx.Identifier{column}.Sanitize()+"=7").Scan(&binary) != nil || binary != "00ff" {
		t.Fatal("rename changed exact retained values")
	}
	if _, err = store.Apply(ctx, s, tableedit.Apply{PlanID: p.ID, Digest: p.Digest, ExecutionID: "replay"}); err == nil {
		t.Fatal("migration replayed")
	}
	if _, err = store.Reconcile(ctx, s); err != nil {
		t.Fatal("renamed and original targets could not reconcile")
	}
}
func TestMigrationPartialRestoreFailureAndUnknownCommitLive(t *testing.T) {
	for _, unknown := range []bool{false, true} {
		name := "known_restore"
		if unknown {
			name = "unknown_commit"
		}
		t.Run(name, func(t *testing.T) {
			f := newChangeFixture(t)
			s := &Session{conn: f.conn}
			parent := tableedit.Target{Schema: f.schema, Table: "e5_parent"}
			child := tableedit.Target{Schema: f.schema, Table: "e5_child"}
			f.exec("CREATE TABLE " + f.table(parent.Table) + "(id integer PRIMARY KEY)")
			f.exec("CREATE TABLE " + f.table(child.Table) + "(parent_id integer,CONSTRAINT e5_selected FOREIGN KEY(parent_id) REFERENCES " + f.table(parent.Table) + "(id))")
			f.exec("INSERT INTO " + f.table(parent.Table) + " VALUES(1)")
			f.exec("INSERT INTO " + f.table(child.Table) + " VALUES(1)")
			replacement := tableedit.KeyEdit{Action: "add", Kind: "foreign", Name: "e5_selected", Columns: []string{"parent_id"}, Reference: &parent, ReferenceColumns: []string{"id"}, OnUpdate: "NO ACTION", OnDelete: "NO ACTION"}
			col := tableedit.Column{Name: "added", Type: tableedit.DataType{Kind: "integer"}, Nullable: true, Default: tableedit.Default{Kind: "none"}}
			d := tableedit.MigrationDraft{Version: 1, Objects: []tableedit.MigrationObject{{ID: "parent", Target: parent, Draft: tableedit.Draft{Columns: []tableedit.Column{col}}, After: []string{}}}, Repairs: []tableedit.MigrationRepair{{ID: "selected", Target: child, Key: "e5_selected", Action: "replace", Replacement: &replacement}}}
			store, p := pgMigrationReview(t, s, d)
			if unknown {
				s.structureCommitOverride = func(commit func() error) error {
					if err := commit(); err != nil {
						return err
					}
					return errors.New("synthetic lost acknowledgement")
				}
			} else {
				s.afterStructureStep = func(_ int) {
					f.exec("INSERT INTO " + f.table(child.Table) + " VALUES(999)")
					s.afterStructureStep = nil
				}
			}
			out := pgMigrationApply(t, s, store, p)
			want := "partiallyApplied"
			if unknown {
				want = "outcomeUnknown"
			}
			if out.State != want || !out.ReconciliationRequired {
				t.Fatalf("lost known/unknown migration evidence: %#v", out)
			}
			if out.Steps[1].State != "notStarted" && unknown {
				t.Fatal("unknown commit advanced migration")
			}
			if !unknown && out.Steps[2].Statements[0].State != "failed" {
				t.Fatal("restore failure was not a known rejection")
			}
			if _, err := store.Apply(context.Background(), s, tableedit.Apply{PlanID: p.ID, Digest: p.Digest, ExecutionID: "again"}); err == nil {
				t.Fatal("partial/unknown execution replayed")
			}
			if _, err := store.Preview(context.Background(), s, d); err == nil {
				t.Fatal("partial/unknown intent bypassed reconciliation")
			}
		})
	}
}
func TestMigrationMetadataPreviewDoesNotEvaluateAndStaleGuardLive(t *testing.T) {
	f := newChangeFixture(t)
	s := &Session{conn: f.conn}
	ctx := context.Background()
	f.exec("CREATE SEQUENCE " + f.table("e5_preview_counter"))
	f.exec("CREATE FUNCTION " + f.table("e5_default") + "() RETURNS integer LANGUAGE sql VOLATILE AS 'SELECT nextval(''" + f.table("e5_preview_counter") + "'')::integer'")
	for _, name := range []string{"e5_a", "e5_b"} {
		f.exec("CREATE TABLE " + f.table(name) + "(id integer)")
	}
	expression := f.table("e5_default") + "()"
	d := tableedit.MigrationDraft{Version: 1, Objects: []tableedit.MigrationObject{}, Repairs: []tableedit.MigrationRepair{}}
	for _, name := range []string{"e5_a", "e5_b"} {
		d.Objects = append(d.Objects, tableedit.MigrationObject{ID: name, Target: tableedit.Target{Schema: f.schema, Table: name}, After: []string{}, Draft: tableedit.Draft{AuthoringVersion: 2, Columns: []tableedit.Column{{Name: "generated_default", Type: tableedit.DataType{Kind: "integer"}, Nullable: true, Default: tableedit.Default{Kind: "expression", Value: &expression}}}}})
	}
	store, p := pgMigrationReview(t, s, d)
	var called bool
	if f.observer.QueryRow(ctx, "SELECT is_called FROM "+f.table("e5_preview_counter")).Scan(&called) != nil || called {
		t.Fatal("metadata Preview evaluated authored support")
	}
	f.exec("ALTER TABLE " + f.table("e5_b") + " ADD COLUMN concurrent integer")
	out := pgMigrationApply(t, s, store, p)
	if out.State != "failed" || out.Steps[0].Statements[0].State != "notStarted" {
		t.Fatal("stale guarded table dispatched migration")
	}
}

func TestMigrationSelectedRepairAroundAtomicReconstructionLive(t *testing.T) {
	f := newChangeFixture(t)
	s := &Session{conn: f.conn}
	ctx := context.Background()
	parent := tableedit.Target{Schema: f.schema, Table: "e5_rebuild_parent"}
	child := tableedit.Target{Schema: f.schema, Table: "e5_rebuild_child"}
	f.exec("CREATE TABLE " + f.table(parent.Table) + "(id integer PRIMARY KEY, amount numeric(30,10))")
	f.exec("CREATE TABLE " + f.table(child.Table) + "(parent_id integer,CONSTRAINT e5_selected FOREIGN KEY(parent_id) REFERENCES " + f.table(parent.Table) + "(id))")
	f.exec("INSERT INTO " + f.table(parent.Table) + " VALUES(1,12345678901234567890.0123456789)")
	f.exec("INSERT INTO " + f.table(child.Table) + " VALUES(1)")
	before, err := s.StructureLoad(ctx, parent)
	if err != nil {
		t.Fatal(err)
	}
	replacement := tableedit.KeyEdit{Action: "add", Kind: "foreign", Name: "e5_selected", Columns: []string{"parent_id"}, Reference: &parent, ReferenceColumns: []string{"id"}, OnUpdate: "NO ACTION", OnDelete: "NO ACTION"}
	d := tableedit.MigrationDraft{Version: 1, Objects: []tableedit.MigrationObject{{ID: "parent", Target: parent, After: []string{}, Draft: tableedit.Draft{AuthoringVersion: 5, AllowDestructive: true, Columns: []tableedit.Column{}, ColumnOrder: []string{"amount", "id"}, Reconstruct: true}}}, Repairs: []tableedit.MigrationRepair{{ID: "selected", Target: child, Key: "e5_selected", Action: "replace", Replacement: &replacement}}}
	store, p := pgMigrationReview(t, s, d)
	if !p.Steps[1].Atomic {
		t.Fatal("transactional reconstruction boundary lost")
	}
	out := pgMigrationApply(t, s, store, p)
	if out.State != "applied" {
		t.Fatal("selected reconstruction repair did not complete")
	}
	after, err := s.StructureLoad(ctx, parent)
	if err != nil || before.Identity == after.Identity || after.Columns[0].Name != "amount" || len(after.Facts.Incoming) != 1 {
		t.Fatal("physical reconstruction or explicit restoration missing")
	}
	var amount string
	if f.observer.QueryRow(ctx, "SELECT amount::text FROM "+f.table(parent.Table)).Scan(&amount) != nil || amount != "12345678901234567890.0123456789" {
		t.Fatal("exact numeric changed across migration reconstruction")
	}
}

func TestMigrationDependencyOrdersNewTablesAndExistingDropsLive(t *testing.T) {
	f := newChangeFixture(t)
	s := &Session{conn: f.conn}
	parent := tableedit.Target{Schema: f.schema, Table: "e5_created_parent", Create: true}
	child := tableedit.Target{Schema: f.schema, Table: "e5_created_child", Create: true}
	ref := parent
	ref.Create = false
	integer := tableedit.DataType{Kind: "integer"}
	column := tableedit.Column{Name: "id", Type: integer, Nullable: false, Default: tableedit.Default{Kind: "none"}}
	d := tableedit.MigrationDraft{Version: 1, Objects: []tableedit.MigrationObject{{ID: "a_child", Target: child, After: []string{}, Draft: tableedit.Draft{Columns: []tableedit.Column{column}, Keys: []tableedit.KeyEdit{{Action: "add", Kind: "foreign", Name: "e5_fk", Columns: []string{"id"}, Reference: &ref, ReferenceColumns: []string{"id"}, OnUpdate: "NO ACTION", OnDelete: "NO ACTION"}}}}, {ID: "z_parent", Target: parent, After: []string{}, Draft: tableedit.Draft{Columns: []tableedit.Column{column}, Keys: []tableedit.KeyEdit{{Action: "add", Kind: "primary", Name: "e5_pk", Columns: []string{"id"}}}}}}, Repairs: []tableedit.MigrationRepair{}}
	store, p := pgMigrationReview(t, s, d)
	if p.Steps[0].ObjectID != "z_parent" {
		t.Fatal("new referenced key was not ordered before its FK")
	}
	if out := pgMigrationApply(t, s, store, p); out.State != "applied" {
		t.Fatal("dependency-ordered creation failed")
	}
	parent.Create = false
	child.Create = false
	drop := tableedit.Draft{AuthoringVersion: 4, Columns: []tableedit.Column{}, DropTable: true, AllowDestructive: true}
	d = tableedit.MigrationDraft{Version: 1, Objects: []tableedit.MigrationObject{{ID: "a_parent", Target: parent, Draft: drop, After: []string{}}, {ID: "z_child", Target: child, Draft: drop, After: []string{}}}, Repairs: []tableedit.MigrationRepair{}}
	store, p = pgMigrationReview(t, s, d)
	if p.Steps[0].ObjectID != "z_child" {
		t.Fatal("incoming table drop was not ordered before referenced table drop")
	}
	if out := pgMigrationApply(t, s, store, p); out.State != "applied" {
		t.Fatal("dependency-ordered drop failed")
	}
}
