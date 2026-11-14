package schemaimport

import (
	"context"
	"encoding/base64"
	"errors"
	"os"
	"path/filepath"
	"reflect"
	"strings"
	"testing"
	"time"

	"golang.org/x/sys/unix"

	"dbeer/helper/internal/adapter"
	"dbeer/helper/internal/mysql"
	"dbeer/helper/internal/postgres"
	"dbeer/helper/internal/protocol"
	"dbeer/helper/internal/schemabundle"
	sc "dbeer/helper/internal/schemacompare"
	sqlitedb "dbeer/helper/internal/sqlite"
)

func render(ctx context.Context, c sc.Capture, ref sc.Ref) (sc.Definition, error) {
	switch c.Context.Engine {
	case "postgresql":
		return postgres.RenderSchemaDefinition(ctx, c, ref)
	case "mysql":
		return mysql.RenderSchemaDefinition(ctx, c, ref)
	case "sqlite":
		return sqlitedb.RenderSchemaDefinition(ctx, c, ref)
	}
	return sc.Definition{}, ErrInvalid
}
func writeBundle(t *testing.T, c sc.Capture, schemas []string) (string, schemabundle.Manifest) {
	t.Helper()
	ctx := context.Background()
	r, e := schemabundle.Build(ctx, t.TempDir(), c, schemas, render)
	if e != nil {
		t.Fatal(e)
	}
	defer r.Close()
	dir := t.TempDir()
	files := []schemabundle.File{r.Summary.Manifest, r.Manifest.Capture}
	for _, o := range r.Manifest.Objects {
		files = append(files, o.File)
	}
	for _, f := range files {
		var data []byte
		for offset := int64(0); ; {
			chunk, e := r.Chunk(ctx, f.ID, offset, 65536)
			if e != nil {
				t.Fatal(e)
			}
			part, e := base64.StdEncoding.DecodeString(chunk.DataBase64)
			if e != nil {
				t.Fatal(e)
			}
			data = append(data, part...)
			offset = chunk.NextOffset
			if !chunk.HasMore {
				break
			}
		}
		if e = os.WriteFile(filepath.Join(dir, f.Path), data, 0600); e != nil {
			t.Fatal(e)
		}
	}
	return dir, r.Manifest
}
func sqliteCapture(t *testing.T) sc.Capture {
	t.Helper()
	ctx := context.Background()
	path := filepath.Join(t.TempDir(), "source.sqlite")
	if e := sqlitedb.Create(ctx, path); e != nil {
		t.Fatal(e)
	}
	s, e := sqlitedb.Open(ctx, protocol.Connection{Engine: "sqlite", SQLite: &protocol.SQLiteSettings{Path: path}, SSLMode: "disable"})
	if e != nil {
		t.Fatal(e)
	}
	defer s.Close()
	for _, sql := range []string{`CREATE TABLE parent(id INTEGER PRIMARY KEY, value TEXT DEFAULT 'NULL')`, `CREATE TABLE child(id INTEGER PRIMARY KEY, parent INTEGER REFERENCES parent(id), payload BLOB)`, `CREATE INDEX child_parent ON child(parent)`, `CREATE TRIGGER child_audit AFTER INSERT ON child BEGIN UPDATE child SET payload=coalesce(new.payload,x'') WHERE id=new.id; END`} {
		r := s.Execute(ctx, protocol.Command{Type: "execute", RequestID: "fixture", SessionID: "fixture", QueryID: "fixture", SQL: sql})
		if r.Type != "query.result" {
			t.Fatal("fixture DDL failed")
		}
	}
	collector := sc.NewCollector(ctx, sc.DefaultLimits())
	if e = s.(adapter.SchemaReader).ReadSchema(ctx, sc.CaptureSpec{Schemas: []string{"main"}, Limits: sc.DefaultLimits()}, collector); e != nil {
		t.Fatal(e)
	}
	return collector.Capture
}
func tableFile(t *testing.T, m schemabundle.Manifest, name string) string {
	t.Helper()
	for _, o := range m.Objects {
		if o.Ref.Kind == "table" && o.Ref.Name == name {
			return o.File.Path
		}
	}
	t.Fatal("missing table file")
	return ""
}

