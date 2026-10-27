package cassandra

import (
	"context"
	"testing"

	"dbeer/helper/internal/protocol"
)

func TestCassandraPostgresTypeOperationsAreUnsupportedBeforeDriverAccess(t *testing.T) {
	s := &Session{}
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
		response := s.catalog(context.Background(), command, nil)
		if response.Type != "error" || response.Category != "unsupported" || response.RequestID != command.RequestID {
			t.Fatal("PostgreSQL type operation reached the Cassandra driver or returned an empty success")
		}
	}
	// Existing Cassandra UDT Copy Name does not require PostgreSQL identity or
	// the driver, and must remain available after the PG-only guard is added.
	udt := protocol.CatalogRequest{Kind: "name", Schema: "demo", Object: "address", ObjectKind: "type"}
	response := s.catalog(context.Background(), protocol.Command{Type: "catalog", RequestID: "udt-name", Catalog: &udt}, nil)
	if response.Type != "query.result" || len(response.Rows) != 1 || response.Rows[0][0] == nil {
		t.Fatal("PostgreSQL-only rejection broke existing Cassandra UDT inspection")
	}
}
