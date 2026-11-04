package sqlite

import (
	"context"
	"encoding/base64"
	"encoding/json"
	"path/filepath"
	"strings"
	"testing"

	"dbeer/helper/internal/protocol"
	sc "dbeer/helper/internal/schemacompare"
	"dbeer/helper/internal/syncplan"
	tc "dbeer/helper/internal/tablecapture"
	"dbeer/helper/internal/tableedit"
)

func toolSession(t *testing.T) *Session {
	t.Helper()
	path := filepath.Join(t.TempDir(), "tools.sqlite")
	if err := Create(context.Background(), path); err != nil {
		t.Fatal(err)
	}
	a, err := Open(context.Background(), protocol.Connection{Engine: "sqlite", SQLite: &protocol.SQLiteSettings{Path: path}})
	if err != nil {
		t.Fatal(err)
	}
	s := a.(*Session)
	t.Cleanup(s.Close)
	return s
}
func toolExec(t *testing.T, s *Session, sql string, args ...any) {
	t.Helper()
	if err := s.exec(context.Background(), sql, args...); err != nil {
		t.Fatal(err)
	}
}
func TestSQLiteStructureRebuildAtomic(t *testing.T) {
	s := toolSession(t)
	ctx := context.Background()
	toolExec(t, s, "CREATE TABLE records(id INTEGER PRIMARY KEY,value TEXT)")
	toolExec(t, s, "INSERT INTO records VALUES(7,'7')")
	target := tableedit.Target{Schema: "main", Table: "records"}
	b, err := s.StructureLoad(ctx, target)
	if err != nil {
		t.Fatal(err)
	}
	real := tableedit.DataType{Kind: "integer"}
	p, err := s.StructurePrepare(ctx, b, tableedit.Draft{Changes: []tableedit.ColumnChange{{Name: "value", Type: &real}}})
	if err != nil {
		t.Fatal(err)
	}
	outcomes := s.StructureApplySteps(ctx, b, tableedit.Plan{SQL: p.SQL})
	for _, o := range outcomes {
		if o.State != "rolledBack" {
			t.Fatalf("lossy affinity change accepted: %#v", outcomes)
		}
	}
	rows, _, err := s.query(ctx, "SELECT typeof(value),value FROM records")
	if err != nil || cellText(rows[0][0]) != "text" {
		t.Fatalf("rollback failed: %v %v", rows, err)
	}
	def := tableedit.Default{Kind: "text", Value: stringPtr("new")}
	b, err = s.StructureLoad(ctx, target)
	if err != nil {
		t.Fatal(err)
	}
	p, err = s.StructurePrepare(ctx, b, tableedit.Draft{Changes: []tableedit.ColumnChange{{Name: "value", Default: &def}}})
	if err != nil {
		t.Fatal(err)
	}
	outcomes = s.StructureApplySteps(ctx, b, tableedit.Plan{SQL: p.SQL})
	for _, o := range outcomes {
		if o.State != "applied" {
			t.Fatalf("safe rebuild failed: %#v", outcomes)
		}
	}
	toolExec(t, s, "INSERT INTO records(id) VALUES(8)")
	rows, _, err = s.query(ctx, "SELECT value FROM records WHERE id=8")
	if err != nil || cellText(rows[0][0]) != "new" {
		t.Fatalf("default absent: %v %v", rows, err)
	}
}
func TestSQLiteStructureStaleAndUnsupported(t *testing.T) {
	s := toolSession(t)
	ctx := context.Background()
	toolExec(t, s, "CREATE TABLE records(id INTEGER PRIMARY KEY,value TEXT CHECK(length(value)<10))")
	b, err := s.StructureLoad(ctx, tableedit.Target{Schema: "main", Table: "records"})
	if err != nil {
		t.Fatal(err)
	}
	nullable := false
	if _, err = s.StructurePrepare(ctx, b, tableedit.Draft{Changes: []tableedit.ColumnChange{{Name: "value", Nullable: &nullable}}}); err != nil {
		t.Fatal("CHECK-preserving reconstruction failed", err)
	}
	p, err := s.StructurePrepare(ctx, b, tableedit.Draft{Columns: []tableedit.Column{{Name: "extra", Type: tableedit.DataType{Kind: "text"}, Nullable: true, Default: tableedit.Default{Kind: "none"}}}})
	if err != nil {
		t.Fatal(err)
	}
	toolExec(t, s, "CREATE INDEX extra_index ON records(value)")
	out := s.StructureApplySteps(ctx, b, tableedit.Plan{SQL: p.SQL})
	if out[0].State != "notStarted" {
		t.Fatalf("stale plan executed: %v", out)
	}
}
func TestSQLiteImportPreviewAndAtomicity(t *testing.T) {
	s := toolSession(t)
	ctx := context.Background()
	toolExec(t, s, "CREATE TABLE records(id INTEGER PRIMARY KEY,value TEXT NOT NULL)")
	request := &protocol.TableImportRequest{Schema: "main", Table: "records"}
	r := s.tableImport(ctx, protocol.Command{Type: "import.describe", TableImport: request})
	if r.Type != "import.describe.result" {
		t.Fatalf("describe: %#v", r)
	}
	request.Fingerprint = r.TableImport.Fingerprint
	request.Columns = []string{"id", "value"}
	request.Rows = [][]protocol.CellValue{{{Kind: "text", Value: stringPtr("1")}, {Kind: "text", Value: stringPtr("kept")}}, {{Kind: "text", Value: stringPtr("1")}, {Kind: "text", Value: stringPtr("duplicate")}}}
	r = s.tableImport(ctx, protocol.Command{Type: "import.preview", TableImport: request})
	if r.Type != "import.preview.result" {
		t.Fatalf("preview: %#v", r)
	}
	rows, _, _ := s.query(ctx, "SELECT count(*) FROM records")
	if cellInt(rows[0][0]) != 0 {
		t.Fatal("preview wrote data")
	}
	r = s.tableImport(ctx, protocol.Command{Type: "import.apply", TableImport: request})
	if r.Type != "error" {
		t.Fatalf("duplicate import succeeded: %#v", r)
	}
	rows, _, _ = s.query(ctx, "SELECT count(*) FROM records")
	if cellInt(rows[0][0]) != 0 {
		t.Fatal("partial import committed")
	}
	request.Rows = request.Rows[:1]
	r = s.tableImport(ctx, protocol.Command{Type: "import.apply", TableImport: request})
	if r.Type != "import.apply.result" {
		t.Fatalf("import: %#v", r)
	}
}