func TestSQLiteBundleUsesActualDefinitionsAndNeverLiveOpen(t *testing.T) {
	ctx := context.Background()
	capture := sqliteCapture(t)
	dir, m := writeBundle(t, capture, []string{"main"})
	got, e := Read(ctx, schemabundle.Source{Path: dir}, t.TempDir(), render)
	if e != nil {

		t.Fatal(e)
	}
	want, e := schemabundle.Canonical(ctx, capture)
	if e != nil {
		t.Fatal(e)
	}
	if !reflect.DeepEqual(got.Capture, want) || got.Summary.ModifiedSQL != 0 || got.Summary.Source.ContentSHA256 == "" {
		t.Fatal("pristine definition changed")
	}
	if _, e = Read(ctx, got.Summary.Source, t.TempDir(), render); e != nil {
		t.Fatal(e)
	}
	if e = os.Mkdir(filepath.Join(dir, ".git"), 0700); e != nil {
		t.Fatal(e)
	}
	if e = os.WriteFile(filepath.Join(dir, "README.md"), []byte("Git notes, not schema"), 0600); e != nil {
		t.Fatal(e)
	}
	if _, e = Read(ctx, got.Summary.Source, t.TempDir(), render); e != nil {
		t.Fatal(e)
	}
	path := filepath.Join(dir, tableFile(t, m, "parent"))
	b, _ := os.ReadFile(path)
	b = []byte(strings.Replace(string(b), "value TEXT", "value TEXT, added INTEGER", 1))
	if e = os.WriteFile(path, b, 0600); e != nil {
		t.Fatal(e)
	}
	if _, e = Read(ctx, got.Summary.Source, t.TempDir(), render); e == nil {
		t.Fatal("changed source identity accepted")
	}
}

func TestSQLiteEditedMembersAddRemoveAndRejectExecution(t *testing.T) {
	ctx := context.Background()
	dir, m := writeBundle(t, sqliteCapture(t), []string{"main"})
	parentPath := filepath.Join(dir, tableFile(t, m, "parent"))
	data, _ := os.ReadFile(parentPath)
	data = []byte(strings.Replace(string(data), "value TEXT DEFAULT 'NULL'", "value TEXT DEFAULT 'NULL', exact INTEGER DEFAULT 9007199254740993", 1))
	if e := os.WriteFile(parentPath, data, 0600); e != nil {
		t.Fatal(e)
	}
	if e := os.Remove(filepath.Join(dir, tableFile(t, m, "child"))); e != nil {
		t.Fatal(e)
	}
	if e := os.WriteFile(filepath.Join(dir, "new-table.sql"), []byte(`CREATE TABLE added(id INTEGER PRIMARY KEY, note TEXT DEFAULT '');`), 0600); e != nil {
		t.Fatal(e)
	}
	got, e := Read(ctx, schemabundle.Source{Path: dir, AllowSQLChanges: true}, t.TempDir(), render)
	if e != nil {
		t.Fatal(e)
	}
	if len(got.Capture.Tables) != 2 || got.Summary.ModifiedSQL != 3 {
		t.Fatal("edited file membership was lost")
	}
	for _, sql := range []string{`INSERT INTO added VALUES(1,'data');`, `ATTACH '/tmp/foreign.sqlite' AS other;`, `CREATE TABLE bad AS SELECT zeroblob(100);`, `CREATE VIRTUAL TABLE bad USING fts5(content);`, `PRAGMA writable_schema=ON;`, `CREATE TABLE bad(x); DROP TABLE added;`} {
		if e = os.WriteFile(filepath.Join(dir, "new-table.sql"), []byte(sql), 0600); e != nil {
			t.Fatal(e)
		}
		if _, e = Read(ctx, schemabundle.Source{Path: dir, AllowSQLChanges: true}, t.TempDir(), render); e == nil {
			t.Fatal("non-schema or unsupported program accepted")
		}
	}
}

