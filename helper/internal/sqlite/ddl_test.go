package sqlite

import (
	"context"
	"strings"
	"testing"

	"dbeer/helper/internal/tableedit"
)

func rebuildDefault(t *testing.T, s *Session, table, column, value string) {
	t.Helper()
	ctx := context.Background()
	b, e := s.StructureLoad(ctx, tableedit.Target{Schema: "main", Table: table})
	if e != nil {
		t.Fatal(e)
	}
	d := tableedit.Default{Kind: "text", Value: &value}
	p, e := s.StructurePrepare(ctx, b, tableedit.Draft{Changes: []tableedit.ColumnChange{{Name: column, Default: &d}}})
	if e != nil {
		t.Fatal(e)
	}
	out := s.StructureApplySteps(ctx, b, tableedit.Plan{SQL: p.SQL})
	if len(out) == 0 || out[0].State != "applied" {
		t.Fatal("source-preserving rebuild failed")
	}
}
func TestSQLitePreservedRebuildRetainsConstraintsAndExpressions(t *testing.T) {
	s := toolSession(t)
	ctx := context.Background()
	toolExec(t, s, `CREATE TABLE parent(a TEXT,b INTEGER,PRIMARY KEY(b,a)) WITHOUT ROWID`)
	toolExec(t, s, `INSERT INTO parent VALUES('parent',7)`)
	toolExec(t, s, `CREATE TABLE records(
 id INTEGER PRIMARY KEY AUTOINCREMENT,
 owner INTEGER, label TEXT,
 value VARCHAR(50) COLLATE NOCASE CONSTRAINT unique_value UNIQUE CONSTRAINT checked CHECK(length(value)<20),
 note TEXT CONSTRAINT default_note DEFAULT (lower('OLD')) CONSTRAINT required_note NOT NULL ON CONFLICT ABORT,
 derived TEXT AS (value || ',' || note) STORED,
 CONSTRAINT parent_reference FOREIGN KEY(owner,label) REFERENCES parent DEFERRABLE INITIALLY DEFERRED,
 CONSTRAINT paired UNIQUE(owner,label)
 )`)
	toolExec(t, s, `INSERT INTO records(owner,label,value) VALUES(7,'parent','First')`)
	toolExec(t, s, `CREATE INDEX expression_index ON records(lower(value)) WHERE owner IS NOT NULL`)
	toolExec(t, s, `CREATE TABLE audit(value TEXT)`)
	toolExec(t, s, `CREATE TRIGGER record_audit AFTER INSERT ON records BEGIN INSERT INTO audit VALUES(NEW.value); END`)
	rebuildDefault(t, s, "records", "note", "new")
	toolExec(t, s, `INSERT INTO records(value) VALUES('second')`)
	rows, _, e := s.query(ctx, `SELECT note,derived FROM records ORDER BY id`)
	if e != nil || cellText(rows[0][0]) != "old" || cellText(rows[0][1]) != "First,old" || cellText(rows[1][1]) != "second,new" {
		t.Fatal("data or generated expressions changed")
	}
	for _, sql := range []string{`INSERT INTO records(value) VALUES('FIRST')`, `INSERT INTO records(value) VALUES('this value is too long')`, `INSERT INTO records(value,note) VALUES('third',NULL)`, `INSERT INTO records(value,owner,label) VALUES('third',99,'missing')`} {
		if e = s.exec(ctx, sql); e == nil {
			t.Fatal("original constraint disappeared")
		}
	}
	rows, _, e = s.query(ctx, `SELECT count(*) FROM audit`)
	if e != nil || cellInt(rows[0][0]) != 1 {
		t.Fatal("trigger was not preserved")
	}
	rows, _, e = s.query(ctx, `SELECT count(*) FROM sqlite_schema WHERE name='expression_index'`)
	if e != nil || cellInt(rows[0][0]) != 1 {
		t.Fatal("expression index lost")
	}
	rows, _, e = s.query(ctx, `SELECT sql FROM sqlite_schema WHERE name='records'`)
	if e != nil {
		t.Fatal(e)
	}
	for _, clause := range []string{"CONSTRAINT unique_value UNIQUE", "CHECK(length(value)<20)", "COLLATE NOCASE", "CONSTRAINT default_note DEFAULT 'new'", "DEFERRABLE INITIALLY DEFERRED", "VARCHAR(50)", "CONSTRAINT paired UNIQUE(owner,label)"} {
		if !strings.Contains(cellText(rows[0][0]), clause) {
			t.Fatal("untouched declaration not retained")
		}
	}
}
func TestSQLitePreservedRebuildIgnoresKeywordTextAndComments(t *testing.T) {
	s := toolSession(t)
	ctx := context.Background()
	toolExec(t, s, `CREATE TABLE records(id INTEGER PRIMARY KEY, "CHECK,REFERENCES" TEXT DEFAULT 'DESC, CONSTRAINT', note TEXT /* UNIQUE, DEFAULT, CHECK */ DEFAULT 'old', marker TEXT DEFAULT (printf('%s,%s','a','b')))`)
	toolExec(t, s, `INSERT INTO records(id) VALUES(1)`)
	rebuildDefault(t, s, "records", "note", "new")
	toolExec(t, s, `INSERT INTO records(id) VALUES(2)`)
	rows, _, e := s.query(ctx, `SELECT "CHECK,REFERENCES",note,marker FROM records ORDER BY id`)
	if e != nil || cellText(rows[0][0]) != "DESC, CONSTRAINT" || cellText(rows[0][1]) != "old" || cellText(rows[1][1]) != "new" || cellText(rows[1][2]) != "a,b" {
		t.Fatal("quoted/comment/expression contents changed")
	}
}
func TestSQLitePreservedRebuildRetainsDescendingPrimaryRowids(t *testing.T) {
	s := toolSession(t)
	ctx := context.Background()
	toolExec(t, s, `CREATE TABLE records(id INTEGER PRIMARY KEY DESC,note TEXT)`)
	toolExec(t, s, `INSERT INTO records(rowid,id,note) VALUES(42,7,'old')`)
	rebuildDefault(t, s, "records", "note", "new")
	rows, _, e := s.query(ctx, `SELECT rowid,id FROM records`)
	if e != nil || cellInt(rows[0][0]) != 42 || cellInt(rows[0][1]) != 7 {
		t.Fatal("descending primary key acquired rowid alias semantics")
	}
}
func TestSQLitePreservedRebuildKeepsUntouchedTypeAliases(t *testing.T) {
	s := toolSession(t)
	ctx := context.Background()
	toolExec(t, s, `CREATE TABLE records(id INTEGER PRIMARY KEY,amount DECIMAL(12,3),note VARCHAR(100) DEFAULT 'old')`)
	toolExec(t, s, `INSERT INTO records VALUES(1,1.25,'kept')`)
	rebuildDefault(t, s, "records", "note", "new")
	rows, _, e := s.query(ctx, `SELECT type FROM pragma_table_xinfo('records') WHERE name='amount'`)
	if e != nil || cellText(rows[0][0]) != "DECIMAL(12,3)" {
		t.Fatal("untouched type alias changed")
	}
}