type toolRows struct{ rows [][]*string }

func (s *toolRows) Row(row []*string) error { s.rows = append(s.rows, row); return nil }
func TestSQLiteTypedCaptureAndSchema(t *testing.T) {
	s := toolSession(t)
	ctx := context.Background()
	toolExec(t, s, "CREATE TABLE records(id INTEGER PRIMARY KEY,value)")
	toolExec(t, s, "INSERT INTO records VALUES(1,42)")
	toolExec(t, s, "INSERT INTO records VALUES(2,'42')")
	toolExec(t, s, "INSERT INTO records VALUES(3,X'3432')")
	d, err := s.DescribeTable(ctx, tc.Table{Schema: "main", Name: "records"})
	if err != nil {
		t.Fatal(err)
	}
	sink := &toolRows{}
	_, out, err := s.CaptureTable(ctx, tc.Spec{Table: d.Table, DescriptorDigest: d.Digest, Columns: []string{"id", "value"}, Keys: []string{"id"}, ReadLimit: 2}, sink)
	if err != nil {
		t.Fatal(err)
	}
	if out.StoredRows != 2 || len(out.PartialReasons) != 1 {
		t.Fatalf("limit not disclosed: %#v", out)
	}
	if *sink.rows[0][1] == *sink.rows[1][1] {
		t.Fatal("integer and text merged")
	}
	collector := sc.NewCollector(ctx, sc.DefaultLimits())
	if err = s.ReadSchema(ctx, sc.CaptureSpec{Schemas: []string{"main"}, Limits: sc.DefaultLimits()}, collector); err != nil {
		t.Fatal(err)
	}
	if len(collector.Capture.Tables) != 1 {
		t.Fatal("table not captured")
	}
	def, err := RenderSchemaDefinition(ctx, collector.Capture, sc.Ref{Schema: "main", Name: "records"})
	if err != nil || !strings.Contains(def.SQL, "CREATE TABLE") {
		t.Fatalf("definition: %v %v", def, err)
	}
}
func TestSQLiteExplainAndSynchronization(t *testing.T) {
	s := toolSession(t)
	ctx := context.Background()
	toolExec(t, s, "CREATE TABLE records(id INTEGER PRIMARY KEY,value TEXT)")
	q := protocol.ExplainRequest{Mode: "plan", SQL: "SELECT * FROM records WHERE id=1"}
	p, err := s.PrepareExplain(q)
	if err != nil {
		t.Fatal(err)
	}
	r := s.ExecuteExplain(ctx, protocol.Command{Explain: &q, PreparedExplainSQL: p.Preview.SQL})
	if r.Type != "explain.result" || !r.Explain.Valid() {
		t.Fatalf("explain: %#v", r)
	}
	q.Mode = "analyze"
	if _, err = s.PrepareExplain(q); err == nil {
		t.Fatal("Analyze accepted")
	}
	value, _ := json.Marshal(protocol.SQLiteValue{Type: "text", Value: base64.StdEncoding.EncodeToString([]byte("O'Reilly"))})
	raw := string(value)
	literal, kind, err := sqliteSyncLiteral(&raw)
	if err != nil || kind != "text" || !strings.HasPrefix(literal, "CAST(X'") {
		t.Fatalf("unsafe literal: %s %s %v", literal, kind, err)
	}
	real, _ := json.Marshal(protocol.SQLiteValue{Type: "real", Value: "0000000000000000"})
	raw = string(real)
	if _, _, err = sqliteSyncLiteral(&raw); err == nil {
		t.Fatal("zero REAL guards must remain manual")
	}
	_, err = RenderDataSynchronization(syncplan.DataOperation{Kind: "delete", Descriptor: tc.Descriptor{Engine: "sqlite", Table: tc.Table{Schema: "main", Name: "records"}, Columns: []tc.Column{{Name: "id"}}}})
	if err == nil {
		t.Fatal("missing originals accepted")
	}
}
func stringPtr(s string) *string { return &s }