func basicPG() sc.Capture {
	table := sc.Table{Ref: sc.Ref{Kind: "table", Schema: "public", Name: "items"}, Kind: sc.Known("r"), Storage: sc.Known("p"), Charset: sc.Absent[string](), Collation: sc.Absent[sc.Ref](), Options: sc.Complete[sc.Option](nil), Columns: sc.Complete[sc.Column](nil), Constraints: sc.Complete[sc.Constraint](nil), Indexes: sc.Complete[sc.Index](nil), Dependencies: sc.Complete[sc.Dependency](nil)}
	typ := sc.TypeUse{Ref: sc.Ref{Kind: "type", Schema: "pg_catalog", Name: "int4"}, Kind: "builtin", Modifiers: sc.Known(sc.TypeModifiers{}), Labels: sc.Complete[string](nil)}
	table.Columns.Items = []sc.Column{{Ref: sc.Ref{Kind: "column", Schema: "public", Table: "items", Name: "id"}, Ordinal: sc.Known(0), Type: sc.Known(typ), Nullable: sc.Known(false), Default: sc.Known(sc.Default{Kind: "none"}), Generated: sc.Known(sc.Generated{Kind: "none"}), Identity: sc.Known(sc.Identity{Kind: "none"}), Charset: sc.Absent[string](), Collation: sc.Absent[sc.Ref](), Visible: sc.Known(true), Comment: sc.Known(""), OnUpdate: sc.Absent[sc.Expression]()}}
	return sc.Capture{Context: sc.CaptureContext{Engine: "postgresql", Version: "17", Database: "fixture", StartedAt: "start", FinishedAt: "finish", Consistency: "repeatableRead", Visibility: "complete", EngineContext: sc.Known([]sc.Option{})}, Inventories: []sc.Inventory{{Schema: "public", Existence: "present", Tables: sc.Complete([]sc.Ref{table.Ref}), Types: sc.Complete[sc.Ref](nil)}}, Tables: []sc.Table{table}, Types: []sc.TypeDefinition{}, Sequences: []sc.Sequence{}, Issues: []sc.Issue{}}
}
func TestPostgresEditedColumnsAndHistoricalMembership(t *testing.T) {
	ctx := context.Background()
	capture := basicPG()
	dir, m := writeBundle(t, capture, []string{"public"})
	got, e := Read(ctx, schemabundle.Source{Path: dir}, t.TempDir(), render)
	if e != nil {
		t.Fatal(e)
	}
	if got.Summary.ManualObjects != 0 || len(got.Capture.Tables) != 1 {
		t.Fatal("ordinary parsed table became manual")
	}
	path := filepath.Join(dir, tableFile(t, m, "items"))
	b, _ := os.ReadFile(path)
	b = []byte(strings.Replace(string(b), `"id" integer NOT NULL`, `"id" bigint NOT NULL, "amount" numeric(40,20) DEFAULT 9007199254740993.12345678901234567890`, 1))
	if e = os.WriteFile(path, b, 0600); e != nil {
		t.Fatal(e)
	}
	got, e = Read(ctx, schemabundle.Source{Path: dir, AllowSQLChanges: true}, t.TempDir(), render)
	if e != nil {
		t.Fatal(e)
	}
	if len(got.Capture.Tables[0].Columns.Items) != 2 || got.Capture.Tables[0].Columns.Items[0].Type.Value.Ref.Name != "int8" {
		t.Fatal("typed edit was not parsed")
	}
	if e = os.WriteFile(filepath.Join(dir, "new.sql"), []byte(`CREATE TABLE "public"."new" ("id" integer NOT NULL);`), 0600); e != nil {
		t.Fatal(e)
	}
	if e = os.Remove(path); e != nil {
		t.Fatal(e)
	}
	got, e = Read(ctx, schemabundle.Source{Path: dir, AllowSQLChanges: true}, t.TempDir(), render)
	if e != nil {
		t.Fatal(e)
	}
	if len(got.Capture.Tables) != 1 || got.Capture.Tables[0].Ref.Name != "new" {
		t.Fatal("add/remove membership lost")
	}
}

