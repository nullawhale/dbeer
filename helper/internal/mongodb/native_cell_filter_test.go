package mongodb

import (
	"context"
	"errors"
	"testing"

	"dbeer/helper/internal/protocol"
)

func TestMongoDBNativeCellFilterFailsBeforeConnection(t *testing.T) {
	value := "NULL"
	filter := protocol.CatalogFilter{Column: "v", Operator: "eq", NativeValue: &protocol.NativeCellFilterValue{Cell: protocol.CellValue{Kind: "text", Value: &value}, SourceEngine: "postgresql", SourceType: "text", SQLiteStorage: "text"}}
	request := protocol.CatalogRequest{Schema: "demo", Object: "items", Filters: []protocol.CatalogFilter{filter}}
	for _, tree := range []bool{false, true} {
		if tree {
			request.Filters = nil
			request.FilterExpression = &protocol.CatalogFilterExpression{Kind: "or", Children: []protocol.CatalogFilterExpression{{Kind: "condition", Condition: &filter}}}
		}
		if _, err := browseScript(request); !errors.Is(err, errNativeCellFilter) {
			t.Fatal("native operand used legacy MongoDB semantics")
		}
		session := &Session{}
		response := session.browse(context.Background(), protocol.Command{Type: "catalog", Catalog: &request}, nil)
		if response.Category != "unsupported" || response.Message != errNativeCellFilter.Error() {
			t.Fatal("native operand reached MongoDB connection or reported legacy operand syntax")
		}
	}
}
