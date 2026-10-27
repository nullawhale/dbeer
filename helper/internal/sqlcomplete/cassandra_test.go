package sqlcomplete

import (
	"strings"
	"testing"
)

func TestCassandraCompletionUsesCQLAndKeyspaceMetadata(t *testing.T) {
	context := Context{Engine: "cassandra", Catalog: []Relation{
		{Schema: "demo", Name: "events", Kind: "table", Columns: []string{"tenant", "created", "status"}, PartitionKeys: []string{"tenant"}, ClusteringColumns: []string{"created"}, StaticColumns: []string{"status"}},
		{Schema: "demo", Name: "by_status", Kind: "view", Columns: []string{"tenant", "status"}},
		{Schema: "demo", Name: "address", Kind: "type"},
	}}
	for _, check := range []struct {
		sql     string
		yes, no []string
	}{
		{"|", []string{"USE", "BEGIN", "TTL"}, []string{"JOIN", "COMMIT", "OFFSET", "RETURNING", "COALESCE", "DATE_TRUNC"}},
		{"USE |", []string{"demo"}, []string{"events", "COUNT"}},
		{"SELECT * FROM |", []string{"events", "by_status", "demo"}, []string{"address", "JOIN", "COUNT"}},
		{"SELECT * FROM demo.|", []string{"events", "by_status"}, []string{"address", "COUNT"}},
		{"SELECT | FROM demo.events", []string{"tenant", "created", "TTL", "TOKEN"}, []string{"JOIN", "OFFSET", "COALESCE"}},
		{"SELECT * FROM demo.events |", []string{"WHERE", "ORDER BY", "PER PARTITION LIMIT"}, []string{"JOIN", "LEFT JOIN", "OFFSET"}},
		{"SELECT * FROM demo.events WHERE |", []string{"tenant", "CONTAINS", "TOKEN"}, []string{"OR", "EXISTS", "LIKE", "ALLOW FILTERING"}},
		{"SELECT * FROM demo.events LIMIT 10 |", nil, []string{"OFFSET", "JOIN"}},
		{"BEGIN |", []string{"BATCH", "UNLOGGED BATCH", "COUNTER BATCH"}, []string{"COMMIT", "TRANSACTION"}},
		{"INSERT INTO demo.events (tenant) VALUES (1) USING |", []string{"TTL", "TIMESTAMP"}, []string{"JOIN", "DEFAULT"}},
	} {
		t.Run(check.sql, func(t *testing.T) {
			items := suggestions(t, check.sql, context)
			names := map[string]bool{}
			for _, item := range items {
				names[item.Label] = true
			}
			for _, want := range check.yes {
				if !names[want] {
					t.Errorf("missing %s", want)
				}
			}
			for _, reject := range check.no {
				if names[reject] {
					t.Errorf("invalid CQL suggestion %s", reject)
				}
			}
		})
	}
	items := suggestions(t, "SELECT ten| FROM demo.events", context)
	if len(items) == 0 || !strings.HasPrefix(items[0].Detail, "Partition key") {
		t.Fatal("partition key detail missing")
	}
}
func TestCassandraLexingAndFunctionSignatures(t *testing.T) {
	for _, text := range []string{"SELECT * FROM demo.events // ignored )", `SELECT 'it''s )' FROM demo.events`, `SELECT 'backslash\' FROM demo.events`, "BEGIN BATCH\nUPDATE demo.events SET a=1;\nAPPLY BATCH;"} {
		if diagnostics := Diagnostics(text, "cassandra"); len(diagnostics) != 0 {
			t.Errorf("false CQL diagnostic: %v", diagnostics)
		}
	}
	if items := suggestions(t, "// SELECT |", Context{Engine: "cassandra"}); len(items) != 0 {
		t.Fatal("completion inside CQL line comment")
	}
	for _, check := range []struct{ sql, typ string }{{"SELECT now(|)", "timeuuid"}, {"SELECT TTL(|)", "int"}, {"SELECT token(|)", "partitioner token"}, {"SELECT current_timestamp(|)", "timestamp"}} {
		help := signatureAt(t, check.sql, Context{Engine: "cassandra"})
		if help == nil || !strings.HasSuffix(help.Signatures[0].Label, check.typ) {
			t.Errorf("missing Cassandra signature %s", check.sql)
		}
	}
	if help := signatureAt(t, "SELECT pg_catalog.lower(|)", Context{Engine: "cassandra"}); help != nil {
		t.Fatal("PostgreSQL built-in leaked into CQL")
	}
}

func TestCassandraUseKeyspaceLimitsUnqualifiedColumnResolution(t *testing.T) {
	context := Context{Engine: "cassandra", Keyspace: "selected", Catalog: []Relation{
		{Schema: "other", Name: "events", Kind: "table", Columns: []string{"wrong_column"}},
		{Schema: "selected", Name: "events", Kind: "table", Columns: []string{"correct_column"}},
	}}
	items := suggestions(t, "SELECT | FROM events", context)
	found := false
	for _, item := range items {
		if item.Label == "wrong_column" {
			t.Fatal("columns from another keyspace leaked into unqualified CQL")
		}
		found = found || item.Label == "correct_column"
	}
	if !found {
		t.Fatal("active keyspace column was not resolved")
	}
	items = suggestions(t, "SELECT | FROM other.events", context)
	found = false
	for _, item := range items {
		found = found || item.Label == "wrong_column"
	}
	if !found {
		t.Fatal("qualified keyspace did not override USE context")
	}
}

func TestCassandraBuiltinCompletionUsesUnambiguousNativeNamespace(t *testing.T) {
	items := suggestions(t, "SELECT TT| FROM demo.events", Context{Engine: "cassandra"})
	found := false
	for _, item := range items {
		if item.Label == "TTL" {
			found = true
			if item.InsertText != "TTL" {
				t.Fatal("special selector was incorrectly namespace qualified")
			}
		}
	}
	if !found {
		t.Fatal("TTL completion missing")
	}
	items = suggestions(t, "SELECT NO| FROM demo.events", Context{Engine: "cassandra"})
	found = false
	for _, item := range items {
		if item.Label == "NOW" {
			found = true
			if item.InsertText != "system.NOW" {
				t.Fatal("ordinary native function can resolve to a keyspace overload")
			}
		}
	}
	if !found {
		t.Fatal("ordinary native function completion missing")
	}

	if help := signatureAt(t, "SELECT system.currenttimestamp(|)", Context{Engine: "cassandra"}); help == nil || !strings.HasSuffix(help.Signatures[0].Label, "timestamp") {
		t.Fatal("native qualified Cassandra 4.1 function signature missing")
	}
}