func TestSQLiteAutoincrementRebuildRetainsSequence(t *testing.T) {
	s := toolSession(t)
	ctx := context.Background()
	toolExec(t, s, "CREATE TABLE records(id INTEGER PRIMARY KEY AUTOINCREMENT,value TEXT)")
	toolExec(t, s, "INSERT INTO records(id,value) VALUES(100,'deleted')")
	toolExec(t, s, "DELETE FROM records")
	b, err := s.StructureLoad(ctx, tableedit.Target{Schema: "main", Table: "records"})
	if err != nil {
		t.Fatal(err)
	}
	def := tableedit.Default{Kind: "text", Value: stringPtr("new")}
	p, err := s.StructurePrepare(ctx, b, tableedit.Draft{Changes: []tableedit.ColumnChange{{Name: "value", Default: &def}}})
	if err != nil {
		t.Fatal(err)
	}
	outcomes := s.StructureApplySteps(ctx, b, tableedit.Plan{SQL: p.SQL})
	for _, o := range outcomes {
		if o.State != "applied" {
			t.Fatalf("rebuild failed: %#v", outcomes)
		}
	}
	toolExec(t, s, "INSERT INTO records DEFAULT VALUES")
	rows, _, err := s.query(ctx, "SELECT id FROM records")
	if err != nil || cellInt(rows[0][0]) != 101 {
		t.Fatalf("sequence lost: %v %v", rows, err)
	}
}

func TestSQLiteStructureStoreAndForeignKeyRollback(t *testing.T) {
	s := toolSession(t)
	ctx := context.Background()
	toolExec(t, s, "CREATE TABLE parent(id INTEGER PRIMARY KEY)")
	toolExec(t, s, "CREATE TABLE child(id INTEGER PRIMARY KEY,parent_id INTEGER)")
	toolExec(t, s, "INSERT INTO child VALUES(1,999)")
	store := &tableedit.Store{}
	loaded, err := store.Load(ctx, s, tableedit.Target{Schema: "main", Table: "child"})
	if err != nil {
		t.Fatal(err)
	}
	draft := tableedit.Draft{Keys: []tableedit.KeyEdit{{Action: "add", Name: "parent_fk", Kind: "foreign", Columns: []string{"parent_id"}, Reference: &tableedit.Target{Schema: "main", Table: "parent"}, ReferenceColumns: []string{"id"}, OnUpdate: "NO ACTION", OnDelete: "NO ACTION"}}}
	preview, err := store.Preview(s, loaded.Baseline.ID, draft)
	if err != nil {
		t.Fatal(err)
	}
	result, err := store.Apply(ctx, s, tableedit.Apply{PlanID: preview.Plan.ID, Digest: preview.Plan.Digest, ExecutionID: "test-execution"})
	if err != nil {
		t.Fatal(err)
	}
	if result.Outcome.State != "failed" {
		t.Fatalf("invalid FK committed: %#v", result.Outcome)
	}
	rows, _, err := s.query(ctx, "PRAGMA main.foreign_key_list(child)")
	if err != nil || len(rows) != 0 {
		t.Fatalf("FK rollback failed: %v %v", rows, err)
	}
	toolExec(t, s, "INSERT INTO parent VALUES(999)")
	loaded, err = store.Load(ctx, s, tableedit.Target{Schema: "main", Table: "child"})
	if err != nil {
		t.Fatal(err)
	}
	preview, err = store.Preview(s, loaded.Baseline.ID, draft)
	if err != nil {
		t.Fatal(err)
	}
	result, err = store.Apply(ctx, s, tableedit.Apply{PlanID: preview.Plan.ID, Digest: preview.Plan.Digest, ExecutionID: "test-execution-2"})
	if err != nil || result.Outcome.State != "applied" {
		t.Fatalf("valid FK failed: %v %#v", err, result.Outcome)
	}
}

