package mongodb

import "testing"

func TestSampledColumnTypesKeepObservedUnionAndNestedPath(t *testing.T) {
	got := sampledColumnTypes(map[string]map[string]bool{"amount": {"decimal128": true, "int64": true}, "author.name": {"string": true}})
	if got["amount"] != "decimal128 | int64" || got["author.name"] != "string" {
		t.Fatal("sampled types lost deterministic union or nested path")
	}
	if len(sampledColumnTypes(nil)) != 0 {
		t.Fatal("missing sample must not invent types")
	}
}
