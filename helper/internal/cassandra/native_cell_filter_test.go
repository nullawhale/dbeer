package cassandra

import (
	"context"
	"errors"
	"testing"

	"dbeer/helper/internal/protocol"
)

func TestCassandraNativeCellFilterFailsBeforeConnection(t *testing.T) {
	value := "1"
	filter := protocol.CatalogFilter{Column: "id", Operator: "eq", NativeValue: &protocol.NativeCellFilterValue{Cell: protocol.CellValue{Kind: "text", Value: &value}, SourceEngine: "postgresql", SourceType: "int8", SQLiteStorage: "integer"}}
	request := protocol.CatalogRequest{Schema: "ks", Object: "items", Filters: []protocol.CatalogFilter{filter}}
	columns := []tableColumn{{name: "id", nativeType: "bigint", kind: "partition_key"}}
	for _, tree := range []bool{false, true} {
		if tree {
			request.Filters = nil
			request.FilterExpression = &protocol.CatalogFilterExpression{Kind: "or", Children: []protocol.CatalogFilterExpression{{Kind: "condition", Condition: &filter}}}
		}
		if _, _, err := browseStatement(request, columns); !errors.Is(err, errNativeBrowse) {
			t.Fatal("native operand used legacy Cassandra semantics")
		}
		session := &Session{}
		response := session.browse(context.Background(), protocol.Command{Type: "catalog", Catalog: &request}, nil)
		if response.Category != "unsupported" || response.Message != errNativeBrowse.Error() {
			t.Fatal("native operand reached Cassandra connection")
		}
	}
}
