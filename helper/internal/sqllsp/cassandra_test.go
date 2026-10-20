package sqllsp

import (
	"strings"
	"testing"
)

func TestCassandraConfigurationAndCompletion(t *testing.T) {
	context := configuration{URI: "sql:///cql", Engine: "cassandra", Catalog: []catalogEntry{{Schema: "demo", Name: "events", Kind: "table", Columns: []string{"tenant"}, PartitionKeys: []string{"tenant"}}, {Schema: "demo", Name: "address", Kind: "type"}}}
	if !boundedConfiguration(context) {
		t.Fatal("Cassandra catalog configuration rejected")
	}
	s := server{contexts: map[string]configuration{context.URI: context}}
	if s.context(document{language: "cassandra"}, context.URI).Engine != "cassandra" {
		t.Fatal("CQL engine normalized to PostgreSQL")
	}
	items := complete("SELECT * FROM demo.", len("SELECT * FROM demo."), context)
	if len(items) != 1 || items[0].Label != "events" || !strings.Contains(items[0].InsertText, "events") {
		t.Fatal("CQL qualified table completion incorrect")
	}
	items = complete("SELECT ", 7, context)
	for _, item := range items {
		if item.Label == "COALESCE" {
			t.Fatal("SQL function leaked into CQL LSP")
		}
	}
}
