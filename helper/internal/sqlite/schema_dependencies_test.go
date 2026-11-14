package sqlite

import (
	"context"
	"encoding/base64"
	"errors"
	"os"
	"reflect"
	"strings"
	"sync/atomic"
	"testing"

	"dbeer/helper/internal/protocol"
	"dbeer/helper/internal/schemabundle"
	sc "dbeer/helper/internal/schemacompare"
)

func readDependencyCapture(t *testing.T, s *Session) sc.Capture {
	t.Helper()
	ctx := context.Background()
	collector := sc.NewCollector(ctx, sc.DefaultLimits())
	if err := s.ReadSchema(ctx, sc.CaptureSpec{Schemas: []string{"main"}, Limits: sc.DefaultLimits()}, collector); err != nil {
		t.Fatalf("schema capture failed (%T)", err)
	}
	return collector.Capture
}
func buildDependencyBundle(t *testing.T, capture sc.Capture) *schemabundle.Result {
	t.Helper()
	r, err := schemabundle.Build(context.Background(), t.TempDir(), capture, []string{"main"}, RenderSchemaDefinition)
	if err != nil {
		t.Fatalf("bundle failed (%T)", err)
	}
	t.Cleanup(func() { _ = r.Close() })
	return r
}
func dependencyObject(t *testing.T, r *schemabundle.Result, name string) schemabundle.Object {
	t.Helper()
	for _, o := range r.Manifest.Objects {
		if o.Ref.Kind == "table" && o.Ref.Name == name {
			return o
		}
	}
	t.Fatal("table object not reported")
	return schemabundle.Object{}
}
func dependencyFile(t *testing.T, r *schemabundle.Result, f schemabundle.File) string {
	t.Helper()
	chunk, err := r.Chunk(context.Background(), f.ID, 0, 1<<20)
	if err != nil || chunk.HasMore {
		t.Fatal("fixture file unavailable")
	}
	b, err := base64.StdEncoding.DecodeString(chunk.DataBase64)
	if err != nil {
		t.Fatal(err)
	}
	return string(b)
}
func verifyCaptureAuthorizerAndForeignKeys(t *testing.T, s *Session) {
	t.Helper()
	stmt, _, err := s.conn.PrepareTransient(`INSERT INTO t DEFAULT VALUES`)
	if stmt != nil {
		_ = stmt.Finalize()
	}
	if err == nil {
		t.Fatal("readonly authorizer was not restored")
	}
	rows, _, err := s.query(context.Background(), "PRAGMA foreign_keys")
	if err != nil || len(rows) != 1 || cellInt(rows[0][0]) != 1 {
		t.Fatal("connection foreign-key mode was not restored")
	}
}

