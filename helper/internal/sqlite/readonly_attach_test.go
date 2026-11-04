package sqlite

import (
	"context"
	"os"
	"path/filepath"
	"strings"
	"testing"

	"dbeer/helper/internal/protocol"
)

func TestSQLiteReadonlyAttachmentsEnforcePhysicalReadMode(t *testing.T) {
	s, main := openCore(t, false)
	runCore(t, s, "CREATE TABLE seed(id INTEGER PRIMARY KEY)")
	ctx := context.Background()
	ro, err := Open(ctx, protocol.Connection{Engine: "sqlite", SQLite: &protocol.SQLiteSettings{Path: main}, Policy: &protocol.ExecutionPolicy{ReadOnly: true}})
	if err != nil {
		t.Fatal(err)
	}
	defer ro.Close()
	extra := filepath.Join(t.TempDir(), "extra '?%.sqlite")
	if err = Create(ctx, extra); err != nil {
		t.Fatal(err)
	}
	other, err := Open(ctx, protocol.Connection{Engine: "sqlite", SQLite: &protocol.SQLiteSettings{Path: extra}})
	if err != nil {
		t.Fatal(err)
	}
	for _, sql := range []string{"CREATE TABLE values_table(id INTEGER PRIMARY KEY)", "INSERT INTO values_table VALUES(7)"} {
		if r := other.Execute(ctx, protocol.Command{Type: "execute", SQL: sql}); r.Type != "query.result" {
			t.Fatal("fixture failed")
		}
	}
	other.Close()
	fileBefore, err := os.ReadFile(extra)
	if err != nil {
		t.Fatal(err)
	}
	attach := "ATTACH DATABASE '" + strings.ReplaceAll(extra, "'", "''") + "' AS extra"
	physical := ro.(*Session)
	if !physical.IsReadOnlyOperation(protocol.OperationRequest{Type: "execute", SQL: attach}) {
		t.Fatal("safe attachment not assessed readonly")
	}
	for _, sql := range []string{attach, "SELECT id FROM extra.values_table"} {
		if r := ro.Execute(ctx, protocol.Command{Type: "execute", SQL: sql}); r.Type != "query.result" {
			t.Fatal("readonly attachment failed")
		}
	}
	for _, sql := range []string{"INSERT INTO extra.values_table VALUES(8)", "DROP TABLE extra.values_table", "PRAGMA extra.query_only=OFF", "PRAGMA extra.journal_mode=WAL"} {
		if r := ro.Execute(ctx, protocol.Command{Type: "execute", SQL: sql}); r.Type != "error" {
			t.Fatal("readonly attachment allowed mutation")
		}
	}
	if r := ro.Execute(ctx, protocol.Command{Type: "execute", SQL: "DETACH extra"}); r.Type != "query.result" {
		t.Fatal("readonly detach failed")
	}
	fileAfter, err := os.ReadFile(extra)
	if err != nil || string(fileBefore) != string(fileAfter) {
		t.Fatal("attached file bytes changed")
	}
	missing := filepath.Join(t.TempDir(), "missing.sqlite")
	if r := ro.Execute(ctx, protocol.Command{Type: "execute", SQL: "ATTACH '" + missing + "' AS missing"}); r.Type != "error" {
		t.Fatal("missing file attached")
	}
	if _, err = os.Stat(missing); !os.IsNotExist(err) {
		t.Fatal("readonly attachment created a file")
	}
	for _, sql := range []string{attach + "; DELETE FROM seed", "ATTACH ':memory:' AS extra", "ATTACH 'file:" + main + "?mode=rw' AS extra", "ATTACH ? AS extra", "DETACH extra; DELETE FROM seed"} {
		if physical.IsReadOnlyOperation(protocol.OperationRequest{Type: "execute", SQL: sql}) {
			t.Fatal("unsafe attachment assessed readonly")
		}
	}
}
