package sqlite

import (
	"context"
	"crypto/sha256"
	"errors"
	"os"
	"path/filepath"
	"reflect"
	"testing"
	"time"

	"dbeer/helper/internal/tableedit"
)

func digestColumns(names ...string) []tableedit.ObservedColumn {
	columns := make([]tableedit.ObservedColumn, len(names))
	for i, name := range names {
		columns[i] = tableedit.ObservedColumn{Name: name}
	}
	return columns
}

func TestSQLiteStructureDigestPreservesMultiplicityAndStorageClasses(t *testing.T) {
	s := toolSession(t)
	ctx := context.Background()
	toolExec(t, s, "CREATE TABLE first(v)")
	toolExec(t, s, "CREATE TABLE second(v)")
	toolExec(t, s, "INSERT INTO first VALUES(NULL),(1),(1),(1.0),('1'),(X'31'),(CAST(X'610062' AS TEXT)),(CAST(X'ff' AS TEXT))")
	toolExec(t, s, "INSERT INTO second SELECT v FROM first ORDER BY rowid DESC")
	parent := t.TempDir()
	read := func(table string) (string, int64) {
		t.Helper()
		digest, count, err := s.structureValueDigestAt(ctx, table, digestColumns("v"), parent, structureDigestQuotaBytes)
		if err != nil {
			t.Fatal(err)
		}
		entries, err := os.ReadDir(parent)
		if err != nil || len(entries) != 0 {
			t.Fatal("private verification workspace not removed", err)
		}
		return digest, count
	}
	a, ac := read("first")
	b, bc := read("second")
	if a != b || ac != 8 || bc != 8 {
		t.Fatal("row order changed exact multiset")
	}
	toolExec(t, s, "UPDATE second SET v='1' WHERE rowid=(SELECT min(rowid) FROM second WHERE typeof(v)='integer')")
	b, bc = read("second")
	if a == b || bc != 8 {
		t.Fatal("integer to text change was not detected")
	}
	toolExec(t, s, "DELETE FROM second WHERE rowid=(SELECT min(rowid) FROM second)")
	b, bc = read("second")
	if a == b || bc != 7 {
		t.Fatal("duplicate multiplicity change was not detected")
	}
}

func TestSQLiteStructureDigestExceedsLegacyCaptureWithoutRetainingRows(t *testing.T) {
	s := toolSession(t)
	ctx := context.Background()
	toolExec(t, s, "CREATE TABLE large(id INTEGER PRIMARY KEY,v BLOB)")
	// 131,073 rows exceed the old 100,001-row bound and contain over 32 MiB.
	toolExec(t, s, "WITH RECURSIVE seq(n) AS (VALUES(1) UNION ALL SELECT n+1 FROM seq WHERE n<131073) INSERT INTO large SELECT n,zeroblob(256) FROM seq")
	columns := digestColumns("id", "v")
	parent := t.TempDir()
	first, count, err := s.structureValueDigestAt(ctx, "large", columns, parent, structureDigestQuotaBytes)
	if err != nil || count != 131073 {
		t.Fatal("large verification failed", count, err)
	}
	toolExec(t, s, "CREATE TABLE copied(id INTEGER PRIMARY KEY,v BLOB)")
	toolExec(t, s, "INSERT INTO copied SELECT id,v FROM large ORDER BY id DESC")
	second, count, err := s.structureValueDigestAt(ctx, "copied", columns, parent, structureDigestQuotaBytes)
	if err != nil || first != second || count != 131073 {
		t.Fatal("large copied values differ", err)
	}
	toolExec(t, s, "UPDATE copied SET v=zeroblob(255) WHERE id=131073")
	changed, _, err := s.structureValueDigestAt(ctx, "copied", columns, parent, structureDigestQuotaBytes)
	if err != nil || changed == first {
		t.Fatal("large changed row escaped verification", err)
	}
	entries, err := os.ReadDir(parent)
	if err != nil || len(entries) != 0 {
		t.Fatal("large verification left temporary runs", err)
	}
}

func TestSQLiteStructureDigestStreamsSingleLargeCell(t *testing.T) {
	s := toolSession(t)
	toolExec(t, s, "CREATE TABLE largecell(v)")
	toolExec(t, s, "INSERT INTO largecell VALUES(zeroblob(20*1024*1024))")
	digest, count, err := s.structureValueDigestAt(context.Background(), "largecell", digestColumns("v"), t.TempDir(), structureDigestQuotaBytes)
	if err != nil || count != 1 || len(digest) != sha256.Size*2 {
		t.Fatal("large cell could not be verified", count, err)
	}
}

