package cassandra

import (
	"encoding/json"
	"errors"
	"strings"
	"testing"

	"dbeer/helper/internal/sqlcomplete"
)

func TestCassandraRoutineCompletionPreservesOverloadsAndAggregateSignatures(t *testing.T) {
	collector := routineCollector{keyspace: "Mixed Keyspace"}
	if err := collector.add("calculate", []string{"decimal", "frozen<tuple<int, text>>"}, []string{"amount", "details"}, "decimal", false); err != nil {
		t.Fatal(err)
	}
	if err := collector.add("calculate", []string{"varint"}, []string{"large"}, "varint", false); err != nil {
		t.Fatal(err)
	}
	if err := collector.add("average", []string{"int", "double"}, nil, "double", true); err != nil {
		t.Fatal(err)
	}
	if len(collector.objects) != 2 || collector.objects[0].kind != "function" || collector.objects[0].keyspace != "Mixed Keyspace" || len(collector.objects[0].signatures) != 2 {
		t.Fatal("routine metadata lost the keyspace, function kind or overloads")
	}
	encoded, err := json.Marshal(collector.objects[0].signatures)
	if err != nil {
		t.Fatal(err)
	}
	var signatures []sqlcomplete.FunctionSignature
	if err := json.Unmarshal(encoded, &signatures); err != nil {
		t.Fatal(err)
	}
	text := `SELECT "Mixed Keyspace"."calculate"(1, `
	help := sqlcomplete.Signatures(text, len(text), sqlcomplete.Context{Engine: "cassandra", Keyspace: "Mixed Keyspace", Catalog: []sqlcomplete.Relation{{Schema: "Mixed Keyspace", Name: "calculate", Kind: "function", Signatures: signatures}}})
	if help == nil || len(help.Signatures) != 2 || help.Signatures[0].ActiveParameter != 1 || !strings.Contains(help.Signatures[0].Label, "details: frozen<tuple<int, text>>") || !strings.HasSuffix(help.Signatures[0].Label, "→ decimal") {
		t.Fatal("routine declarations could not round-trip into language signature help")
	}
	aggregate := collector.objects[1].signatures[0]
	if len(aggregate.Parameters) != 2 || aggregate.Parameters[0].Name != "arg1" || aggregate.Parameters[1].Name != "arg2" || aggregate.Parameters[1].Position != 2 || aggregate.ReturnType != "double" {
		t.Fatal("aggregate argument types were lost or nonexistent argument names were invented")
	}
}

func TestCassandraRoutineCompletionHasProtocolBounds(t *testing.T) {
	collector := routineCollector{keyspace: "work"}
	for range 40 {
		if err := collector.add("overloaded", nil, nil, "int", false); err != nil {
			t.Fatal(err)
		}
	}
	if len(collector.objects) != 1 || len(collector.objects[0].signatures) != 32 || collector.objects[0].signatures[0].Parameters == nil {
		t.Fatal("routine metadata exceeded the protocol overload bound or encoded null parameters")
	}
	for _, mutate := range []func(*routineCollector){
		func(c *routineCollector) { c.bytes = maxBytes },
		func(c *routineCollector) { c.rows = 16384 },
	} {
		bounded := routineCollector{keyspace: "work"}
		mutate(&bounded)
		if err := bounded.add("f", nil, nil, "int", false); !errors.Is(err, errRoutineMetadata) || len(bounded.objects) != 0 {
			t.Fatal("routine metadata was retained after its shared row/byte budget was exhausted")
		}
	}
}

func TestCassandraRoutineCompletionRejectsMalformedDeclarations(t *testing.T) {
	for _, declaration := range []struct {
		name, result string
		types, names []string
	}{
		{"", "int", nil, nil}, {"f", "", nil, nil}, {"f", "int", []string{"int"}, nil},
		{"f", "int", []string{""}, []string{"x"}}, {"f", "int", []string{"int"}, []string{""}},
		{"f\x00hidden", "int", nil, nil}, {"f", "int", []string{string([]byte{255})}, []string{"x"}},
		{"f", "int", make([]string, 257), make([]string, 257)},
		{strings.Repeat("f", 1025), "int", nil, nil}, {"f", strings.Repeat("x", 4097), nil, nil},
	} {
		collector := routineCollector{keyspace: "work"}
		if err := collector.add(declaration.name, declaration.types, declaration.names, declaration.result, false); !errors.Is(err, errRoutineMetadata) || len(collector.objects) != 0 {
			t.Fatal("malformed routine metadata reached completion")
		}
	}
}
