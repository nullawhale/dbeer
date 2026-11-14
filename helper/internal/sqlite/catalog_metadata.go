package sqlite

import (
	"context"
	"dbeer/helper/internal/adapter"
	"dbeer/helper/internal/protocol"
)

func (s *Session) ReadCatalogMetadata(ctx context.Context, c protocol.Command, sink adapter.ResultSink) (protocol.Response, string) {
	if s.TransactionStatus() != "idle" {
		r := protocol.ErrorResponse(c, "busy", "Metadata capture requires an idle service session.")
		r.Connected, r.TransactionStatus = true, s.TransactionStatus()
		return r, "schemaVersion"
	}
	if err := s.checkIdentity(); err != nil {
		return s.fail(c, ctx, err), "schemaVersion"
	}
	before, _, err := s.query(ctx, "PRAGMA main.schema_version")
	if err != nil {
		return s.fail(c, ctx, err), "schemaVersion"
	}
	s.metadataCapture = true
	defer func() { s.metadataCapture = false }()
	r := s.catalog(ctx, c, sink)
	if c.Catalog.Kind == "referencingTables" && r.Type != "error" {
		objects, _, e := s.query(ctx, "SELECT name FROM main.sqlite_schema WHERE type='table' AND name=? COLLATE NOCASE", c.Catalog.Object)
		if e != nil {
			return s.fail(c, ctx, e), "schemaVersion"
		}
		if len(objects) == 1 {
			r.MetadataTarget = &protocol.CatalogRelationTarget{Schema: "main", Name: text(objects[0][0])}
		}
	}
	after, _, err := s.query(ctx, "PRAGMA main.schema_version")
	if err != nil {
		return s.fail(c, ctx, err), "schemaVersion"
	}
	if len(before) != 1 || len(after) != 1 || len(before[0]) != 1 || len(after[0]) != 1 || before[0][0] != after[0][0] {
		r.DisplayNotice = "The SQLite schema changed during metadata capture. Refresh explicitly."
		r.MetadataStale = true
	}
	return r, "schemaVersion"
}
