package mongodb

import (
	"reflect"
	"testing"

	"dbeer/helper/internal/protocol"
	"go.mongodb.org/mongo-driver/v2/bson"
)

func TestMongoDBBrowseNestedFilterPreservesTypesNullAndMissing(t *testing.T) {
	exact, text := `{"$numberLong":"9007199254740993"}`, `".*literal"`
	leaf := func(column, operator string, value *string) protocol.CatalogFilterExpression {
		return protocol.CatalogFilterExpression{Kind: "condition", Condition: &protocol.CatalogFilter{Column: column, Operator: operator, Value: value}}
	}
	expression := protocol.CatalogFilterExpression{Kind: "and", Children: []protocol.CatalogFilterExpression{
		{Kind: "or", Children: []protocol.CatalogFilterExpression{leaf("nested.value", "gte", &exact), leaf("nullable", "isNull", nil)}},
		{Kind: "or", Children: []protocol.CatalogFilterExpression{leaf("nullable", "isNotNull", nil), leaf("label", "contains", &text)}},
	}}
	script, err := browseScript(protocol.CatalogRequest{Schema: "demo", Object: "items", FilterExpression: &expression,
		Sort: []protocol.CatalogSort{{Column: "label", Direction: "desc"}, {Column: "nested.value", Direction: "asc"}}})
	if err != nil {
		t.Fatal("valid nested BSON browse rejected")
	}
	want := bson.D{{Key: "$and", Value: bson.A{
		bson.D{{Key: "$or", Value: bson.A{
			bson.D{{Key: "nested.value", Value: bson.D{{Key: "$gte", Value: int64(9007199254740993)}}}},
			bson.D{{Key: "nullable", Value: bson.D{{Key: "$type", Value: 10}}}},
		}}},
		bson.D{{Key: "$or", Value: bson.A{
			bson.D{{Key: "nullable", Value: bson.D{{Key: "$exists", Value: true}, {Key: "$ne", Value: nil}}}},
			bson.D{{Key: "label", Value: bson.D{{Key: "$regex", Value: `\.\*literal`}}}},
		}}},
	}}}
	if !reflect.DeepEqual(script.Filter, want) || !reflect.DeepEqual(script.Sort, bson.D{{Key: "label", Value: int32(-1)}, {Key: "nested.value", Value: int32(1)}}) {
		t.Fatal("nested BSON changed grouping, exact type, null/missing distinction, literal matching, or sort")
	}
}

func TestMongoDBBrowseRejectsMalformedAndMixedFilterTrees(t *testing.T) {
	value := `"x"`
	valid := protocol.CatalogFilterExpression{Kind: "condition", Condition: &protocol.CatalogFilter{Column: "label", Operator: "eq", Value: &value}}
	for _, expression := range []protocol.CatalogFilterExpression{
		{Kind: "or"},
		{Kind: "condition"},
		{Kind: "condition", Condition: &protocol.CatalogFilter{Column: "$where", Operator: "eq", Value: &value}},
		{Kind: "and", Children: []protocol.CatalogFilterExpression{{Kind: "condition", Condition: &protocol.CatalogFilter{Column: "label", Operator: "isNull", Value: &value}}}},
	} {
		if _, err := browseScript(protocol.CatalogRequest{FilterExpression: &expression}); err == nil {
			t.Fatal("malformed or unsafe BSON tree filter accepted")
		}
	}
	if _, err := browseScript(protocol.CatalogRequest{Filters: []protocol.CatalogFilter{*valid.Condition}, FilterExpression: &valid}); err == nil {
		t.Fatal("ambiguous legacy and tree filters accepted")
	}
	if _, err := browseScript(protocol.CatalogRequest{Sort: []protocol.CatalogSort{{Column: "label", Direction: "asc"}, {Column: "label", Direction: "desc"}}}); err == nil {
		t.Fatal("duplicate BSON sort field accepted")
	}
}