func TestForgedCaptureCannotSmuggleDefaultStatementsOrOwnership(t *testing.T) {
	ctx := context.Background()
	for _, ownership := range []bool{false, true} {
		c := basicPG()
		if ownership {
			c.Tables[0].Columns.Items[0].Ref.Table = "different"
		} else {
			c.Tables[0].Columns.Items[0].Default = sc.Known(sc.Default{Kind: "expression", Expression: &sc.Expression{Text: `0); CREATE TABLE "public"."unrelated" (x integer); --`, Dependencies: sc.Complete[sc.Ref](nil)}})
		}
		dir, _ := writeBundle(t, c, []string{"public"})
		if _, e := Read(ctx, schemabundle.Source{Path: dir}, t.TempDir(), render); e == nil {
			t.Fatal("forged self-consistent hashes bypassed semantic validation")
		}
	}
}
func TestStrictBundleReadsRejectCorruptionSymlinksExtrasAndCancellation(t *testing.T) {
	ctx := context.Background()
	dir, m := writeBundle(t, basicPG(), []string{"public"})
	path := filepath.Join(dir, tableFile(t, m, "items"))
	b, _ := os.ReadFile(path)
	if e := os.WriteFile(filepath.Join(dir, "not-schema.txt"), []byte("ignored would be ambiguous"), 0600); e != nil {
		t.Fatal(e)
	}
	if _, e := Read(ctx, schemabundle.Source{Path: dir}, t.TempDir(), render); e == nil {
		t.Fatal("unknown file ignored")
	}
	os.Remove(filepath.Join(dir, "not-schema.txt"))
	outside := filepath.Join(t.TempDir(), "outside.sql")
	os.WriteFile(outside, b, 0600)
	os.Remove(path)
	if e := os.Symlink(outside, path); e != nil {
		t.Fatal(e)
	}
	if _, e := Read(ctx, schemabundle.Source{Path: dir}, t.TempDir(), render); e == nil {
		t.Fatal("symlink followed")
	}
	os.Remove(path)
	os.WriteFile(path, b, 0600)
	manifestPath := filepath.Join(dir, "manifest.json")
	raw, _ := os.ReadFile(manifestPath)
	wrongCase := []byte(strings.Replace(string(raw), `"engine":`, `"Engine":`, 1))
	os.WriteFile(manifestPath, wrongCase, 0600)
	if _, e := Read(ctx, schemabundle.Source{Path: dir}, t.TempDir(), render); e == nil {
		t.Fatal("case-insensitive field alias accepted")
	}
	raw = []byte(strings.Replace(string(raw), `"formatVersion": 1`, `"formatVersion": 1, "formatVersion": 1`, 1))
	os.WriteFile(manifestPath, raw, 0600)
	if _, e := Read(ctx, schemabundle.Source{Path: dir}, t.TempDir(), render); e == nil {
		t.Fatal("duplicate JSON accepted")
	}
	cancelled, cancel := context.WithCancel(ctx)
	cancel()
	if _, e := Read(cancelled, schemabundle.Source{Path: dir}, t.TempDir(), render); !errors.Is(e, context.Canceled) {
		t.Fatal("cancellation not retained")
	}
}

func TestDDLParserBoundsAndByteExactLiterals(t *testing.T) {
	ctx := context.Background()
	for _, sql := range []string{`CREATE TABLE "public"."é" ("a" text DEFAULT '); DROP TABLE other; --');`, `CREATE TABLE "public"."é" ("a" text DEFAULT 'NULL', "b" text DEFAULT '');`} {
		ast, e := parseDefinition(ctx, sql, "postgresql", "public", false)
		if e != nil || len(ast.tables) != 1 {
			t.Fatal("quoted literal became a statement")
		}
	}
	a, _ := lex(ctx, `"é"`, "postgresql", false)
	b, _ := lex(ctx, `"é"`, "postgresql", false)
	if tokensSame(a, b) {
		t.Fatal("Unicode identifiers normalized")
	}
	for _, input := range []string{"NULL", "'NULL'", "''", "9007199254740993.12345678901234567890"} {
		ts, e := lex(ctx, input, "postgresql", false)
		if e != nil {
			t.Fatal(e)
		}
		d, e := pureDefault(ts, "postgresql")
		if e != nil {
			t.Fatal(e)
		}
		if input == "NULL" && d.Kind != "sqlNull" || input == "'NULL'" && (d.Value == nil || *d.Value != "NULL") || input == "''" && (d.Value == nil || *d.Value != "") {
			t.Fatal("default representation changed")
		}
	}
	if _, e := lex(ctx, strings.Repeat(" ", 128<<10+1), "postgresql", false); !errors.Is(e, ErrLimit) {
		t.Fatal("SQL byte limit lost")
	}
	ts, e := lex(ctx, strings.Repeat("(", 129)+"1"+strings.Repeat(")", 129), "postgresql", false)
	if e != nil {
		t.Fatal(e)
	}
	if _, e = statements(ts); !errors.Is(e, ErrLimit) {
		t.Fatal("nesting budget lost")
	}
	if (schemabundle.Source{Path: "relative"}).Valid(true) || (schemabundle.Source{Path: t.TempDir(), Engine: "postgresql"}).Valid(true) {
		t.Fatal("invalid source descriptor accepted")
	}
}

