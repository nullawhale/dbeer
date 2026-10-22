package mysql

import (
	"context"
	"testing"

	"dbeer/helper/internal/protocol"
)

func TestMySQLPostgresTypeOperationsAreUnsupportedBeforeDriverAccess(t *testing.T) {
	s := &Session{}
	s.transaction.Store("idle")
	for _, kind := range []string{"typeDetails", "enumValues", "typeDependencies", "typeDDL", "definition", "name", "objects"} {
		request := protocol.CatalogRequest{Kind: kind, Schema: "public", Object: "status", ObjectKind: "enum", Identity: "1234"}
		if kind == "objects" {
			request.Object, request.Identity = "", ""
		}
		if kind == "typeDDL" {
			v := ""
			request.TypeChange = &protocol.TypeChange{Operation: "addEnumValue", Value: &v}
		}
		command := protocol.Command{Type: "catalog", RequestID: kind, SessionID: "session", QueryID: "query", Catalog: &request}
		response := s.catalog(context.Background(), command)
		if response.Type != "error" || response.Category != "unsupported" || response.RequestID != command.RequestID || !response.Connected {
			t.Fatal("PostgreSQL type operation reached the MySQL driver or returned an empty success")
		}
	}
}