func TestSchemaDependenciesNameExcludedViewsAndOmitUnprovenFunctions(t *testing.T) {
	for _, fixture := range []struct {
		name, trigger string
		view          bool
	}{
		{"view", `CREATE TRIGGER tr AFTER INSERT ON t BEGIN SELECT count(*) FROM v; END`, true},
		{"view_when_false", `CREATE TRIGGER tr AFTER INSERT ON t WHEN 0 BEGIN SELECT count(*) FROM v; END`, true},
		{"cte_shadow", `CREATE TRIGGER tr AFTER INSERT ON t BEGIN SELECT count(*) FROM (WITH v(id) AS (SELECT 1) SELECT * FROM v); END`, true},
		{"trigger_view_name", `CREATE TRIGGER v AFTER INSERT ON t BEGIN SELECT 1; END`, true},
		{"missing_function", `CREATE TRIGGER tr AFTER INSERT ON t BEGIN SELECT unavailable_function(new.id); END`, false},
		{"unfired_update", `CREATE TRIGGER tr AFTER UPDATE OF absent_column ON t BEGIN SELECT unavailable_function(new.id); END`, false},
	} {
		t.Run(fixture.name, func(t *testing.T) {
			s, path := openCore(t, false)
			runCore(t, s, `CREATE TABLE t(id INTEGER PRIMARY KEY AUTOINCREMENT,note TEXT DEFAULT 'safe')`)
			runCore(t, s, `CREATE TABLE other(id INTEGER)`)
			if fixture.view {
				runCore(t, s, `CREATE VIEW v AS SELECT id FROM other`)
			}
			runCore(t, s, fixture.trigger)
			if err := s.SetReadOnly(context.Background(), true); err != nil {
				t.Fatal(err)
			}
			before, err := os.ReadFile(path)
			if err != nil {
				t.Fatal(err)
			}
			capture := readDependencyCapture(t, s)
			r := buildDependencyBundle(t, capture)
			object := dependencyObject(t, r, "t")
			if object.State == "included" || strings.Contains(dependencyFile(t, r, object.File), "CREATE") {
				t.Fatal("unavailable definition retained executable SQL")
			}
			if fixture.view {
				named := false
				for _, dependency := range object.Dependencies {
					if dependency.Ref == (sc.Ref{Kind: "view", Schema: "main", Name: "v"}) && dependency.State == "external" {
						named = true
					}
				}
				if !named && object.State != "incomplete" {
					t.Fatal("view dependency disappeared")
				}
				if fixture.name == "view" && !named {
					t.Fatal("actual excluded view identity not retained")
				}
				if (fixture.name == "cte_shadow" || fixture.name == "trigger_view_name") && named {
					t.Fatal("CTE alias fabricated a view dependency")
				}
			} else {
				explicit := false
				for _, issue := range r.Manifest.Issues {
					if issue.Code == "sqliteProgramDependenciesUnproven" {
						explicit = true
					}
				}
				if !explicit {
					t.Fatal("unknown function/trigger coverage not reported")
				}
			}
			after, err := os.ReadFile(path)
			if err != nil || !reflect.DeepEqual(before, after) {
				t.Fatal("dependency preparation changed the source file")
			}
			verifyCaptureAuthorizerAndForeignKeys(t, s)
		})
	}
}
func TestSchemaDependenciesKeepSafeProgramsAndIncomingFKParentsIncluded(t *testing.T) {
	s, path := openCore(t, false)
	runCore(t, s, `CREATE TABLE t(id INTEGER PRIMARY KEY AUTOINCREMENT,note TEXT DEFAULT(upper('safe')) CHECK(length(note)>0))`)
	runCore(t, s, `CREATE TABLE child(id INTEGER PRIMARY KEY,parent_id INTEGER REFERENCES t(id) ON DELETE CASCADE)`)
	runCore(t, s, `CREATE INDEX note_index ON t(lower(note)) WHERE note IS NOT NULL`)
	runCore(t, s, `CREATE VIEW v AS SELECT id FROM child`)
	// The CTE shadows an excluded view. Quoted text/comments are not references.
	runCore(t, s, `CREATE TRIGGER tr AFTER INSERT ON t BEGIN UPDATE t SET note=coalesce(new.note,'FROM v unavailable_function()') WHERE id=new.id; SELECT count(*) FROM (WITH local_rows(id) AS (SELECT 1) SELECT * FROM local_rows); /* FROM v */ END`)
	runCore(t, s, `CREATE TRIGGER child_tr AFTER DELETE ON child BEGIN SELECT count(*) FROM v; END`)
	runCore(t, s, `INSERT INTO t(note) VALUES('original')`)
	if err := s.SetReadOnly(context.Background(), true); err != nil {
		t.Fatal(err)
	}
	before, err := os.ReadFile(path)
	if err != nil {
		t.Fatal(err)
	}
	capture := readDependencyCapture(t, s)
	r := buildDependencyBundle(t, capture)
	object := dependencyObject(t, r, "t")
	if object.State != "included" {
		t.Fatalf("provable SQL lost: state=%s codes=%v dependencies=%v issues=%v", object.State, object.ReasonCodes, object.Dependencies, r.Manifest.Issues)
	}
	for _, d := range object.Dependencies {
		if d.Ref.Name == "v" || d.Ref.Name == "child" {
			t.Fatal("CTE/incoming-FK runtime dependency leaked into outgoing definitions")
		}
	}
	ddl := dependencyFile(t, r, object.File)
	if !strings.Contains(ddl, "CREATE TABLE") || !strings.Contains(ddl, "CREATE INDEX") || !strings.Contains(ddl, "CREATE TRIGGER") {
		t.Fatal("supported definition coverage lost")
	}
	after, err := os.ReadFile(path)
	if err != nil || !reflect.DeepEqual(before, after) {
		t.Fatal("dependency compilation changed rows or sequence counters")
	}
	verifyCaptureAuthorizerAndForeignKeys(t, s)
}