func TestSQLiteStructureDigestQuotaAndCancellationCleanWorkspace(t *testing.T) {
	s := toolSession(t)
	toolExec(t, s, "CREATE TABLE records(v)")
	toolExec(t, s, "INSERT INTO records VALUES(1),(1)")
	parent := t.TempDir()
	_, _, err := s.structureValueDigestAt(context.Background(), "records", digestColumns("v"), parent, sha256.Size)
	if !errors.Is(err, ErrStructureDigestQuota) {
		t.Fatal("workspace quota not enforced", err)
	}
	entries, _ := os.ReadDir(parent)
	if len(entries) != 0 {
		t.Fatal("quota failure left temporary data")
	}
	ctx, cancel := context.WithCancel(context.Background())
	cancel()
	_, _, err = s.structureValueDigestAt(ctx, "records", digestColumns("v"), parent, structureDigestQuotaBytes)
	if !errors.Is(err, context.Canceled) {
		t.Fatal("cancellation not preserved", err)
	}
	entries, _ = os.ReadDir(parent)
	if len(entries) != 0 {
		t.Fatal("cancellation left temporary data")
	}
	// Cancellation during an active scan also clears any completed run files.
	toolExec(t, s, "WITH RECURSIVE seq(n) AS (VALUES(1) UNION ALL SELECT n+1 FROM seq WHERE n<500000) INSERT INTO records SELECT n FROM seq")
	ctx, cancel = context.WithCancel(context.Background())
	stop := make(chan struct{})
	go func() {
		defer close(stop)
		deadline := time.Now().Add(5 * time.Second)
		for time.Now().Before(deadline) {
			dirs, _ := os.ReadDir(parent)
			if len(dirs) > 0 {
				files, _ := os.ReadDir(filepath.Join(parent, dirs[0].Name()))
				if len(files) > 0 {
					cancel()
					return
				}
			}
			time.Sleep(time.Millisecond)
		}
		cancel()
	}()
	_, _, err = s.structureValueDigestAt(ctx, "records", digestColumns("v"), parent, structureDigestQuotaBytes)
	cancel()
	<-stop
	if !errors.Is(err, context.Canceled) {
		t.Fatal("active scan was not cancelled", err)
	}
	entries, _ = os.ReadDir(parent)
	if len(entries) != 0 {
		t.Fatal("active cancellation left private files")
	}
	if _, _, err = s.query(context.Background(), "SELECT 1"); err != nil {
		t.Fatal("connection was not reusable after digest cancellation", err)
	}
}

func TestSQLiteStructureDigestMergeBoundsAndMultiplicity(t *testing.T) {
	root := t.TempDir()
	w := structureDigestWorkspace{dir: root, quota: 1 << 20}
	rows := [][sha256.Size]byte{sha256.Sum256([]byte("a")), sha256.Sum256([]byte("a")), sha256.Sum256([]byte("b"))}
	var runs []structureDigestRun
	for range structureDigestMergeWidth + 1 {
		run, err := w.writeRun(context.Background(), append([][sha256.Size]byte(nil), rows...))
		if err != nil {
			t.Fatal(err)
		}
		runs = append(runs, run)
	}
	merged, err := w.mergeRun(context.Background(), runs[:structureDigestMergeWidth])
	if err != nil {
		t.Fatal(err)
	}
	runs = append([]structureDigestRun{merged}, runs[structureDigestMergeWidth:]...)
	var first, second bytesForStructureDigest
	if err = mergeStructureDigests(context.Background(), runs, &first); err != nil {
		t.Fatal(err)
	}
	all := make([][sha256.Size]byte, 0, len(rows)*(structureDigestMergeWidth+1))
	for range structureDigestMergeWidth + 1 {
		all = append(all, rows...)
	}
	run, err := w.writeRun(context.Background(), all)
	if err != nil {
		t.Fatal(err)
	}
	if err = mergeStructureDigests(context.Background(), []structureDigestRun{run}, &second); err != nil {
		t.Fatal(err)
	}
	if !reflect.DeepEqual(first, second) || len(first) != len(all)*sha256.Size {
		t.Fatal("merge lost a record or changed ordering")
	}
}

type bytesForStructureDigest []byte

func (b *bytesForStructureDigest) Write(p []byte) (int, error) {
	*b = append(*b, p...)
	return len(p), nil
}