func TestPostgresEnumSequenceMembershipAndMissingDependencies(t *testing.T) {
	ctx := context.Background()
	capture := basicPG()
	enumSQL := `CREATE TYPE "public"."mood" AS ENUM ('é','é','');`
	ast, e := parseDefinition(ctx, enumSQL, "postgresql", "public", false)
	if e != nil {
		t.Fatal(e)
	}
	enum, e := parseEnum(ast.other[0], "public")
	if e != nil {
		t.Fatal(e)
	}
	seqSQL := `CREATE SEQUENCE "public"."number" AS bigint START WITH 9007199254740993 INCREMENT BY 2 MINVALUE 1 MAXVALUE 9223372036854775807 CACHE 20 NO CYCLE OWNED BY "public"."items"."id";`
	ast, e = parseDefinition(ctx, seqSQL, "postgresql", "public", false)
	if e != nil {
		t.Fatal(e)
	}
	seq, e := parseSequence(ast.other[0], "public")
	if e != nil {
		t.Fatal(e)
	}
	capture.Types = []sc.TypeDefinition{enum}
	capture.Sequences = []sc.Sequence{seq}
	capture.Inventories[0].Types = sc.Complete([]sc.Ref{enum.Ref})
	dir, m := writeBundle(t, capture, []string{"public"})
	got, e := Read(ctx, schemabundle.Source{Path: dir}, t.TempDir(), render)
	if e != nil {
		t.Fatal(e)
	}
	if got.Summary.ManualObjects != 0 || len(got.Capture.Types) != 1 || len(got.Capture.Sequences) != 1 {
		t.Fatal("supported enum or sequence lost")
	}
	for _, o := range m.Objects {
		if o.Ref.Kind == "type" {
			data, _ := os.ReadFile(filepath.Join(dir, o.File.Path))
			os.WriteFile(filepath.Join(dir, o.File.Path), []byte(strings.Replace(string(data), "AS ENUM (", "AS ENUM (E'new', ", 1)), 0600)
		}
		if o.Ref.Kind == "sequence" {
			os.Remove(filepath.Join(dir, o.File.Path))
		}
	}
	os.WriteFile(filepath.Join(dir, "added-sequence.sql"), []byte(strings.Replace(seqSQL, `"number"`, `"added"`, 1)), 0600)
	got, e = Read(ctx, schemabundle.Source{Path: dir, AllowSQLChanges: true}, t.TempDir(), render)
	if e != nil {
		t.Fatal(e)
	}
	if got.Summary.ModifiedSQL != 3 || len(got.Capture.Sequences) != 1 || got.Capture.Sequences[0].Ref.Name != "added" || got.Capture.Types[0].Labels.Items[0] != "new" {
		t.Fatal("type or sequence Git membership edit lost")
	}
	// Removing a referenced selected table keeps a visible unknown dependency.
	os.Remove(filepath.Join(dir, tableFile(t, m, "items")))
	got, e = Read(ctx, schemabundle.Source{Path: dir, AllowSQLChanges: true}, t.TempDir(), render)
	if e != nil {
		t.Fatal(e)
	}
	if len(got.Capture.Tables) != 0 {
		t.Fatal("removed table retained")
	}
	if got.Summary.Complete || got.Summary.ManualObjects != 1 {
		t.Fatal("orphaned sequence owner became proven")
	}
}
func TestReaderPinsRootParentFilesAndEnforcesActualReadBounds(t *testing.T) {
	ctx := context.Background()
	for _, mutation := range []string{"same-inode", "replacement", "root-symlink", "parent-replacement"} {
		t.Run(mutation, func(t *testing.T) {
			base := t.TempDir()
			parent := filepath.Join(base, "parent")
			dir := filepath.Join(parent, "source")
			if e := os.MkdirAll(dir, 0700); e != nil {
				t.Fatal(e)
			}
			path := filepath.Join(dir, "object.sql")
			if e := os.WriteFile(path, []byte("abc"), 0600); e != nil {
				t.Fatal(e)
			}
			p, e := openDirectory(dir)
			if e != nil {
				t.Fatal(e)
			}
			defer p.file.Close()
			defer p.parent.Close()
			names, e := p.names(ctx)
			if e != nil {
				t.Fatal(e)
			}
			if _, e = p.read(ctx, "object.sql", 3); e != nil {
				t.Fatal(e)
			}
			switch mutation {
			case "same-inode":
				before, _ := os.Stat(path)
				os.WriteFile(path, []byte("xyz"), 0600)
				os.Chtimes(path, before.ModTime(), before.ModTime())
			case "replacement":
				os.Rename(path, path+".old")
				os.WriteFile(path, []byte("abc"), 0600)
				os.Remove(path + ".old")
			case "root-symlink":
				os.Rename(dir, dir+".old")
				os.Symlink(dir+".old", dir)
			case "parent-replacement":
				os.Rename(parent, parent+".old")
				os.MkdirAll(dir, 0700)
				os.WriteFile(path, []byte("abc"), 0600)
			}
			if e = p.check(ctx, names); !errors.Is(e, ErrChanged) {
				t.Fatal("mutation was accepted")
			}
		})
	}
	dir := t.TempDir()
	os.WriteFile(filepath.Join(dir, "large.sql"), []byte("1234"), 0600)
	p, e := openDirectory(dir)
	if e != nil {
		t.Fatal(e)
	}
	defer p.file.Close()
	defer p.parent.Close()
	if _, e = p.read(ctx, "large.sql", 3); !errors.Is(e, ErrLimit) {
		t.Fatal("actual file exceeded read bound")
	}
	p.bytes = schemabundle.MaxBytes - 2
	if _, e = p.read(ctx, "large.sql", 4); !errors.Is(e, ErrLimit) {
		t.Fatal("total actual bytes exceeded import bound")
	}
}
func TestUnsupportedSelfConsistentFactsRemainManualAndChangedDefaultsParse(t *testing.T) {
	ctx := context.Background()
	capture := basicPG()
	raw := "ignored raw type syntax"
	capture.Tables[0].Columns.Items[0].Type.Value.Modifiers.Value.SQL = &raw
	dir, m := writeBundle(t, capture, []string{"public"})
	got, e := Read(ctx, schemabundle.Source{Path: dir}, t.TempDir(), render)
	if e != nil {
		t.Fatal(e)
	}
	if got.Summary.Complete || got.Summary.ManualObjects != 1 {
		t.Fatal("non-rendered forged fact became proven")
	}
	path := filepath.Join(dir, tableFile(t, m, "items"))
	data, _ := os.ReadFile(path)
	data = []byte(strings.Replace(string(data), `integer NOT NULL`, `integer NOT NULL DEFAULT 9007199254740993`, 1))
	os.WriteFile(path, data, 0600)
	got, e = Read(ctx, schemabundle.Source{Path: dir, AllowSQLChanges: true}, t.TempDir(), render)
	if e != nil {
		t.Fatal(e)
	}
	if got.Capture.Tables[0].Columns.Items[0].Default.Value.Expression == nil || got.Summary.Complete {
		t.Fatal("changed default was rejected or unverifiable baseline became complete")
	}
}

