package cassandra

import (
	"context"
	"errors"
	"reflect"
	"testing"

	"dbeer/helper/internal/protocol"
)

func TestCassandraBrowseANDTreePreservesKeyAndSortValidation(t *testing.T) {
	columns := []tableColumn{{name: "tenant", nativeType: "text", kind: "partition_key"}, {name: "created", nativeType: "bigint", kind: "clustering", order: "desc"}}
	filters := []protocol.CatalogFilter{{Column: "tenant", Operator: "eq", Value: ptr("exact' value")}, {Column: "created", Operator: "gte", Value: ptr("9007199254740993")}}
	leaf := func(filter protocol.CatalogFilter) protocol.CatalogFilterExpression {
		return protocol.CatalogFilterExpression{Kind: "condition", Condition: &filter}
	}
	tree := protocol.CatalogFilterExpression{Kind: "and", Children: []protocol.CatalogFilterExpression{leaf(filters[0]), {Kind: "and", Children: []protocol.CatalogFilterExpression{leaf(filters[1])}}}}
	legacy := protocol.CatalogRequest{Schema: "ks", Object: "records", Filters: filters, Sort: []protocol.CatalogSort{{Column: "created", Direction: "asc"}}}
	request := legacy
	request.Filters = nil
	request.FilterExpression = &tree
	for _, source := range []bool{false, true} {
		want, expected, err := buildBrowseStatement(legacy, columns, source)
		if err != nil {
			t.Fatal(err)
		}
		got, values, err := buildBrowseStatement(request, columns, source)
		if err != nil || got != want || !reflect.DeepEqual(values, expected) {
			t.Fatal("AND tree changed Cassandra key semantics")
		}
	}
	tree.Kind = "or"
	if _, _, err := browseStatement(request, columns); !errors.Is(err, errBrowse) {
		t.Fatal("OR accepted by Cassandra builder")
	}
	// A zero-value Session has no connection. Rejecting here demonstrates that
	// OR never reaches even the metadata query path.
	session := &Session{}
	response := session.browse(context.Background(), protocol.Command{Type: "catalog", Catalog: &request}, nil)
	if response.Category != "unsupported" {
		t.Fatal("OR reached Cassandra connection")
	}
	request.Filters = filters
	if _, _, err := browseStatement(request, columns); !errors.Is(err, errBrowse) {
		t.Fatal("mixed filter representations accepted")
	}
}
