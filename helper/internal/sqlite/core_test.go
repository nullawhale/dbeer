package sqlite

import (
	"context"
	"encoding/base64"
	"encoding/json"
	"os"
	"path/filepath"
	"strings"
	"testing"
	"time"

	"dbeer/helper/internal/protocol"
)

func openCore(t *testing.T, readOnly bool) (*Session, string) {
	t.Helper()
	path := filepath.Join(t.TempDir(), "test.sqlite")
	if err := Create(context.Background(), path); err != nil {
		t.Fatal(err)
	}
	c := protocol.Connection{Engine: "sqlite", SQLite: &protocol.SQLiteSettings{Path: path}, Policy: &protocol.ExecutionPolicy{ReadOnly: readOnly}}
	physical, err := Open(context.Background(), c)
	if err != nil {
		t.Fatal(err)
	}
	s := physical.(*Session)
	t.Cleanup(s.Close)
	return s, path
}
func runCore(t *testing.T, s *Session, sql string) protocol.Response {
	t.Helper()
	r := s.Execute(context.Background(), protocol.Command{Type: "execute", RequestID: "r", SessionID: "s", QueryID: "q", SQL: sql})
	if r.Type == "error" {
		t.Fatalf("SQLite statement failed: %s", r.Message)
	}
	return r
}
func TestFileCreationAndMissingOpen(t *testing.T) {
	path := filepath.Join(t.TempDir(), "new.sqlite")
	if _, err := Open(context.Background(), protocol.Connection{Engine: "sqlite", SQLite: &protocol.SQLiteSettings{Path: path}}); err == nil {
		t.Fatal("missing file opened")
	}
	if _, err := os.Stat(path); !os.IsNotExist(err) {
		t.Fatal("opening created a missing file")
	}
	if err := Create(context.Background(), path); err != nil {
		t.Fatal(err)
	}
	before, err := os.ReadFile(path)
	if err != nil || len(before) < 100 || !strings.HasPrefix(string(before), "SQLite format 3") {
		t.Fatal("creation did not initialize a database")
	}
	if err = Create(context.Background(), path); err == nil {
		t.Fatal("creation overwrote an existing file")
	}
	after, _ := os.ReadFile(path)
	if string(before) != string(after) {
		t.Fatal("existing database changed")
	}
}
func TestTypedValuesAndTrailingComments(t *testing.T) {
	s, _ := openCore(t, false)
	r := runCore(t, s, "SELECT NULL,9223372036854775807,1.5,'', 'NULL', CAST(X'610062' AS TEXT), CAST(X'ff' AS TEXT), X'', X'ff'; -- retained comment\n /* tail */ ")
	want := []protocol.SQLiteValue{{Type: "null"}, {Type: "integer", Value: "9223372036854775807"}, {Type: "real", Value: "3ff8000000000000"}, {Type: "text"}, {Type: "text", Value: "TlVMTA=="}, {Type: "text", Value: "YQBi"}, {Type: "text", Value: "/w=="}, {Type: "blob"}, {Type: "blob", Value: "/w=="}}
	b, _ := json.Marshal(r.SQLiteValues[0])
	w, _ := json.Marshal(want)
	if string(b) != string(w) {
		t.Fatalf("typed values differ: %s", b)
	}
	if r.Rows[0][0] != nil || *r.Rows[0][3] != "" || *r.Rows[0][4] != "NULL" {
		t.Fatal("NULL distinctions were lost")
	}
	if r = s.Execute(context.Background(), protocol.Command{Type: "execute", SQL: "SELECT 1; SELECT 2"}); r.Type != "error" || !r.SQLNotExecuted {
		t.Fatal("multiple statements were executed")
	}
}
func TestIndependentTransactionsAndSavepoints(t *testing.T) {
	s, path := openCore(t, false)
	runCore(t, s, "CREATE TABLE t(id INTEGER PRIMARY KEY,v)")
	other, err := Open(context.Background(), protocol.Connection{Engine: "sqlite", SQLite: &protocol.SQLiteSettings{Path: path}})
	if err != nil {
		t.Fatal(err)
	}
	defer other.Close()
	runCore(t, s, "BEGIN")
	runCore(t, s, "INSERT INTO t VALUES(1,'local')")
	runCore(t, s, "SAVEPOINT p")
	runCore(t, s, "INSERT INTO t VALUES(2,'undone')")
	runCore(t, s, "ROLLBACK TO p")
	runCore(t, s, "RELEASE p")
	r := other.Execute(context.Background(), protocol.Command{Type: "execute", SQL: "SELECT count(*) FROM t"})
	if r.Type != "query.result" || *r.Rows[0][0] != "0" {
		t.Fatal("another session saw uncommitted rows")
	}
	if s.TransactionStatus() != "transaction" {
		t.Fatal("savepoint lost transaction")
	}
	runCore(t, s, "COMMIT")
	r = other.Execute(context.Background(), protocol.Command{Type: "execute", SQL: "SELECT count(*) FROM t"})
	if r.Type != "query.result" || *r.Rows[0][0] != "1" {
		t.Fatal("commit did not publish exactly the retained row")
	}
}
func TestReadonlyAndAttachBoundaries(t *testing.T) {
	s, path := openCore(t, false)
	runCore(t, s, "CREATE TABLE t(id INTEGER PRIMARY KEY,v)")
	ro, err := Open(context.Background(), protocol.Connection{Engine: "sqlite", SQLite: &protocol.SQLiteSettings{Path: path}, Policy: &protocol.ExecutionPolicy{ReadOnly: true}})
	if err != nil {
		t.Fatal(err)
	}
	defer ro.Close()
	for _, sql := range []string{"INSERT INTO t VALUES(1,'x')", "PRAGMA query_only=OFF", "PRAGMA writable_schema=ON", "PRAGMA journal_mode=WAL", "SELECT load_extension('missing')", "VACUUM INTO 'missing.sqlite'"} {
		if r := ro.Execute(context.Background(), protocol.Command{Type: "execute", SQL: sql}); r.Type != "error" {
			t.Fatal("readonly accepted prohibited SQL")
		}
	}
	missing := filepath.Join(t.TempDir(), "missing.sqlite")
	for _, sql := range []string{"ATTACH '" + missing + "' AS x", "ATTACH ':memory:' AS x", "ATTACH 'file:" + path + "' AS x", "SELECT load_extension('missing')"} {
		if r := s.Execute(context.Background(), protocol.Command{Type: "execute", SQL: sql}); r.Type != "error" {
			t.Fatal("unsafe attachment or extension was accepted")
		}
	}
	if _, err = os.Stat(missing); !os.IsNotExist(err) {
		t.Fatal("ATTACH created a missing database")
	}
	attached := filepath.Join(t.TempDir(), "attached.sqlite")
	if err = Create(context.Background(), attached); err != nil {
		t.Fatal(err)
	}
	runCore(t, s, "ATTACH DATABASE '"+attached+"' AS extra")
	runCore(t, s, "CREATE TABLE extra.u(id INTEGER)")
	runCore(t, s, "INSERT INTO extra.u VALUES(7)")
	if r := runCore(t, s, "SELECT id FROM extra.u"); *r.Rows[0][0] != "7" {
		t.Fatal("attached database was not usable")
	}
	runCore(t, s, "DETACH extra")
	if err := os.Rename(attached, attached+".old"); err != nil {
		t.Fatal(err)
	}
	// Detached file identities must no longer restrict this SQL session.
	runCore(t, s, "SELECT 1")
	if err := Create(context.Background(), attached); err != nil {
		t.Fatal(err)
	}
	runCore(t, s, "ATTACH DATABASE '"+attached+"' AS extra")
	if err := os.Rename(attached, attached+".replaced"); err != nil {
		t.Fatal(err)
	}
	if err := Create(context.Background(), attached); err != nil {
		t.Fatal(err)
	}
	if r := s.Execute(context.Background(), protocol.Command{Type: "execute", SQL: "CREATE TABLE extra.wrong(id)"}); r.Type != "error" {
		t.Fatal("session accepted a replaced attached file")
	}
}
func TestCancelThenReuseAndFileReplacement(t *testing.T) {
	s, path := openCore(t, false)
	ctx, cancel := context.WithTimeout(context.Background(), 20*time.Millisecond)
	defer cancel()
	r := s.Execute(ctx, protocol.Command{Type: "execute", SQL: "WITH RECURSIVE n(x) AS (VALUES(1) UNION ALL SELECT x+1 FROM n) SELECT sum(x) FROM n"})
	if r.Type != "error" || r.Category != "timeout" {
		t.Fatal("long query did not time out")
	}
	runCore(t, s, "SELECT 1")
	if err := os.Rename(path, path+".old"); err != nil {
		t.Fatal(err)
	}
	if err := Create(context.Background(), path); err != nil {
		t.Fatal(err)
	}
	if r = s.Execute(context.Background(), protocol.Command{Type: "execute", SQL: "CREATE TABLE wrong(id)"}); r.Type != "error" {
		t.Fatal("session used a replaced file")
	}
}
func TestCatalogBrowseFiltersAndEditConflict(t *testing.T) {
	s, _ := openCore(t, false)
	runCore(t, s, "CREATE TABLE t(id INTEGER PRIMARY KEY,v TEXT,b BLOB)")
	runCore(t, s, "INSERT INTO t VALUES(1,'one',X'ff'),(2,'two',X'')")
	value := "one"
	r := s.Execute(context.Background(), protocol.Command{Type: "catalog", Catalog: &protocol.CatalogRequest{Kind: "browse", Schema: "main", Object: "t", ObjectKind: "table", Filters: []protocol.CatalogFilter{{Column: "v", Operator: "eq", Value: &value}}}})
	if r.Type != "query.result" || len(r.Rows) != 1 || r.SQLiteValues[0][2].Type != "blob" {
		t.Fatal("typed filtered browse failed")
	}
	str := func(s string) *string { return &s }
	request := &protocol.ChangesRequest{Schema: "main", Table: "t", Columns: []protocol.SnapshotColumn{{Name: "id", Engine: "sqlite", NativeType: "INTEGER"}, {Name: "v", Engine: "sqlite", NativeType: "TEXT"}, {Name: "b", Engine: "sqlite", NativeType: "BLOB"}}, Changes: []protocol.RowChange{{Kind: "update", Original: []protocol.CellValue{{Kind: "sqliteInteger", Value: str("1")}, {Kind: "sqliteText", Value: str(base64.StdEncoding.EncodeToString([]byte("one")))}, {Kind: "sqliteBlob", Value: str("/w==")}}, Values: []protocol.ColumnAssignment{{Column: "v", Value: protocol.CellValue{Kind: "text", Value: str("changed")}}}}}}
	r = s.Execute(context.Background(), protocol.Command{Type: "changes.preview", Changes: request})
	if r.Type != "query.result" || !strings.Contains(r.SQL, "UPDATE") {
		t.Fatal("preview did not produce SQL")
	}
	r = s.Execute(context.Background(), protocol.Command{Type: "changes.apply", Changes: request})
	if r.Type != "query.result" || r.AppliedChangeCount == nil || *r.AppliedChangeCount != 1 {
		t.Fatal("apply failed")
	}
	r = s.Execute(context.Background(), protocol.Command{Type: "changes.apply", Changes: request})
	if r.Type != "error" || r.Category != "conflict" {
		t.Fatal("stale original was applied")
	}
	if s.TransactionStatus() != "idle" {
		t.Fatal("conflict retained a transaction")
	}
	if r.TransactionStatus != "idle" {
		t.Fatal("conflict response reported stale transaction state")
	}
}