func TestSQLiteNamedParameterStorage(t *testing.T) {
	s := toolSession(t)
	ctx := context.Background()
	amount, day, at := "-1234567890.123456789", "2024-02-29", "2026-11-01 12:30:59.123456"
	parameters := []protocol.QueryParameter{{Name: "amount", Type: "decimal", Value: &amount}, {Name: "day", Type: "date", Value: &day}, {Name: "at", Type: "timestamp", Value: &at}}
	r := s.Execute(ctx, protocol.Command{Type: "execute", SQL: "SELECT :amount, :day, :at, :amount", Parameters: parameters})
	if r.Type != "query.result" || len(r.SQLiteValues) != 1 || len(r.SQLiteValues[0]) != 4 {
		t.Fatalf("SQLite parameter execution failed: %#v", r)
	}
	for i, want := range []string{amount, day, at, amount} {
		if r.SQLiteValues[0][i].Type != "text" || cellText(r.SQLiteValues[0][i]) != want {
			t.Fatalf("SQLite cast or changed parameter %d: %#v", i, r.SQLiteValues[0][i])
		}
	}
}

func TestSQLiteRebuildPreservesInlineDefinitions(t *testing.T) {
	for _, definition := range []string{
		"CREATE TABLE records(id INTEGER PRIMARY KEY,parent_id INTEGER REFERENCES parent(id),value TEXT)",
		"CREATE TABLE records(id INTEGER PRIMARY KEY,value TEXT,derived TEXT AS (value || '!'))",
		"CREATE TABLE records(id INTEGER PRIMARY KEY\nDESC,value TEXT)",
		"CREATE TABLE records(id INTEGER PRIMARY KEY ON\nCONFLICT REPLACE,value TEXT)",
	} {
		t.Run(definition, func(t *testing.T) {
			s := toolSession(t)
			ctx := context.Background()
			toolExec(t, s, "CREATE TABLE parent(id INTEGER PRIMARY KEY)")
			toolExec(t, s, definition)
			b, err := s.StructureLoad(ctx, tableedit.Target{Schema: "main", Table: "records"})
			if err != nil {
				t.Fatal(err)
			}
			def := tableedit.Default{Kind: "text", Value: stringPtr("new")}
			p, err := s.StructurePrepare(ctx, b, tableedit.Draft{Changes: []tableedit.ColumnChange{{Name: "value", Default: &def}}})
			if err != nil {
				t.Fatal("source-preserving reconstruction failed", err)
			}
			outcomes := s.StructureApplySteps(ctx, b, tableedit.Plan{SQL: p.SQL})
			if outcomes[0].State != "applied" {
				t.Fatal("preserving inline definition failed", outcomes[0].State)
			}
			toolExec(t, s, "INSERT INTO records(id) VALUES(1)")
			if strings.Contains(definition, "REFERENCES") {
				if err := s.exec(ctx, "INSERT INTO records(id,parent_id) VALUES(2,99)"); err == nil {
					t.Fatal("foreign key lost")
				}
			}
			if strings.Contains(definition, "derived") {
				values, _, err := s.query(ctx, "SELECT derived FROM records WHERE id=1")
				if err != nil || cellText(values[0][0]) != "new!" {
					t.Fatal("generated expression lost")
				}
			}
		})
	}
}