func TestNumericTokensNeverMergeInvalidDefaultsOrModifiers(t *testing.T) {
	ctx := context.Background()
	for _, input := range []string{"1 2", "1 /* separated */ 2", "1 e2", ". 5", "- 1 2", "1.2.3"} {
		ts, err := lex(ctx, input, "postgresql", false)
		if err != nil {
			t.Fatal(err)
		}
		if _, err = pureDefault(ts, "postgresql"); err == nil {
			t.Fatal("invalid numeric default accepted")
		}
		if _, err = intLiteral(ts); err == nil {
			t.Fatal("invalid integer modifier accepted")
		}
	}
	for _, input := range []string{"9007199254740993.12345678901234567890", "- .5", "1e-100", "+ 12"} {
		ts, err := lex(ctx, input, "postgresql", false)
		if err != nil {
			t.Fatal(err)
		}
		d, err := pureDefault(ts, "postgresql")
		if err != nil || d.Expression == nil {
			t.Fatal("valid exact numeric default rejected")
		}
		if strings.Contains(d.Expression.Text, " ") {
			t.Fatal("numeric default was emitted with separated tokens")
		}
	}
}

func TestEditedColumnCommentsDoNotRetainDeletedStatements(t *testing.T) {
	ctx := context.Background()
	capture := basicPG()
	capture.Tables[0].Columns.Items[0].Comment = sc.Known("original comment")
	dir, m := writeBundle(t, capture, []string{"public"})
	path := filepath.Join(dir, tableFile(t, m, "items"))
	data, err := os.ReadFile(path)
	if err != nil {
		t.Fatal(err)
	}
	sql := string(data)
	comment := strings.Index(sql, "COMMENT ON COLUMN")
	if comment < 0 {
		t.Fatal("fixture comment missing")
	}
	if err = os.WriteFile(path, []byte(sql[:comment]), 0600); err != nil {
		t.Fatal(err)
	}
	got, err := Read(ctx, schemabundle.Source{Path: dir, AllowSQLChanges: true}, t.TempDir(), render)
	if err != nil {
		t.Fatal(err)
	}
	if value := got.Capture.Tables[0].Columns.Items[0].Comment.Value; value == nil || *value != "" {
		t.Fatal("removed comment survived Git edit")
	}
	if err = os.WriteFile(path, []byte(sql[:comment]+`COMMENT ON COLUMN "public"."items"."id" IS 'replacement';`), 0600); err != nil {
		t.Fatal(err)
	}
	got, err = Read(ctx, schemabundle.Source{Path: dir, AllowSQLChanges: true}, t.TempDir(), render)
	if err != nil {
		t.Fatal(err)
	}
	if value := got.Capture.Tables[0].Columns.Items[0].Comment.Value; value == nil || *value != "replacement" {
		t.Fatal("replacement comment lost")
	}
}

