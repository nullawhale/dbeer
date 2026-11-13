package schemajob

import (
	"context"
	"encoding/base64"
	"errors"
	"os"
	"path/filepath"
	"strings"
	"sync/atomic"
	"testing"
	"time"

	"dbeer/helper/internal/adapter"
	"dbeer/helper/internal/protocol"
	"dbeer/helper/internal/schemabundle"
	sc "dbeer/helper/internal/schemacompare"
	"dbeer/helper/internal/schemaimport"
	sqlitedb "dbeer/helper/internal/sqlite"
	"dbeer/helper/internal/syncplan"
)

func sourceFixture(t *testing.T, ddl string) (schemabundle.Source, sc.Capture) {
	t.Helper()
	ctx := context.Background()
	capture, err := sqlitedb.ImportDefinitions(ctx, []string{ddl}, sc.DefaultLimits())
	if err != nil {
		t.Fatal(err)
	}
	result, err := schemabundle.Build(ctx, t.TempDir(), capture, []string{"main"}, sqlitedb.RenderSchemaDefinition)
	if err != nil {
		t.Fatal(err)
	}
	defer result.Close()
	dir := t.TempDir()
	files := []schemabundle.File{result.Summary.Manifest, result.Manifest.Capture}
	for _, o := range result.Manifest.Objects {
		files = append(files, o.File)
	}
	for _, f := range files {
		var data []byte
		for offset := int64(0); ; {
			chunk, e := result.Chunk(ctx, f.ID, offset, 65536)
			if e != nil {
				t.Fatal(e)
			}
			b, e := base64.StdEncoding.DecodeString(chunk.DataBase64)
			if e != nil {
				t.Fatal(e)
			}
			data = append(data, b...)
			offset = chunk.NextOffset
			if !chunk.HasMore {
				break
			}
		}
		if err = os.WriteFile(filepath.Join(dir, f.Path), data, 0600); err != nil {
			t.Fatal(err)
		}
	}
	imported, err := schemaimport.Read(ctx, schemabundle.Source{Path: dir}, t.TempDir(), sqlitedb.RenderSchemaDefinition)
	if err != nil {
		t.Fatal(err)
	}
	return imported.Summary.Source, capture
}
func waitImport(t *testing.T, m *Manager, id, state string) *protocol.SchemaComparisonResponse {
	t.Helper()
	deadline := time.Now().Add(3 * time.Second)
	for time.Now().Before(deadline) {
		r := m.Handle(protocol.Command{Type: "schema.import.status", SchemaComparison: &protocol.SchemaComparisonRequest{JobID: id}})
		if r.SchemaComparison != nil && r.SchemaComparison.State == state {
			return r.SchemaComparison
		}
		time.Sleep(time.Millisecond)
	}
	t.Fatal("inspection did not reach expected state")
	return nil
}
func TestImportJobIsFilesOnlyAndDoesNotRestoreOrGrantLiveAccess(t *testing.T) {
	source, _ := sourceFixture(t, `CREATE TABLE items(id INTEGER PRIMARY KEY, value TEXT DEFAULT 'NULL');`)
	var opened atomic.Int32
	m, err := New(func(context.Context, protocol.Connection) (adapter.Session, error) {
		opened.Add(1)
		return nil, errors.New("live open forbidden")
	}, Options{Root: t.TempDir(), RenderDefinition: sqlitedb.RenderSchemaDefinition})
	if err != nil {
		t.Fatal(err)
	}
	defer m.Close()
	if opened.Load() != 0 || len(m.jobs) != 0 {
		t.Fatal("manager restore inspected or opened live source")
	}
	inspect := schemabundle.Source{Path: source.Path}
	started := m.Handle(protocol.Command{Type: "schema.import.start", SchemaComparison: &protocol.SchemaComparisonRequest{Bundle: &inspect}})
	if started.SchemaComparison == nil {
		t.Fatal("inspection failed to start")
	}
	id := started.SchemaComparison.JobID
	status := waitImport(t, m, id, "completed")
	if opened.Load() != 0 || status.ImportSummary == nil || status.Summary != nil || status.BundleSummary != nil || status.ImportSummary.Source != source {
		t.Fatal("inspection created a live owner or fabricated a comparison")
	}
	for _, kind := range []string{"schema.status", "schema.bundle.status", "schema.export", "schema.plan", "schema.bundle.export"} {
		if r := m.Handle(protocol.Command{Type: kind, SchemaComparison: &protocol.SchemaComparisonRequest{JobID: id}}); r.Type != "error" {
			t.Fatal("import job crossed capability boundary")
		}
	}
	m.Handle(protocol.Command{Type: "schema.import.close", SchemaComparison: &protocol.SchemaComparisonRequest{JobID: id}})
}
func TestBothOfflineComparisonCarriesHistoricalIdentityAndRevalidates(t *testing.T) {
	source, _ := sourceFixture(t, `CREATE TABLE items(id INTEGER PRIMARY KEY, value TEXT DEFAULT 'NULL');`)
	var opened atomic.Int32
	m, err := New(func(context.Context, protocol.Connection) (adapter.Session, error) {
		opened.Add(1)
		return nil, errors.New("live open forbidden")
	}, Options{Root: t.TempDir(), RenderDefinition: sqlitedb.RenderSchemaDefinition})
	if err != nil {
		t.Fatal(err)
	}
	defer m.Close()
	start := protocol.Command{Type: "schema.start", SchemaComparison: &protocol.SchemaComparisonRequest{Source: &protocol.SchemaSide{Bundle: &source}, Target: &protocol.SchemaSide{Bundle: &source}, Mappings: &sc.Mappings{Schemas: []sc.NamePair{{Source: "main", Target: "main"}}, Tables: []sc.TablePair{}, Types: []sc.ObjectPair{}}}}
	result := m.Handle(start)
	if result.SchemaComparison == nil {
		t.Fatal("offline comparison did not start")
	}
	id := result.SchemaComparison.JobID
	waitState(t, m, id, "completed")
	summary := m.Handle(protocol.Command{Type: "schema.status", SchemaComparison: &protocol.SchemaComparisonRequest{JobID: id}}).SchemaComparison.Summary
	if opened.Load() != 0 || summary == nil || summary.Source.Origin == nil || summary.Target.Origin == nil || summary.Source.StartedAt != "" || summary.Source.Version != "" || summary.Source.Database != "" || summary.Source.Origin.ContentSHA256 != source.ContentSHA256 {
		t.Fatal("portable source became a fictitious live capture")
	}
	m.Handle(protocol.Command{Type: "schema.close", SchemaComparison: &protocol.SchemaComparisonRequest{JobID: id}})
	// Recheck bytes for every explicit comparison; an earlier successful inspect
	// does not make a mutable folder a trusted or immutable snapshot.
	if err = os.WriteFile(filepath.Join(source.Path, "new.sql"), []byte(`CREATE TABLE changed(x);`), 0600); err != nil {
		t.Fatal(err)
	}
	result = m.Handle(start)
	if result.SchemaComparison == nil {
		t.Fatal("comparison owner not created")
	}
	id = result.SchemaComparison.JobID
	waitState(t, m, id, "failed")
	status := m.Handle(protocol.Command{Type: "schema.status", SchemaComparison: &protocol.SchemaComparisonRequest{JobID: id}}).SchemaComparison
	if status.Summary != nil || opened.Load() != 0 {
		t.Fatal("changed source yielded a report or opened live connection")
	}
}
func TestImportCancellationDeadlineAndLateCompletionCannotPublish(t *testing.T) {
	for _, deadline := range []bool{false, true} {
		t.Run(map[bool]string{false: "cancel", true: "deadline"}[deadline], func(t *testing.T) {
			entered := make(chan struct{})
			released := make(chan struct{})
			var opened atomic.Int32
			reader := func(ctx context.Context, _ schemabundle.Source, _ string, _ sc.DefinitionRenderer) (schemaimport.Imported, error) {
				close(entered)
				<-ctx.Done()
				<-released
				return schemaimport.Imported{}, nil
			}
			timeout := time.Second
			if deadline {
				timeout = 15 * time.Millisecond
			}
			m, err := New(func(context.Context, protocol.Connection) (adapter.Session, error) {
				opened.Add(1)
				return nil, errors.New("live open forbidden")
			}, Options{Root: t.TempDir(), Deadline: timeout, ReadSource: reader})
			if err != nil {
				t.Fatal(err)
			}
			defer m.Close()
			source := schemabundle.Source{Path: t.TempDir()}
			id := m.Handle(protocol.Command{Type: "schema.import.start", SchemaComparison: &protocol.SchemaComparisonRequest{Bundle: &source}}).SchemaComparison.JobID
			<-entered
			if !deadline {
				r := m.Handle(protocol.Command{Type: "schema.import.cancel", SchemaComparison: &protocol.SchemaComparisonRequest{JobID: id}})
				if r.SchemaComparison.State != "cancelled" {
					t.Fatal("cancel not acknowledged")
				}
			}
			close(released)
			expected := "cancelled"
			if deadline {
				expected = "failed"
			}
			status := waitImport(t, m, id, expected)
			if status.ImportSummary != nil || opened.Load() != 0 || deadline && !strings.Contains(status.Code, "deadline") {
				t.Fatal("late completion published or timeout lost")
			}
			m.Close()
			if _, err = os.Stat(m.root); !os.IsNotExist(err) {
				t.Fatal("import scratch survived shutdown")
			}
		})
	}
}