func TestBusyCancellationAndPrimaryKeyEligibility(t *testing.T) {
	s, path := openCore(t, false)
	for _, sql := range []string{"CREATE TABLE nullable(a INTEGER,b TEXT NOT NULL,PRIMARY KEY(a,b))", "CREATE TABLE descending(a INTEGER PRIMARY KEY DESC,v TEXT)", "CREATE TABLE stable(a INTEGER PRIMARY KEY,v TEXT)"} {
		runCore(t, s, sql)
	}
	for _, name := range []string{"nullable", "descending"} {
		cols, err := s.tableInfo(context.Background(), "main", name)
		if err != nil {
			t.Fatal(err)
		}
		if s.editableTable(context.Background(), name, cols) {
			t.Fatal("nullable primary key enabled editing")
		}
	}
	runCore(t, s, "BEGIN IMMEDIATE")
	other, err := Open(context.Background(), protocol.Connection{Engine: "sqlite", SQLite: &protocol.SQLiteSettings{Path: path}})
	if err != nil {
		t.Fatal(err)
	}
	defer other.Close()
	ctx, cancel := context.WithTimeout(context.Background(), 20*time.Millisecond)
	defer cancel()
	start := time.Now()
	r := other.Execute(ctx, protocol.Command{Type: "execute", SQL: "INSERT INTO stable VALUES(1,'blocked')"})
	if r.Type != "error" || r.Category != "timeout" {
		t.Fatal("busy writer ignored cancellation")
	}
	if time.Since(start) > time.Second {
		t.Fatal("busy cancellation did not return promptly")
	}
	runCore(t, s, "ROLLBACK")
}

func TestNamedParametersAndVacuum(t *testing.T) {
	s, _ := openCore(t, false)
	date, decimal := "2026-11-04", "12345678901234567890.123456789"
	r := s.Execute(context.Background(), protocol.Command{Type: "execute", SQL: "SELECT :date,:decimal,:date", Parameters: []protocol.QueryParameter{{Name: "date", Type: "date", Value: &date}, {Name: "decimal", Type: "decimal", Value: &decimal}}})
	if r.Type != "query.result" || len(r.SQLiteValues) != 1 || text(r.SQLiteValues[0][0]) != date || text(r.SQLiteValues[0][1]) != decimal || text(r.SQLiteValues[0][2]) != date {
		t.Fatal("named SQLite parameters were coerced")
	}
	runCore(t, s, "CREATE TABLE t(id INTEGER PRIMARY KEY)")
	runCore(t, s, "BEGIN")
	runCore(t, s, "INSERT INTO t VALUES(1)")
	if r = runCore(t, s, "COMMIT"); r.RowCount != 0 {
		t.Fatal("COMMIT reported stale affected rows")
	}
	runCore(t, s, "VACUUM")
}