func TestArtifactJSONRejectsMalformedSurrogatesWithoutNormalizingIdentifiers(t *testing.T) {
	ctx := context.Background()
	type value struct {
		Name string `json:"name"`
	}
	for _, raw := range []string{`{"name":"\ud800"}`, `{"name":"\udc00"}`, `{"name":"\ud800x"}`, `{"na\ud800me":"x"}`} {
		var got value
		if err := strictJSON(ctx, []byte(raw), &got); err == nil {
			t.Fatal("malformed artifact Unicode rewritten")
		}
	}
	for raw, want := range map[string]string{`{"name":"\ud83d\ude00"}`: "😀", `{"name":"\ufffd"}`: "�", `{"name":"é"}`: "é", `{"name":"e\u0301"}`: "é", `{"name":"\\ud800"}`: `\ud800`} {
		var got value
		if err := strictJSON(ctx, []byte(raw), &got); err != nil || got.Name != want {
			t.Fatal("valid original scalar identity changed")
		}
	}
}

func TestSpecialFilesCannotBlockInspectionOrRecheck(t *testing.T) {
	for _, recheck := range []bool{false, true} {
		t.Run(map[bool]string{false: "manifest", true: "recheck"}[recheck], func(t *testing.T) {
			dir := t.TempDir()
			name := "manifest.json"
			path := filepath.Join(dir, name)
			ctx, cancel := context.WithTimeout(context.Background(), 50*time.Millisecond)
			defer cancel()
			var inspect func() error
			if recheck {
				if err := os.WriteFile(path, []byte("original"), 0600); err != nil {
					t.Fatal(err)
				}
				p, err := openDirectory(dir)
				if err != nil {
					t.Fatal(err)
				}
				defer p.file.Close()
				defer p.parent.Close()
				names, err := p.names(ctx)
				if err != nil {
					t.Fatal(err)
				}
				if _, err = p.read(ctx, name, 128); err != nil {
					t.Fatal(err)
				}
				if err = os.Remove(path); err != nil {
					t.Fatal(err)
				}
				inspect = func() error { return p.check(ctx, names) }
			} else {
				inspect = func() error { _, err := Read(ctx, schemabundle.Source{Path: dir}, t.TempDir(), render); return err }
			}
			if err := unix.Mkfifo(path, 0600); err != nil {
				t.Fatal(err)
			}
			done := make(chan error, 1)
			go func() { done <- inspect() }()
			select {
			case err := <-done:
				if err == nil {
					t.Fatal("special file accepted")
				}
			case <-time.After(500 * time.Millisecond):
				// Unblock a regressed FIFO reader before failing, so the test cannot leak an owner.
				fd, err := unix.Open(path, unix.O_RDWR|unix.O_NONBLOCK, 0)
				if err == nil {
					defer unix.Close(fd)
				}
				select {
				case <-done:
				case <-time.After(time.Second):
				}
				t.Fatal("special file blocked past inspection deadline")
			}
		})
	}
}

func TestMySQLIdentifierBackslashesAreNotStringEscapes(t *testing.T) {
	for _, noBackslash := range []bool{false, true} {
		for _, name := range []string{`a\n`, `a\q`, "a`b", `a\\b`} {
			quoted := "`" + strings.ReplaceAll(name, "`", "``") + "`"
			ts, err := lex(context.Background(), quoted, "mysql", noBackslash)
			if err != nil || len(ts) != 1 || ts[0].kind != 'q' || ts[0].value != name {
				t.Fatal("backtick identifier changed")
			}
		}
	}
	for _, noBackslash := range []bool{false, true} {
		ts, err := lex(context.Background(), `'a\n'`, "mysql", noBackslash)
		want := "a\n"
		if noBackslash {
			want = `a\n`
		}
		if err != nil || len(ts) != 1 || ts[0].value != want {
			t.Fatal("string escape policy changed")
		}
	}
}