func TestSQLiteRebuildNewRowidColumnDoesNotStealHiddenIdentity(t *testing.T) {
	s := toolSession(t)
	ctx := context.Background()
	toolExec(t, s, "CREATE TABLE records(code TEXT PRIMARY KEY NOT NULL,value TEXT)")
	toolExec(t, s, "INSERT INTO records(rowid,code,value) VALUES(42,'key','old')")
	b, err := s.StructureLoad(ctx, tableedit.Target{Schema: "main", Table: "records"})
	if err != nil {
		t.Fatal(err)
	}
	def := tableedit.Default{Kind: "text", Value: stringPtr("new")}
	p, err := s.StructurePrepare(ctx, b, tableedit.Draft{Columns: []tableedit.Column{{Name: "rowid", Type: tableedit.DataType{Kind: "integer"}, Nullable: true, Default: tableedit.Default{Kind: "none"}}}, Changes: []tableedit.ColumnChange{{Name: "value", Default: &def}}})
	if err != nil {
		t.Fatal(err)
	}
	outcomes := s.StructureApplySteps(ctx, b, tableedit.Plan{SQL: p.SQL})
	if outcomes[0].State != "applied" {
		t.Fatalf("safe rebuild failed: %#v", outcomes)
	}
	rows, _, err := s.query(ctx, "SELECT _rowid_,rowid FROM records")
	if err != nil || cellInt(rows[0][0]) != 42 || rows[0][1].Type != "null" {
		t.Fatalf("new user column stole row identity: %v %v", rows, err)
	}
}

func TestSQLiteSchemaImplicitForeignKeysAndDeferrability(t *testing.T) {
	s := toolSession(t)
	ctx := context.Background()
	toolExec(t, s, "CREATE TABLE parent(z TEXT,a INTEGER,PRIMARY KEY(a,z)) WITHOUT ROWID")
	toolExec(t, s, "CREATE TABLE child(x INTEGER,y TEXT,FOREIGN KEY(x,y) REFERENCES parent DEFERRABLE INITIALLY DEFERRED)")
	toolExec(t, s, "CREATE TABLE plain(x INTEGER,y TEXT,FOREIGN KEY(x,y) REFERENCES parent)")
	toolExec(t, s, "CREATE TABLE orphan(x INTEGER REFERENCES missing)")
	collector := sc.NewCollector(ctx, sc.DefaultLimits())
	if err := s.ReadSchema(ctx, sc.CaptureSpec{Schemas: []string{"main"}, Limits: sc.DefaultLimits()}, collector); err != nil {
		t.Fatal(err)
	}
	seen := map[string]bool{}
	for _, table := range collector.Capture.Tables {
		for _, fk := range table.Constraints.Items {
			if fk.Kind.Value == nil || *fk.Kind.Value != "f" {
				continue
			}
			seen[table.Ref.Name] = true
			if table.Ref.Name == "orphan" {
				if fk.ForeignKeys.Complete || fk.ForeignKeys.State != "unsupported" || len(fk.ForeignKeys.Items) != 0 {
					t.Fatalf("missing parent reported complete: %#v", fk)
				}
				continue
			}
			if !fk.ForeignKeys.Complete || len(fk.ForeignKeys.Items) != 2 || fk.ForeignKeys.Items[0].Source.Name != "x" || fk.ForeignKeys.Items[0].Target.Name != "a" || fk.ForeignKeys.Items[1].Source.Name != "y" || fk.ForeignKeys.Items[1].Target.Name != "z" {
				t.Fatalf("implicit composite PK order lost: %#v", fk)
			}
			if table.Ref.Name == "child" {
				if fk.Deferrable.State != "unsupported" || fk.Deferrable.Value != nil || fk.InitiallyDeferred.State != "unsupported" || fk.InitiallyDeferred.Value != nil {
					t.Fatalf("deferrability invented: %#v", fk)
				}
			} else {
				if fk.Deferrable.Value == nil || *fk.Deferrable.Value || fk.InitiallyDeferred.Value == nil || *fk.InitiallyDeferred.Value {
					t.Fatalf("default deferrability not known: %#v", fk)
				}
			}
		}
	}
	if !seen["child"] || !seen["plain"] || !seen["orphan"] {
		t.Fatalf("missing captured FK: %v", seen)
	}
}
