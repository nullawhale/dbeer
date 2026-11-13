package mysql

import (
	"context"
	"fmt"
	"strings"
	"testing"
	"time"

	"dbeer/helper/internal/adapter"
	"dbeer/helper/internal/catalogmetadata"
	"dbeer/helper/internal/protocol"
)

func TestMySQLMetadataPagesColumnsForeignKeysAndVisibility(t *testing.T) {
	s := integrationSession(t)
	prefix := fmt.Sprintf("metadata_%d_", time.Now().UnixNano())
	wide, target, source := prefix+"wide", prefix+"target", prefix+"source"
	quote := func(value string) string { return "`" + strings.ReplaceAll(value, "`", "``") + "`" }
	t.Cleanup(func() {
		for _, name := range []string{source, target, wide} {
			s.Execute(context.Background(), protocol.Command{SQL: "DROP TABLE IF EXISTS " + quote(name)})
		}
	})
	columns := make([]string, 1005)
	for i := range columns {
		columns[i] = fmt.Sprintf("column_%04d INT", i)
	}
	run(t, s, "CREATE TABLE "+quote(wide)+"("+strings.Join(columns, ",")+") ENGINE=InnoDB")
	key := make([]string, 16)
	fields := make([]string, 16)
	for i := range key {
		key[i] = fmt.Sprintf("k%d", i)
		fields[i] = key[i] + " INT"
	}
	keyList := strings.Join(key, ",")
	run(t, s, "CREATE TABLE "+quote(target)+"("+strings.Join(fields, ",")+",PRIMARY KEY("+keyList+")) ENGINE=InnoDB")
	constraints := make([]string, 63)
	for i := range constraints {
		constraints[i] = fmt.Sprintf("CONSTRAINT %s FOREIGN KEY(%s) REFERENCES %s(%s)", quote(fmt.Sprintf("%sfk_%02d", prefix, i)), keyList, quote(target), keyList)
	}
	run(t, s, "CREATE TABLE "+quote(source)+"("+strings.Join(fields, ",")+","+strings.Join(constraints, ",")+") ENGINE=InnoDB")
	var store catalogmetadata.Store
	defer store.Close()
	database := integrationSettings(t).Database
	for _, test := range []struct {
		selector protocol.CatalogRequest
		count    int
	}{
		{protocol.CatalogRequest{Kind: "columns", Schema: database, Object: wide, ObjectKind: "table"}, 1005},
		{protocol.CatalogRequest{Kind: "foreignKeys", Schema: database, Object: source, ObjectKind: "table"}, 1008},
	} {
		c := protocol.Command{Type: "catalog.page", CatalogMetadata: &protocol.CatalogMetadataRequest{Selectors: []protocol.CatalogRequest{test.selector}}}
		count := 0
		capture := ""
		for {
			r, err := store.Execute(context.Background(), s, c)
			if err != nil || !r.Valid() {
				t.Fatalf("invalid MySQL metadata: %v", err)
			}
			page := r.Collections[0]
			if page.State != "complete" || page.Consistency != "bestEffort" {
				t.Fatalf("incomplete MySQL metadata: %s", page.Issue)
			}
			if test.selector.Kind == "foreignKeys" && len(page.Rows)%16 != 0 {
				t.Fatal("FK split across pages")
			}
			count += len(page.Rows)
			c.CatalogMetadata.Cursor = page.NextCursor
			capture = page.CaptureID
			if page.NextCursor == "" {
				break
			}
		}
		if count != test.count {
			t.Fatalf("%s captured %d, expected %d", test.selector.Kind, count, test.count)
		}
		store.Execute(context.Background(), s, protocol.Command{Type: "catalog.close", CatalogMetadata: &protocol.CatalogMetadataRequest{CaptureIDs: []string{capture}}})
	}
	denied, err := store.Execute(context.Background(), s, protocol.Command{Type: "catalog.page", CatalogMetadata: &protocol.CatalogMetadataRequest{Selectors: []protocol.CatalogRequest{{Kind: "columns", Schema: "mysql", Object: "user", ObjectKind: "table"}}}})
	if err != nil || denied.Collections[0].State != "unavailable" {
		t.Fatal("denied system metadata became a complete empty collection")
	}
	run(t, s, "SET SESSION group_concat_max_len=4")
	warnings, err := store.Execute(context.Background(), s, protocol.Command{Type: "catalog.page", CatalogMetadata: &protocol.CatalogMetadataRequest{Selectors: []protocol.CatalogRequest{{Kind: "indexes", Schema: database, Object: source, ObjectKind: "table"}}}})
	if err != nil || warnings.Collections[0].State != "partial" || !strings.Contains(warnings.Collections[0].Issue, "warning") {
		t.Fatal("truncated GROUP_CONCAT metadata was reported complete")
	}
	run(t, s, "SET SESSION group_concat_max_len=1024")
	observer := integrationSession(t)
	sink := &metadataMutationSink{after: func() { run(t, observer, "ALTER TABLE "+quote(wide)+" ADD COLUMN changed INT") }}
	r, _ := s.ReadCatalogMetadata(context.Background(), protocol.Command{Type: "catalog", Catalog: &protocol.CatalogRequest{Kind: "columns", Schema: database, Object: wide, ObjectKind: "table"}}, sink)
	if r.Type != "query.result" || !r.MetadataStale {
		t.Fatal("metadata recheck missed concurrent schema change")
	}
}

type metadataMutationSink struct{ after func() }

func (s *metadataMutationSink) Begin(int, []protocol.Column) error { return nil }
func (s *metadataMutationSink) Row(int, []*string) error           { return nil }
func (s *metadataMutationSink) End(int, protocol.ResultSet) error  { s.after(); return nil }

var _ adapter.ResultSink = (*metadataMutationSink)(nil)