func TestRelationalListsRejectEveryEmptyTerm(t *testing.T) {
	ctx := context.Background()
	for _, engine := range []string{"postgresql", "mysql"} {
		for _, body := range []string{"", ",id integer", "id integer,", "id integer,,n integer"} {
			if _, err := parseDefinition(ctx, "CREATE TABLE t("+body+");", engine, "public", false); err == nil {
				t.Fatal("empty table term accepted")
			}
		}
		for _, body := range []string{"", ",id", "id,", "id,,n"} {
			ts, err := lex(ctx, body, engine, false)
			if err != nil {
				t.Fatal(err)
			}
			if _, err = commaTerms(ts); err == nil {
				t.Fatal("empty list term accepted")
			}
			ref := sc.Ref{Kind: "table", Schema: "public", Name: "t"}
			constraint, _ := lex(ctx, "CONSTRAINT k UNIQUE ("+body+")", engine, false)
			if _, _, err = parseConstraint(constraint, ref, engine); err == nil {
				t.Fatal("empty key term accepted")
			}
			index, _ := lex(ctx, "CREATE INDEX k ON t ("+body+")", engine, false)
			if _, err = parseStandaloneIndex(index, ref, engine); err == nil {
				t.Fatal("empty index term accepted")
			}
		}
		for _, body := range []string{"", ",10", "10,", "10,,2"} {
			ts, _ := lex(ctx, "numeric("+body+")", engine, false)
			if _, err := builtinType(ts, engine); err == nil {
				t.Fatal("empty type modifier accepted")
			}
		}
	}
	for _, body := range []string{",'a'", "'a',", "'a',,'b'"} {
		ts, _ := lex(ctx, "CREATE TYPE mood AS ENUM ("+body+")", "postgresql", false)
		if _, err := parseEnum(ts, "public"); err == nil {
			t.Fatal("empty enum term accepted")
		}
	}
}

func TestEditedPostgresTableRejectsTrailingCommaAtImportBoundary(t *testing.T) {
	ctx := context.Background()
	dir, manifest := writeBundle(t, basicPG(), []string{"public"})
	path := filepath.Join(dir, tableFile(t, manifest, "items"))
	if err := os.WriteFile(path, []byte(`CREATE TABLE "public"."items"("id" integer NOT NULL,);`), 0600); err != nil {
		t.Fatal(err)
	}
	if _, err := Read(ctx, schemabundle.Source{Path: dir, AllowSQLChanges: true}, t.TempDir(), render); err == nil {
		t.Fatal("invalid edited table accepted as parsed source")
	}
}

func TestPostgresBuiltinTypeIdentityPreservesQuotedSpelling(t *testing.T) {
	ctx := context.Background()
	for _, input := range []string{`"pg_catalog"."INT4"`, `"integer"`, `pg_catalog.integer`, `"timestamp" WITH TIME ZONE`} {
		ts, _ := lex(ctx, input, "postgresql", false)
		if _, err := builtinType(ts, "postgresql"); err == nil {
			t.Fatal("quoted or qualified type became a different builtin")
		}
	}
	for _, input := range []string{`"pg_catalog"."int4"`, `pg_catalog.int4`, `"int4"`, `INTEGER`} {
		ts, _ := lex(ctx, input, "postgresql", false)
		typ, err := builtinType(ts, "postgresql")
		if err != nil || typ.Ref.Name != "int4" {
			t.Fatal("actual builtin identity lost")
		}
	}
	dir, _ := writeBundle(t, basicPG(), []string{"public"})
	for _, input := range []string{`"pg_catalog"."INT4"`, `"integer"`, `pg_catalog.integer`} {
		sql := `CREATE TABLE "public"."added"(id ` + input + `);`
		if err := os.WriteFile(filepath.Join(dir, "added.sql"), []byte(sql), 0600); err != nil {
			t.Fatal(err)
		}
		if _, err := Read(ctx, schemabundle.Source{Path: dir, AllowSQLChanges: true}, t.TempDir(), render); err == nil {
			t.Fatal("unresolved quoted type accepted by import")
		}
	}
}
