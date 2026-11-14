package schemabundle_test

import (
	"context"
	"encoding/base64"
	"path/filepath"
	"reflect"
	"strings"
	"testing"

	"dbeer/helper/internal/adapter"
	"dbeer/helper/internal/protocol"
	"dbeer/helper/internal/schemabundle"
	sc "dbeer/helper/internal/schemacompare"
	sqlitedb "dbeer/helper/internal/sqlite"
)

func TestSQLiteLiveCaptureIncludesExactDefinitionsAndIgnoresRowsAndCounters(t *testing.T) {
	ctx := context.Background()
	path := filepath.Join(t.TempDir(), "source.sqlite")
	if err := sqlitedb.Create(ctx, path); err != nil {
		t.Fatal(err)
	}
	settings := protocol.Connection{Engine: "sqlite", SQLite: &protocol.SQLiteSettings{Path: path}, SSLMode: "disable"}
	source, err := sqlitedb.Open(ctx, settings)
	if err != nil {
		t.Fatal(err)
	}
	defer source.Close()
	execute := func(sql string) {
		t.Helper()
		reply := source.Execute(ctx, protocol.Command{Type: "execute", SessionID: "fixture", QueryID: "fixture", RequestID: "fixture", SQL: sql})
		if reply.Type != "query.result" {
			t.Fatal("SQLite fixture command failed")
		}
	}
	execute(`CREATE TABLE "Exact_é" (id INTEGER PRIMARY KEY AUTOINCREMENT, amount INTEGER DEFAULT 9007199254740993, note TEXT COLLATE NOCASE)`)
	execute(`CREATE INDEX "Exact_index" ON "Exact_é" (note)`)
	execute(`CREATE TRIGGER "Exact_trigger" AFTER INSERT ON "Exact_é" BEGIN UPDATE "Exact_é" SET note=coalesce(new.note,'exact') WHERE id=new.id; END;`)
	snapshots := []map[string][]byte{}
	for i := 0; i < 2; i++ {
		session, err := sqlitedb.Open(ctx, settings)
		if err != nil {
			t.Fatal(err)
		}
		if err = session.(adapter.ReadOnlySession).SetReadOnly(ctx, true); err != nil {
			session.Close()
			t.Fatal(err)
		}
		collector := sc.NewCollector(ctx, sc.DefaultLimits())
		err = session.(adapter.SchemaReader).ReadSchema(ctx, sc.CaptureSpec{Schemas: []string{"main"}, Limits: sc.DefaultLimits()}, collector)
		session.Close()
		if err != nil {
			t.Fatal(err)
		}
		result, err := schemabundle.Build(ctx, t.TempDir(), collector.Capture, []string{"main"}, sqlitedb.RenderSchemaDefinition)
		if err != nil {
			t.Fatal(err)
		}
		if result.Summary.Included != 1 {
			t.Fatal("ordinary SQLite table was omitted")
		}
		files := map[string][]byte{}
		descriptions := []schemabundle.File{result.Summary.Manifest, result.Manifest.Capture}
		for _, o := range result.Manifest.Objects {
			descriptions = append(descriptions, o.File)
		}
		for _, file := range descriptions {
			var b []byte
			for offset := int64(0); ; {
				chunk, err := result.Chunk(ctx, file.ID, offset, 17)
				if err != nil {
					t.Fatal(err)
				}
				part, err := base64.StdEncoding.DecodeString(chunk.DataBase64)
				if err != nil {
					t.Fatal(err)
				}
				b = append(b, part...)
				offset = chunk.NextOffset
				if !chunk.HasMore {
					break
				}
			}
			files[file.Path] = b
		}
		for _, o := range result.Manifest.Objects {
			if o.Ref.Kind == "table" {
				ddl := string(files[o.File.Path])
				if o.State != "included" || !strings.Contains(ddl, `CREATE TABLE "Exact_é"`) || !strings.Contains(ddl, "CREATE INDEX") || !strings.Contains(ddl, "CREATE TRIGGER") {
					t.Fatal("SQLite exact definitions missing")
				}
				for _, dependency := range o.Dependencies {
					if dependency.Ref.Kind == "type" && dependency.State != "builtin" {
						t.Fatal("SQLite builtin type treated as user dependency")
					}
				}
			}
		}
		_ = result.Close()
		snapshots = append(snapshots, files)
		execute(`INSERT INTO "Exact_é"(note) VALUES ('row data is outside the schema')`)
	}
	if !reflect.DeepEqual(snapshots[0], snapshots[1]) {
		t.Fatal("SQLite rows or changing sequence counter entered portable files")
	}
}
