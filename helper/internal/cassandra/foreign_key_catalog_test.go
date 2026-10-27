package cassandra

import (
	"context"
	"testing"

	"dbeer/helper/internal/protocol"
)

func TestForeignKeyCatalogIsExplicitlyUnsupportedWithoutDriverAccess(t *testing.T) {
	s := &Session{}
	command := protocol.Command{Type: "catalog", RequestID: "foreign-keys", SessionID: "session", QueryID: "query",
		Catalog: &protocol.CatalogRequest{Kind: "foreignKeys", Schema: "demo", Object: "events", ObjectKind: "table"}}
	response := s.catalog(context.Background(), command, nil)
	if response.Type != "error" || response.Category != "unsupported" || response.Message != "Cassandra does not support foreign keys." || response.RequestID != command.RequestID || response.SessionID != command.SessionID || response.QueryID != command.QueryID {
		t.Fatal("foreign key catalog support must be explicit and retain request correlation")
	}
}
