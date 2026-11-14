package mysql

import (
	"context"
	"dbeer/helper/internal/tableedit"
	"fmt"
	"io"
	"os"
	"testing"
	"time"
)

func myMigrationReview(t *testing.T, s *Session, d tableedit.MigrationDraft) (*tableedit.MigrationStore, *tableedit.MigrationPlan) {
	t.Helper()
	store := &tableedit.MigrationStore{}
	reply, err := store.Preview(context.Background(), s, d)
	if err != nil {
		t.Fatal(err)
	}
	return store, reply.Plan
}
func myMigrationApply(t *testing.T, s *Session, store *tableedit.MigrationStore, p *tableedit.MigrationPlan) *tableedit.MigrationOutcome {
	t.Helper()
	reply, err := store.Apply(context.Background(), s, tableedit.Apply{PlanID: p.ID, Digest: p.Digest, ExecutionID: "migration"})
	if err != nil {
		t.Fatal(err)
	}
	if reply.Outcome.State != "applied" {
		for _, step := range reply.Outcome.Steps {
			t.Logf("step %s state=%s message=%s", step.ID, step.State, step.Message)
			for _, x := range step.Statements {
				t.Logf("statement state=%s message=%s", x.State, x.Message)
			}
		}
	}
	return reply.Outcome
}
func myMigrationFixture(t *testing.T) (*Session, *Session, tableedit.Target, tableedit.Target) {
	t.Helper()
	if os.Getenv("DBEER_TEST_MYSQL_STRUCTURE_PRIVILEGES") != "1" {
		t.Skip("requires isolated complete structure metadata fixture")
	}
	s, observer := integrationSession(t), integrationSession(t)
	schema := integrationSettings(t).Database
	suffix := fmt.Sprint(time.Now().UnixNano())
	parent := tableedit.Target{Schema: schema, Table: "e5_parent_" + suffix}
	child := tableedit.Target{Schema: schema, Table: "e5_child_" + suffix}
	if external := os.Getenv("DBEER_TEST_MYSQL_NATIVE_SCHEMA"); external != "" {
		child.Schema = external
	}
	table := func(x tableedit.Target) string { return QuoteIdentifier(x.Schema) + "." + QuoteIdentifier(x.Table) }
	run(t, observer, "CREATE TABLE "+table(parent)+"(id INT PRIMARY KEY,retained VARBINARY(8))")
	run(t, observer, "CREATE TABLE "+table(child)+"(parent_id INT,CONSTRAINT "+QuoteIdentifier("e5_fk_"+suffix)+" FOREIGN KEY(parent_id) REFERENCES "+table(parent)+"(id))")
	run(t, observer, "INSERT INTO "+table(parent)+" VALUES(1,X'00ff')")
	run(t, observer, "INSERT INTO "+table(child)+" VALUES(1),(NULL)")
	t.Cleanup(func() {
		run(t, observer, "DROP TABLE IF EXISTS "+table(child))
		run(t, observer, "DROP TABLE IF EXISTS "+table(parent))
	})
	return s, observer, parent, child
}
func TestMigrationSelectedRepairExplicitRenameLive(t *testing.T) {
	s, observer, parent, child := myMigrationFixture(t)
	ctx := context.Background()
	b, err := s.StructureLoad(ctx, child)
	if err != nil {
		t.Fatal(err)
	}
	fk := ""
	for _, k := range b.Keys {
		if k.Kind == "foreign" {
			fk = k.Name
		}
	}
	renamed := parent.Table + "_new"
	column := "new_id"
	ref := tableedit.Target{Schema: parent.Schema, Table: renamed}
	replacement := tableedit.KeyEdit{Action: "add", Kind: "foreign", Name: fk, Columns: []string{"parent_id"}, Reference: &ref, ReferenceColumns: []string{column}, OnUpdate: "RESTRICT", OnDelete: "RESTRICT"}
	t.Cleanup(func() {
		run(t, observer, "DROP TABLE IF EXISTS "+QuoteIdentifier(child.Schema)+"."+QuoteIdentifier(child.Table))
		run(t, observer, "DROP TABLE IF EXISTS "+QuoteIdentifier(ref.Schema)+"."+QuoteIdentifier(ref.Table))
	})
	d := tableedit.MigrationDraft{Version: 1, Objects: []tableedit.MigrationObject{{ID: "parent", Target: parent, Draft: tableedit.Draft{AuthoringVersion: 2, Columns: []tableedit.Column{}, Changes: []tableedit.ColumnChange{{Name: "id", RenameTo: &column}}, RenameTable: &renamed}, After: []string{}}}, Repairs: []tableedit.MigrationRepair{{ID: "selected", Target: child, Key: fk, Action: "replace", Replacement: &replacement}}}
	without := d
	without.Repairs = []tableedit.MigrationRepair{}
	if _, err := (&tableedit.MigrationStore{}).Preview(ctx, s, without); err == nil {
		t.Fatal("unselected owner was silently rewritten")
	}
	store, p := myMigrationReview(t, s, d)
	if len(p.Steps) != 3 {
		t.Fatal("explicit repair phases missing")
	}
	out := myMigrationApply(t, s, store, p)
	if out.State != "applied" {
		t.Fatal("reviewed rename migration did not complete")
	}
	values, err := observer.work.client.Execute("SELECT HEX(retained) FROM " + QuoteIdentifier(ref.Schema) + "." + QuoteIdentifier(ref.Table) + " WHERE " + QuoteIdentifier(column) + "=1")
	if err != nil {
		t.Fatal("renamed value cannot be read")
	}
	defer values.Close()
	value, _ := values.GetString(0, 0)
	if value != "00FF" {
		t.Fatal("retained binary value changed")
	}
	after, err := s.StructureLoad(ctx, ref)
	if err != nil || len(after.Facts.Incoming) != 1 || after.Facts.Incoming[0].Columns[0] != column {
		t.Fatal("explicit restored mapping missing")
	}
}
func TestMigrationRestoreFailureAndUnknownAcknowledgementLive(t *testing.T) {
	for _, unknown := range []bool{false, true} {
		name := "known_restore"
		if unknown {
			name = "unknown_ack"
		}
		t.Run(name, func(t *testing.T) {
			s, observer, parent, child := myMigrationFixture(t)
			ctx := context.Background()
			b, err := s.StructureLoad(ctx, child)
			if err != nil {
				t.Fatal(err)
			}
			fk := ""
			for _, k := range b.Keys {
				if k.Kind == "foreign" {
					fk = k.Name
				}
			}
			replacement := tableedit.KeyEdit{Action: "add", Kind: "foreign", Name: fk, Columns: []string{"parent_id"}, Reference: &parent, ReferenceColumns: []string{"id"}, OnUpdate: "RESTRICT", OnDelete: "RESTRICT"}
			col := tableedit.Column{Name: "added", Type: tableedit.DataType{Kind: "integer"}, Nullable: true, Default: tableedit.Default{Kind: "none"}}
			d := tableedit.MigrationDraft{Version: 1, Objects: []tableedit.MigrationObject{{ID: "parent", Target: parent, Draft: tableedit.Draft{Columns: []tableedit.Column{col}}, After: []string{}}}, Repairs: []tableedit.MigrationRepair{{ID: "selected", Target: child, Key: fk, Action: "replace", Replacement: &replacement}}}
			store, p := myMigrationReview(t, s, d)
			if unknown {
				s.structureExecuteOverride = func(execute func() error) error {
					if err := execute(); err != nil {
						return err
					}
					return io.EOF
				}
			} else {
				s.afterStructureStep = func(_ int) {
					run(t, observer, "INSERT INTO "+QuoteIdentifier(child.Schema)+"."+QuoteIdentifier(child.Table)+" VALUES(999)")
					s.afterStructureStep = nil
				}
			}
			out := myMigrationApply(t, s, store, p)
			want := "partiallyApplied"
			if unknown {
				want = "outcomeUnknown"
			}
			if out.State != want || !out.ReconciliationRequired {
				t.Fatal("partial or unknown evidence missing")
			}
			if unknown && out.Steps[1].State != "notStarted" {
				t.Fatal("unknown acknowledgement advanced migration")
			}
			if !unknown && out.Steps[2].Statements[0].State != "failed" {
				t.Fatal("restore was not a known rejection")
			}
			if _, err = store.Apply(ctx, s, tableedit.Apply{PlanID: p.ID, Digest: p.Digest, ExecutionID: "again"}); err == nil {
				t.Fatal("partial/unknown migration replayed")
			}
		})
	}
}
func TestMigrationMetadataOnlyPreviewAndStaleGuardLive(t *testing.T) {
	s, observer, parent, child := myMigrationFixture(t)
	ctx := context.Background()
	expression := "UUID_SHORT()"
	d := tableedit.MigrationDraft{Version: 1, Objects: []tableedit.MigrationObject{{ID: "parent", Target: parent, Draft: tableedit.Draft{AuthoringVersion: 2, Columns: []tableedit.Column{{Name: "token", Type: tableedit.DataType{Kind: "bigint"}, Nullable: true, Default: tableedit.Default{Kind: "expression", Value: &expression}}}}, After: []string{}}}, Repairs: []tableedit.MigrationRepair{}}
	before, err := observer.work.client.Execute("SELECT UUID_SHORT()")
	if err != nil {
		t.Fatal("cannot establish preview control")
	}
	value, _ := before.GetUint(0, 0)
	before.Close()
	store, p := myMigrationReview(t, s, d)
	after, err := observer.work.client.Execute("SELECT UUID_SHORT()")
	if err != nil {
		t.Fatal("cannot inspect preview control")
	}
	next, _ := after.GetUint(0, 0)
	after.Close()
	if next != value+1 {
		t.Fatal("Preview evaluated authored code")
	}
	run(t, observer, "ALTER TABLE "+QuoteIdentifier(child.Schema)+"."+QuoteIdentifier(child.Table)+" ADD COLUMN concurrent INT")
	out := myMigrationApply(t, s, store, p)
	if out.State != "failed" || out.Steps[0].Statements[0].State != "notStarted" {
		t.Fatal("stale external guard dispatched migration")
	}
	_ = ctx
}