type dependencyCancelContext struct {
	context.Context
	cancel context.CancelFunc
	calls  atomic.Int32
	at     int32
}

func (c *dependencyCancelContext) Err() error {
	if c.calls.Add(1) == c.at {
		c.cancel()
	}
	return c.Context.Err()
}
func TestSchemaDependencyProbeCancellationAndLimitsRestoreAuthorization(t *testing.T) {
	s, _ := openCore(t, false)
	runCore(t, s, `CREATE TABLE t(id INTEGER PRIMARY KEY)`)
	if err := s.SetReadOnly(context.Background(), true); err != nil {
		t.Fatal(err)
	}
	ref := sc.Ref{Kind: "table", Schema: "main", Name: "t"}
	catalog := schemaProgramCatalog{objects: map[string]sc.Ref{"T": ref}, triggers: map[string]sc.Ref{}}
	limits := sc.DefaultLimits()
	limits.Members = 1
	if _, err := s.schemaProgramDependencies(context.Background(), ref, []columnInfo{{Name: "id"}}, nil, catalog, limits); !errors.Is(err, sc.ErrLimit) {
		t.Fatal("dependency observation limit ignored")
	}
	verifyCaptureAuthorizerAndForeignKeys(t, s)
	limits = sc.DefaultLimits()
	limits.Bytes = 1
	if _, err := s.schemaProgramDependencies(context.Background(), ref, []columnInfo{{Name: "id"}}, nil, catalog, limits); !errors.Is(err, sc.ErrLimit) {
		t.Fatal("dependency byte limit ignored")
	}
	verifyCaptureAuthorizerAndForeignKeys(t, s)
	limits = sc.DefaultLimits()
	limits.Scalar = 16
	if _, err := s.schemaProgramDependencies(context.Background(), ref, []columnInfo{{Name: "id"}}, nil, catalog, limits); !errors.Is(err, sc.ErrLimit) {
		t.Fatal("generated SQL limit ignored")
	}
	verifyCaptureAuthorizerAndForeignKeys(t, s)
	ctx, cancel := context.WithCancel(context.Background())
	defer cancel()
	canceled := &dependencyCancelContext{Context: ctx, cancel: cancel, at: 6}
	if _, err := s.schemaProgramDependencies(canceled, ref, []columnInfo{{Name: "id"}}, nil, catalog, sc.DefaultLimits()); !errors.Is(err, context.Canceled) {
		t.Fatal("cancellation not retained")
	}
	verifyCaptureAuthorizerAndForeignKeys(t, s)
	// Cancellation of the whole capture must restore the pre-BEGIN mode too.
	ctx, cancel = context.WithCancel(context.Background())
	defer cancel()
	canceled = &dependencyCancelContext{Context: ctx, cancel: cancel, at: 6}
	collector := sc.NewCollector(canceled, sc.DefaultLimits())
	if err := s.ReadSchema(canceled, sc.CaptureSpec{Schemas: []string{"main"}, Limits: sc.DefaultLimits()}, collector); !errors.Is(err, context.Canceled) {
		t.Fatal("capture cancellation not retained")
	}
	verifyCaptureAuthorizerAndForeignKeys(t, s)
}
func TestSchemaDependencyProofWorksOnPhysicalReadonlyFile(t *testing.T) {
	source, path := openCore(t, false)
	runCore(t, source, `CREATE TABLE t(id INTEGER PRIMARY KEY,note TEXT DEFAULT(lower('SAFE')))`)
	runCore(t, source, `CREATE TRIGGER tr AFTER INSERT ON t BEGIN SELECT coalesce(new.note,'safe'); END`)
	source.Close()
	opened, err := Open(context.Background(), protocol.Connection{Engine: "sqlite", SQLite: &protocol.SQLiteSettings{Path: path}, Policy: &protocol.ExecutionPolicy{ReadOnly: true}})
	if err != nil {
		t.Fatal(err)
	}
	s := opened.(*Session)
	defer s.Close()
	capture := readDependencyCapture(t, s)
	r := buildDependencyBundle(t, capture)
	if dependencyObject(t, r, "t").State != "included" {
		t.Fatal("physical readonly capture lost safe definitions")
	}
	verifyCaptureAuthorizerAndForeignKeys(t, s)
}