func TestSQLitePreservedRebuildKeepsNotNullConflictPolicy(t *testing.T) {
	s := toolSession(t)
	ctx := context.Background()
	toolExec(t, s, `CREATE TABLE records(id INTEGER PRIMARY KEY,note TEXT CONSTRAINT note_required NOT NULL ON CONFLICT FAIL DEFAULT 'old')`)
	toolExec(t, s, `INSERT INTO records VALUES(1,'kept')`)
	b, e := s.StructureLoad(ctx, tableedit.Target{Schema: "main", Table: "records"})
	if e != nil {
		t.Fatal(e)
	}
	nullable := false
	d := tableedit.Default{Kind: "text", Value: stringPtr("new")}
	p, e := s.StructurePrepare(ctx, b, tableedit.Draft{Changes: []tableedit.ColumnChange{{Name: "note", Nullable: &nullable, Default: &d}}})
	if e != nil {
		t.Fatal(e)
	}
	outcomes := s.StructureApplySteps(ctx, b, tableedit.Plan{SQL: p.SQL})
	if outcomes[0].State != "applied" {
		t.Fatal("preserving NOT NULL policy failed")
	}
	rows, _, e := s.query(ctx, `SELECT sql FROM sqlite_schema WHERE name='records'`)
	if e != nil || !strings.Contains(cellText(rows[0][0]), "CONSTRAINT note_required NOT NULL ON CONFLICT FAIL") {
		t.Fatal("NOT NULL conflict policy changed")
	}
}

