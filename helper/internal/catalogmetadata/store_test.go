package catalogmetadata

import (
	"context"
	"fmt"
	"os"
	"testing"
	"time"

	"dbeer/helper/internal/adapter"
	"dbeer/helper/internal/protocol"
)

type readerFunc func(context.Context, protocol.Command, adapter.ResultSink) (protocol.Response, string)

func (f readerFunc) ReadCatalogMetadata(ctx context.Context, c protocol.Command, s adapter.ResultSink) (protocol.Response, string) {
	return f(ctx, c, s)
}
func pointer(value string) *string { return &value }
func request(selector protocol.CatalogRequest) protocol.Command {
	return protocol.Command{Type: "catalog.page", CatalogMetadata: &protocol.CatalogMetadataRequest{Selectors: []protocol.CatalogRequest{selector}, PageSize: 200}}
}
func objects(count int) readerFunc {
	return func(ctx context.Context, c protocol.Command, sink adapter.ResultSink) (protocol.Response, string) {
		columns := []protocol.Column{{Index: 0, Name: "name"}}
		if err := sink.Begin(0, columns); err != nil {
			return protocol.ErrorResponse(c, "cancelled", "Cancelled"), "bestEffort"
		}
		for i := 0; i < count; i++ {
			if err := sink.Row(0, []*string{pointer(fmt.Sprint(i))}); err != nil {
				return protocol.ErrorResponse(c, "cancelled", "Cancelled"), "bestEffort"
			}
		}
		_ = sink.End(0, protocol.ResultSet{})
		return protocol.Response{Type: "query.result", Connected: true}, "bestEffort"
	}
}
func TestPagesRetainFullObservationAndOwnCursors(t *testing.T) {
	var store Store
	defer store.Close()
	c := request(protocol.CatalogRequest{Kind: "schemas"})
	reply, err := store.Execute(context.Background(), objects(1205), c)
	if err != nil || !reply.Valid() {
		t.Fatalf("first page invalid: %v", err)
	}
	first := reply.Collections[0]
	count := len(first.Rows)
	var other Store
	defer other.Close()
	continuation := c
	continuation.CatalogMetadata = &protocol.CatalogMetadataRequest{Selectors: c.CatalogMetadata.Selectors, Cursor: first.NextCursor}
	if _, err := other.Execute(context.Background(), objects(0), continuation); err == nil {
		t.Fatal("cursor crossed session store")
	}
	changed := continuation
	changed.CatalogMetadata = &protocol.CatalogMetadataRequest{Selectors: []protocol.CatalogRequest{{Kind: "objects", Schema: "public", ObjectKind: "table"}}, Cursor: first.NextCursor}
	if _, err := store.Execute(context.Background(), objects(0), changed); err == nil {
		t.Fatal("cursor changed selector")
	}
	for next := first.NextCursor; next != ""; {
		c.CatalogMetadata.Cursor = next
		r, err := store.Execute(context.Background(), objects(0), c)
		if err != nil {
			t.Fatal(err)
		}
		count += len(r.Collections[0].Rows)
		next = r.Collections[0].NextCursor
	}
	if count != 1205 {
		t.Fatalf("captured %d of 1205", count)
	}
	file := store.captures[first.CaptureID].file.Name()
	close := protocol.Command{Type: "catalog.close", CatalogMetadata: &protocol.CatalogMetadataRequest{CaptureIDs: []string{first.CaptureID}}}
	if _, err := store.Execute(context.Background(), objects(0), close); err != nil {
		t.Fatal(err)
	}
	if _, err := os.Stat(file); !os.IsNotExist(err) {
		t.Fatal("capture file retained after close")
	}
	if _, err := store.Execute(context.Background(), objects(0), continuation); err == nil {
		t.Fatal("closed cursor survived")
	}
}
func TestCompositeForeignKeysAreAtomicAcrossPages(t *testing.T) {
	var store Store
	defer store.Close()
	reader := readerFunc(func(ctx context.Context, c protocol.Command, s adapter.ResultSink) (protocol.Response, string) {
		columns := []protocol.Column{}
		for i, name := range []string{"name", "targetSchema", "targetTable", "sourceColumn", "targetColumn", "position"} {
			columns = append(columns, protocol.Column{Index: i, Name: name})
		}
		s.Begin(0, columns)
		for key := 0; key < 501; key++ {
			for pair := 1; pair <= 3; pair++ {
				s.Row(0, []*string{pointer(fmt.Sprintf("fk%04d", key)), pointer("public"), pointer("target"), pointer(fmt.Sprint(pair)), pointer(fmt.Sprint(pair)), pointer(fmt.Sprint(pair))})
			}
		}
		s.End(0, protocol.ResultSet{})
		return protocol.Response{Type: "query.result", Connected: true}, "repeatableRead"
	})
	c := request(protocol.CatalogRequest{Kind: "foreignKeys", Schema: "public", Object: "source", ObjectKind: "table"})
	count := 0
	for {
		r, err := store.Execute(context.Background(), reader, c)
		if err != nil || !r.Valid() {
			t.Fatalf("invalid page: %v", err)
		}
		page := r.Collections[0]
		if len(page.Rows)%3 != 0 {
			t.Fatal("composite constraint split")
		}
		count += len(page.Rows)
		if page.NextCursor == "" {
			break
		}
		c.CatalogMetadata.Cursor = page.NextCursor
	}
	if count != 1503 {
		t.Fatalf("only captured %d FK rows", count)
	}
}
func TestBatchRetainsPerCollectionFailuresAndRejectsExpiredCursors(t *testing.T) {
	var store Store
	defer store.Close()
	reader := readerFunc(func(ctx context.Context, c protocol.Command, s adapter.ResultSink) (protocol.Response, string) {
		if c.Catalog.Schema == "denied" {
			r := protocol.ErrorResponse(c, "sql", "Denied")
			r.Connected = true
			return r, "bestEffort"
		}
		return objects(300)(ctx, c, s)
	})
	c := protocol.Command{Type: "catalog.batch", CatalogMetadata: &protocol.CatalogMetadataRequest{Selectors: []protocol.CatalogRequest{{Kind: "schemas"}, {Kind: "objects", Schema: "denied", ObjectKind: "table"}}}}
	r, err := store.Execute(context.Background(), reader, c)
	if err != nil || !r.Valid() {
		t.Fatalf("invalid batch: %v", err)
	}
	if r.Collections[0].State != "complete" || r.Collections[1].State != "unavailable" {
		t.Fatal("collection states collapsed")
	}
	first := r.Collections[0]
	store.captures[first.CaptureID].expires = time.Now().Add(-time.Second)
	page := request(first.Selector)
	page.CatalogMetadata.Cursor = first.NextCursor
	if _, err := store.Execute(context.Background(), reader, page); err == nil {
		t.Fatal("expired cursor accepted")
	}
}
func TestCancelledCaptureCleansAllFiles(t *testing.T) {
	var store Store
	defer store.Close()
	ctx, cancel := context.WithCancel(context.Background())
	reader := readerFunc(func(ctx context.Context, c protocol.Command, s adapter.ResultSink) (protocol.Response, string) {
		cancel()
		return objects(1)(ctx, c, s)
	})
	_, err := store.Execute(ctx, reader, request(protocol.CatalogRequest{Kind: "schemas"}))
	if err == nil || len(store.captures) != 0 {
		t.Fatal("cancelled capture was retained")
	}
}