func TestSchemaDependenciesClassifyGlobalNestedTriggerNamesWithoutInventedViews(t *testing.T) {
	for _, fixture := range []struct {
		name, triggerName, viewName string
		ambiguous, readsView        bool
	}{
		{"nested_collision", "v", "v", true, false},
		{"ascii_case_collision", "MiXeD", "mixed", true, false},
		{"unicode_normalization_is_distinct", "e\u0301", "é", false, false},
		{"unicode_case_is_distinct", "É", "é", false, false},
		{"actual_nested_view", "nested", "Target_é", false, true},
	} {
		t.Run(fixture.name, func(t *testing.T) {
			s, path := openCore(t, false)
			runCore(t, s, `CREATE TABLE t(id INTEGER)`)
			runCore(t, s, `CREATE TABLE b(id INTEGER)`)
			viewSQL := `CREATE VIEW ` + quote(fixture.viewName) + ` AS SELECT 1`
			if fixture.readsView {
				viewSQL = `CREATE VIEW ` + quote(fixture.viewName) + ` AS SELECT id FROM b`
			}
			runCore(t, s, viewSQL)
			runCore(t, s, `CREATE TRIGGER tr AFTER INSERT ON t BEGIN INSERT INTO b(id) VALUES(new.id); END`)
			body := `SELECT 1;`
			if fixture.readsView {
				body = `SELECT count(*) FROM ` + quote(fixture.viewName) + `;`
			}
			runCore(t, s, `CREATE TRIGGER `+quote(fixture.triggerName)+` AFTER INSERT ON b BEGIN `+body+` END`)
			if err := s.SetReadOnly(context.Background(), true); err != nil {
				t.Fatal(err)
			}
			catalog, err := s.schemaDependencyCatalog(context.Background(), sc.DefaultLimits())
			if err != nil {
				t.Fatal(err)
			}
			trigger, ok := catalog.triggers[ddlFold(fixture.triggerName)]
			if !ok || trigger != (sc.Ref{Kind: "trigger", Schema: "main", Name: fixture.triggerName, Table: "b"}) {
				t.Fatal("global trigger identity lost exact bytes or owner")
			}
			view, ok := catalog.objects[ddlFold(fixture.viewName)]
			if !ok || view != (sc.Ref{Kind: "view", Schema: "main", Name: fixture.viewName}) {
				t.Fatal("view identity was replaced by trigger identity")
			}
			before, err := os.ReadFile(path)
			if err != nil {
				t.Fatal(err)
			}
			capture := readDependencyCapture(t, s)
			bundle := buildDependencyBundle(t, capture)
			object := dependencyObject(t, bundle, "t")
			foundView := false
			for _, dependency := range object.Dependencies {
				if dependency.Ref.Kind == "view" {
					if dependency.Ref != view || !fixture.readsView || dependency.State != "external" {
						t.Fatal("nested trigger invented a view dependency")
					}
					foundView = true
				}
			}
			if foundView != fixture.readsView {
				t.Fatal("actual nested view dependency was not retained")
			}
			if fixture.ambiguous {
				if object.State != "incomplete" {
					t.Fatal("ambiguous nested accessor appeared complete")
				}
				explicit := false
				for _, issue := range bundle.Manifest.Issues {
					if issue.Ref != nil && *issue.Ref == (sc.Ref{Kind: "table", Schema: "main", Name: "t"}) && issue.Code == "sqliteProgramDependenciesUnproven" {
						explicit = true
					}
				}
				if !explicit {
					t.Fatal("nested trigger/view ambiguity was not reported")
				}
			} else if !fixture.readsView && object.State != "included" {
				t.Fatal("distinct SQLite trigger/view identities were treated as a collision")
			}
			after, err := os.ReadFile(path)
			if err != nil || !reflect.DeepEqual(before, after) {
				t.Fatal("nested dependency preparation changed source data")
			}
			verifyCaptureAuthorizerAndForeignKeys(t, s)
		})
	}
}
