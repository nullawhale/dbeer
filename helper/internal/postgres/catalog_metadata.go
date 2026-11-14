package postgres

import (
	"context"
	"dbeer/helper/internal/adapter"
	"dbeer/helper/internal/protocol"
	"github.com/jackc/pgx/v5"
	"time"
)

func (s *Session) ReadCatalogMetadata(ctx context.Context, c protocol.Command, sink adapter.ResultSink) (protocol.Response, string) {
	if s.TransactionStatus() != "idle" {
		r := protocol.ErrorResponse(c, "busy", "Metadata capture requires an idle service session.")
		r.Connected, r.TransactionStatus = true, s.TransactionStatus()
		return r, "repeatableRead"
	}
	tx, err := s.conn.BeginTx(ctx, pgx.TxOptions{IsoLevel: pgx.RepeatableRead, AccessMode: pgx.ReadOnly})
	if err != nil {
		return connectionError(c, err), "repeatableRead"
	}
	defer func() {
		cleanup, cancel := context.WithTimeout(context.Background(), time.Second)
		defer cancel()
		_ = tx.Rollback(cleanup)
	}()
	r := catalogWithSink(ctx, s.conn, c, sink)
	// The metadata sink receives every row before the ordinary display limit.
	if r.Truncated && r.DisplayNotice == "Result display is limited to 1000 rows and 8 MiB. The command completed in full." {
		r.DisplayNotice = ""
	}
	// catalogAccess already proved this exact object's visibility and existence.
	// An empty supported collection is a complete empty observation.
	if c.Catalog.Object != "" && r.DisplayNotice == "No catalog information is available for this object." {
		r.DisplayNotice = ""
	}
	if err := tx.Rollback(ctx); err != nil {
		return connectionError(c, err), "repeatableRead"
	}
	r.TransactionStatus = s.TransactionStatus()
	if c.Catalog.Kind == "referencingTables" && r.Type != "error" && !r.MetadataStale {
		r.MetadataTarget = &protocol.CatalogRelationTarget{Schema: c.Catalog.Schema, Name: c.Catalog.Object}
	}
	return r, "repeatableRead"
}
