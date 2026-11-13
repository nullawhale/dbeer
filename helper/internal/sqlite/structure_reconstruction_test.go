package sqlite

import (
	"context"
	"dbeer/helper/internal/tableedit"
	"errors"
	"reflect"
	"strings"
	"testing"
)

func e4Prepare(t *testing.T, s *Session, table string, d tableedit.Draft) (tableedit.Baseline, tableedit.Plan) {
	t.Helper()
	b, e := s.StructureLoad(context.Background(), tableedit.Target{Schema: "main", Table: table})
	if e != nil {
		t.Fatal(e)
	}
	p, e := s.StructurePrepare(context.Background(), b, d)
	if e != nil {
		t.Fatal(e)
	}
	return b, tableedit.Plan{SQL: p.SQL, Reconstruction: p.Reconstruction}
}
func e4Draft(order ...string) tableedit.Draft {
	return tableedit.Draft{AuthoringVersion: 5, AllowDestructive: true, Columns: []tableedit.Column{}, ColumnOrder: order, Reconstruct: true}
}
func e4Apply(t *testing.T, s *Session, b tableedit.Baseline, p tableedit.Plan) {
	t.Helper()
	out := s.StructureApplySteps(context.Background(), b, p)
	for i, x := range out {
		if x.State != "applied" {
			t.Fatalf("step %d: %s %s", i, x.State, x.Message)
		}
	}
}
func TestSQLiteReconstructionPreservesValuesConstraintsIndexesDependencies(t *testing.T) {
	s := toolSession(t)
	ctx := context.Background()
	for _, sql := range []string{`CREATE TABLE parent(k INTEGER PRIMARY KEY)`, `INSERT INTO parent VALUES(7)`, `CREATE TABLE records(id INTEGER PRIMARY KEY AUTOINCREMENT, p INTEGER REFERENCES parent(k) ON DELETE CASCADE DEFERRABLE INITIALLY DEFERRED, label VARCHAR(40) COLLATE NOCASE CONSTRAINT label_unique UNIQUE CHECK(length(label)<30), value, derived TEXT AS (label||':kept') STORED)`, `INSERT INTO records(p,label,value) VALUES(7,'empty',''),(7,'null',NULL),(7,'text-null','NULL'),(7,'numeric',9223372036854775807),(7,'binary',X'00FF31')`, `UPDATE sqlite_sequence SET seq=900 WHERE name='records'`, `CREATE INDEX records_expression ON records(lower(label)) WHERE p IS NOT NULL`, `CREATE TABLE child(k INTEGER REFERENCES records(id) ON DELETE CASCADE)`, `INSERT INTO child VALUES(1)`, `CREATE TABLE audit(v TEXT)`, `CREATE TRIGGER records_audit AFTER INSERT ON records BEGIN INSERT INTO audit VALUES(NEW.label); END`} {
		toolExec(t, s, sql)
	}
	before, count, e := s.structureValueDigest(ctx, "records", digestColumns("rowid", "id", "p", "label", "value", "derived"))
	if e != nil {
		t.Fatal(e)
	}
	d := e4Draft("required", "value", "label", "p", "id", "derived")
	d.Columns = []tableedit.Column{{Name: "required", Type: tableedit.DataType{Kind: "text"}, Default: tableedit.Default{Kind: "none"}}}
	d.Backfills = []tableedit.Backfill{{Column: "required", Expression: "label||':backfilled'"}}
	b, p := e4Prepare(t, s, "records", d)
	if !strings.Contains(p.SQL[1], "(label||':backfilled')") {
		t.Fatal("backfill omitted from review")
	}
	e4Apply(t, s, b, p)
	after, n, e := s.structureValueDigest(ctx, "records", digestColumns("rowid", "id", "p", "label", "value", "derived"))
	if e != nil || before != after || count != n {
		t.Fatal("retained native values changed", e)
	}
	rows, _, e := s.query(ctx, `SELECT required FROM records WHERE id=1`)
	if e != nil || cellText(rows[0][0]) != "empty:backfilled" {
		t.Fatal("backfill wrong")
	}
	rows, _, e = s.query(ctx, `SELECT count(*) FROM child`)
	if e != nil || cellInt(rows[0][0]) != 1 {
		t.Fatal("DROP fired incoming CASCADE")
	}
	for _, sql := range []string{`INSERT INTO records(p,label,required) VALUES(7,'EMPTY','ok')`, `INSERT INTO records(p,label,required) VALUES(7,'longer than the allowed thirty characters','ok')`, `INSERT INTO records(p,label,required) VALUES(99,'missing-parent','ok')`, `INSERT INTO records(label) VALUES('missing-required')`} {
		if s.exec(ctx, sql) == nil {
			t.Fatal("constraint disappeared")
		}
	}
	toolExec(t, s, `INSERT INTO records(label,required) VALUES('next','ok')`)
	rows, _, e = s.query(ctx, `SELECT id FROM records WHERE label='next'`)
	if e != nil || cellInt(rows[0][0]) != 901 {
		t.Fatal("counter changed")
	}
	rows, _, e = s.query(ctx, `SELECT count(*) FROM audit`)
	if e != nil || cellInt(rows[0][0]) != 1 {
		t.Fatal("copy fired or lost trigger")
	}
	rows, _, e = s.query(ctx, `PRAGMA foreign_keys`)
	if e != nil || cellInt(rows[0][0]) != 1 {
		t.Fatal("foreign_keys not restored")
	}
}
func TestSQLiteReconstructionHiddenRowIDAndWithoutRowID(t *testing.T) {
	for _, ddl := range []string{`CREATE TABLE records(id INTEGER PRIMARY KEY DESC,v ANY) STRICT`, `CREATE TABLE records(id TEXT PRIMARY KEY,v ANY) STRICT, WITHOUT ROWID`} {
		t.Run(ddl, func(t *testing.T) {
			s := toolSession(t)
			toolExec(t, s, ddl)
			without := strings.Contains(ddl, "WITHOUT")
			if without {
				toolExec(t, s, `INSERT INTO records VALUES('key',X'00FF')`)
			} else {
				toolExec(t, s, `INSERT INTO records(rowid,id,v) VALUES(42,7,X'00FF')`)
			}
			b, p := e4Prepare(t, s, "records", e4Draft("v", "id"))
			e4Apply(t, s, b, p)
			if !without {
				rows, _, e := s.query(context.Background(), `SELECT rowid,id FROM records`)
				if e != nil || cellInt(rows[0][0]) != 42 || cellInt(rows[0][1]) != 7 {
					t.Fatal("hidden rowid changed")
				}
			}
		})
	}
}
func TestSQLiteReconstructionPreviewDoesNotEvaluateAndFailureIsAtomic(t *testing.T) {
	s := toolSession(t)
	toolExec(t, s, `CREATE TABLE records(v TEXT)`)
	toolExec(t, s, `INSERT INTO records VALUES('kept')`)
	d := e4Draft()
	d.Columns = []tableedit.Column{{Name: "required", Type: tableedit.DataType{Kind: "text"}, Default: tableedit.Default{Kind: "none"}}}
	d.Backfills = []tableedit.Backfill{{Column: "required", Expression: "missing_function(v)"}}
	b, p := e4Prepare(t, s, "records", d)
	out := s.StructureApplySteps(context.Background(), b, p)
	if len(out) < 4 || out[0].State != "rolledBack" || out[1].State != "rolledBack" || out[2].State != "notStarted" {
		t.Fatal(out)
	}
	fresh, e := s.StructureLoad(context.Background(), b.Target)
	if e != nil || fresh.Fingerprint != b.Fingerprint {
		t.Fatal("failed copy changed schema")
	}
}
func TestSQLiteReconstructionConcurrentSchemaChangeCancellationAndNoReplay(t *testing.T) {
	t.Run("stale", func(t *testing.T) {
		s := toolSession(t)
		toolExec(t, s, `CREATE TABLE records(v TEXT)`)
		b, p := e4Prepare(t, s, "records", e4Draft())
		toolExec(t, s, `CREATE INDEX later ON records(v)`)
		for _, x := range s.StructureApplySteps(context.Background(), b, p) {
			if x.State != "notStarted" {
				t.Fatal("stale dispatched")
			}
		}
	})
	t.Run("cancel", func(t *testing.T) {
		s := toolSession(t)
		toolExec(t, s, `CREATE TABLE records(v TEXT)`)
		b, p := e4Prepare(t, s, "records", e4Draft())
		ctx, cancel := context.WithCancel(context.Background())
		s.structureAfterStep = func(i int) {
			if i == 0 {
				cancel()
			}
		}
		out := s.StructureApplySteps(ctx, b, p)
		if out[0].State != "rolledBack" || out[1].State != "notStarted" {
			t.Fatal(out)
		}
		fresh, e := s.StructureLoad(context.Background(), b.Target)
		if e != nil || fresh.Fingerprint != b.Fingerprint {
			t.Fatal("cancel persisted")
		}
	})
	t.Run("unknown", func(t *testing.T) {
		s := toolSession(t)
		toolExec(t, s, `CREATE TABLE records(v TEXT)`)
		store := tableedit.Store{}
		loaded, e := store.Load(context.Background(), s, tableedit.Target{Schema: "main", Table: "records"})
		if e != nil {
			t.Fatal(e)
		}
		preview, e := store.Preview(s, loaded.Baseline.ID, e4Draft())
		if e != nil {
			t.Fatal(e)
		}
		s.structureCommitOverride = func(commit func() error) error {
			if e := commit(); e != nil {
				return e
			}
			return errors.New("lost ack")
		}
		apply := tableedit.Apply{PlanID: preview.Plan.ID, Digest: preview.Plan.Digest, ExecutionID: "unknown"}
		reply, e := store.Apply(context.Background(), s, apply)
		if e != nil || reply.Outcome.State != "outcomeUnknown" || !s.closed || s.TransactionStatus() != "unknown" {
			t.Fatal("unknown did not retire", e)
		}
		if _, e = store.Apply(context.Background(), s, apply); e == nil {
			t.Fatal("replayed")
		}
		if !reflect.DeepEqual(store.Status().Outcome, reply.Outcome) {
			t.Fatal("status lost")
		}
	})
}
func TestSQLiteReconstructionDetectsRetainedDataOrDependencyMutation(t *testing.T) {
	for _, mutation := range []string{"data", "schema"} {
		t.Run(mutation, func(t *testing.T) {
			s := toolSession(t)
			for _, sql := range []string{`CREATE TABLE records(v TEXT)`, `INSERT INTO records VALUES('kept')`, `CREATE TABLE unrelated(v TEXT)`} {
				toolExec(t, s, sql)
			}
			b, p := e4Prepare(t, s, "records", e4Draft())
			s.structureAfterStep = func(i int) {
				if i == 1 {
					sql := `DROP TABLE unrelated`
					if mutation == "data" {
						sql = `UPDATE main.` + quote("__dbeer_rebuild_"+b.Fingerprint[:12]) + ` SET v='changed'`
					}
					if e := s.exec(context.Background(), sql); e != nil {
						t.Fatal(e)
					}
				}
			}
			out := s.StructureApplySteps(context.Background(), b, p)
			if out[0].State != "rolledBack" {
				t.Fatal(out)
			}
			fresh, e := s.StructureLoad(context.Background(), b.Target)
			if e != nil || fresh.Fingerprint != b.Fingerprint {
				t.Fatal("rollback lost schema")
			}
		})
	}
}