func TestMixedHistoricalAndRealSQLiteSourcesGenerateOnlyReviewedPlans(t *testing.T) {
	ctx := context.Background()
	source, _ := sourceFixture(t, `CREATE TABLE items(id INTEGER PRIMARY KEY); CREATE TABLE offline_only(id INTEGER PRIMARY KEY);`)
	path := filepath.Join(t.TempDir(), "live.sqlite")
	if err := sqlitedb.Create(ctx, path); err != nil {
		t.Fatal(err)
	}
	connection := protocol.Connection{Engine: "sqlite", SQLite: &protocol.SQLiteSettings{Path: path}, SSLMode: "disable"}
	owner, err := sqlitedb.Open(ctx, connection)
	if err != nil {
		t.Fatal(err)
	}
	defer owner.Close()
	if response := owner.Execute(ctx, protocol.Command{Type: "execute", RequestID: "fixture", SessionID: "fixture", QueryID: "fixture", SQL: `CREATE TABLE items(id INTEGER PRIMARY KEY);`}); response.Type != "query.result" {
		t.Fatal("fixture creation failed")
	}
	for _, offlineTarget := range []bool{false, true} {
		t.Run(map[bool]string{false: "offline-source", true: "offline-target"}[offlineTarget], func(t *testing.T) {
			var opens atomic.Int32
			m, err := New(func(ctx context.Context, settings protocol.Connection) (adapter.Session, error) {
				opens.Add(1)
				if settings.SQLite == nil || settings.SQLite.Path != path {
					return nil, errors.New("unexpected live owner")
				}
				return sqlitedb.Open(ctx, settings)
			}, Options{Root: t.TempDir(), RenderDefinition: sqlitedb.RenderSchemaDefinition, RenderPlan: func(ctx context.Context, report sc.Report) (syncplan.Plan, error) {
				return syncplan.Schema(ctx, report, sqlitedb.RenderSynchronizationSchema)
			}})
			if err != nil {
				t.Fatal(err)
			}
			defer m.Close()
			a, b := protocol.SchemaSide{Bundle: &source}, protocol.SchemaSide{Connection: connection}
			if offlineTarget {
				a, b = b, a
			}
			started := m.Handle(protocol.Command{Type: "schema.start", SchemaComparison: &protocol.SchemaComparisonRequest{Source: &a, Target: &b, Mappings: &sc.Mappings{Schemas: []sc.NamePair{{Source: "main", Target: "main"}}, Tables: []sc.TablePair{}, Types: []sc.ObjectPair{}}}})
			if started.SchemaComparison == nil {
				t.Fatal("mixed comparison did not start")
			}
			id := started.SchemaComparison.JobID
			waitState(t, m, id, "completed")
			summary := m.Handle(protocol.Command{Type: "schema.status", SchemaComparison: &protocol.SchemaComparisonRequest{JobID: id}}).SchemaComparison.Summary
			if summary == nil || opens.Load() != 1 || (summary.Target.Origin != nil) != offlineTarget || (summary.Source.Origin != nil) == offlineTarget {
				t.Fatal("historical side acquired a live owner or context")
			}
			plan := m.Handle(protocol.Command{Type: "schema.plan", SchemaComparison: &protocol.SchemaComparisonRequest{JobID: id, ModelDigest: summary.ModelDigest}})
			if plan.SchemaComparison == nil || plan.SchemaComparison.Plan == nil || len(plan.SchemaComparison.Plan.Steps) == 0 || opens.Load() != 1 {
				t.Fatal("mixed plan missing or reopened a live source")
			}
			collector := sc.NewCollector(ctx, sc.DefaultLimits())
			if err := owner.(adapter.SchemaReader).ReadSchema(ctx, sc.CaptureSpec{Schemas: []string{"main"}, Limits: sc.DefaultLimits()}, collector); err != nil || len(collector.Capture.Tables) != 1 {
				t.Fatal("plan generation applied imported SQL to live database")
			}
		})
	}
}