func TestSQLitePreservedRebuildAddsColumnsBeforeTableConstraints(t *testing.T) {
	s := toolSession(t)
	ctx := context.Background()
	toolExec(t, s, `CREATE TABLE records(id INTEGER PRIMARY KEY,note TEXT,CONSTRAINT unique_note UNIQUE(note))`)
	toolExec(t, s, `INSERT INTO records VALUES(1,'kept')`)
	b, e := s.StructureLoad(ctx, tableedit.Target{Schema: "main", Table: "records"})
	if e != nil {
		t.Fatal(e)
	}
	def := tableedit.Default{Kind: "text", Value: stringPtr("new")}
	p, e := s.StructurePrepare(ctx, b, tableedit.Draft{Columns: []tableedit.Column{{Name: "extra", Type: tableedit.DataType{Kind: "text"}, Nullable: true, Default: tableedit.Default{Kind: "none"}}}, Changes: []tableedit.ColumnChange{{Name: "note", Default: &def}}})
	if e != nil {
		t.Fatal(e)
	}
	outcomes := s.StructureApplySteps(ctx, b, tableedit.Plan{SQL: p.SQL})
	if outcomes[0].State != "applied" {
		t.Fatal("new column after existing table constraint was not valid")
	}
	if _, e = s.tableInfo(ctx, "main", "records"); e != nil {
		t.Fatal(e)
	}
	if e = s.exec(ctx, `INSERT INTO records(id,note) VALUES(2,'kept')`); e == nil {
		t.Fatal("table constraint disappeared")
	}
}

func TestSQLitePreservedRebuildAddsTypeToTypelessColumns(t *testing.T) {
	for _, kind := range []string{"blob", "text"} {
		t.Run(kind, func(t *testing.T) {
			s := toolSession(t)
			ctx := context.Background()
			toolExec(t, s, `CREATE TABLE records(id INTEGER PRIMARY KEY,value)`)
			toolExec(t, s, `INSERT INTO records VALUES(1,17),(2,'kept'),(3,X'ff')`)
			b, e := s.StructureLoad(ctx, tableedit.Target{Schema: "main", Table: "records"})
			if e != nil {
				t.Fatal(e)
			}
			typ := tableedit.DataType{Kind: kind}
			p, e := s.StructurePrepare(ctx, b, tableedit.Draft{Changes: []tableedit.ColumnChange{{Name: "value", Type: &typ}}})
			if e != nil {
				t.Fatal("adding an explicit type failed", e)
			}
			out := s.StructureApplySteps(ctx, b, tableedit.Plan{SQL: p.SQL})
			want := "applied"
			if kind == "text" {
				want = "rolledBack"
			}
			if out[0].State != want {
				t.Fatal("incorrect affinity preservation outcome")
			}
			values, _, e := s.query(ctx, `SELECT typeof(value) FROM records ORDER BY id`)
			if e != nil || cellText(values[0][0]) != "integer" || cellText(values[1][0]) != "text" || cellText(values[2][0]) != "blob" {
				t.Fatal("stored types changed")
			}
			metadata, _, e := s.query(ctx, `SELECT type FROM pragma_table_xinfo('records') WHERE name='value'`)
			wantType := "BLOB"
			if kind == "text" {
				wantType = ""
			}
			if e != nil || cellText(metadata[0][0]) != wantType {
				t.Fatal("declared type change was not transactional")
			}
		})
	}
}
