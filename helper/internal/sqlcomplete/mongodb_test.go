package sqlcomplete

import (
	"strings"
	"testing"
)

func TestMongoDBCompletionUsesJSONCollectionsFieldsOperatorsAndTypes(t *testing.T) {
	c := Context{Engine: "mongodb", Catalog: []Relation{{Schema: "demo", Name: "orders", Kind: "table", Columns: []string{"_id", "price", "nested.name"}}}}
	for _, test := range []struct{ text, label, replacement string }{
		{`{"col`, "collection", `"collection": "collection"`},
		{`{"collection":"ord`, "orders", `"orders"`},
		{`{"collection":"orders","find":{"pri`, "price", `"price": null`},
		{`{"collection":"orders","find":{"price":{"$gt`, "$gt", `"$gt": 0`},
		{`{"collection":"orders","aggregate":[{"$ma`, "$match", `"$match": {}`},
		{`{"collection":"orders","find":{"_id":{"$oi`, "$oid", `"$oid": "507f1f77bcf86cd799439011"`},
		{`{"collection":"orders","find":{"price":{"$type":"dec`, "decimal", `"decimal"`},
	} {
		items := Complete(test.text, len(test.text), c)
		found := false
		for _, item := range items {
			if item.Label == test.label {
				found = item.InsertText == test.replacement && item.Start >= 0 && item.End == len(test.text)
			}
			if strings.EqualFold(item.Label, "SELECT") {
				t.Fatal("SQL leaked into MongoDB completion")
			}
		}
		if !found {
			t.Fatalf("missing or invalid JSON completion for %s", test.label)
		}
	}
	if len(Complete(`{"collection":"orders","find":{"name":"ordinary`, len(`{"collection":"orders","find":{"name":"ordinary`), c)) != 0 {
		t.Fatal("suggestions leaked into a literal value")
	}
	if Signatures("COUNT(", 6, c) != nil {
		t.Fatal("SQL signatures leaked into JSON")
	}
	if len(Diagnostics(`{"collection":"orders","find":{}}`, "mongodb")) != 0 || len(Diagnostics("db.orders.find({})", "mongodb")) == 0 {
		t.Fatal("MongoDB diagnostics ignored the editor contract")
	}
}
