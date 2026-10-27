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

func TestCassandraDDLCompletionUsesObjectKindsAndNativeTypes(t *testing.T) {
	context := Context{Engine: "cassandra", Keyspace: "demo", Catalog: []Relation{
		{Schema: "demo", Name: "events", Kind: "table", Columns: []string{"tenant", "created", "status"}},
		{Schema: "demo", Name: "by_status", Kind: "view"},
		{Schema: "demo", Name: "address", Kind: "type"},
		{Schema: "demo", Name: "calculate", Kind: "function"},
		{Schema: "other", Name: "address_elsewhere", Kind: "type"},
	}}
	for _, check := range []struct {
		sql     string
		yes, no []string
	}{
		{"ALTER TABLE |", []string{"events", "demo"}, []string{"address", "calculate", "by_status", "JOIN"}},
		{"DROP TABLE IF EXISTS demo.|", []string{"events"}, []string{"address", "by_status", "demo"}},
		{"TRUNCATE |", []string{"events"}, []string{"address", "by_status"}},
		{"TRUNCATE TABLE demo.|", []string{"events"}, []string{"address", "by_status"}},
		{"ALTER TYPE |", []string{"address", "address_elsewhere"}, []string{"events", "calculate"}},
		{"DROP MATERIALIZED VIEW demo.|", []string{"by_status"}, []string{"events", "address"}},
		{"DROP FUNCTION |", []string{"calculate"}, []string{"events", "address"}},
		{"ALTER KEYSPACE |", []string{"demo", "other"}, []string{"events", "address"}},
		{"CREATE TABLE demo.new_table (id |)", []string{"TEXT", "UUID", "MAP", "FROZEN", "VECTOR", "address"}, []string{"JOIN", "COUNT", "events"}},
		{"CREATE TABLE demo.new_table (id uuid, note |)", []string{"TEXT", "address"}, []string{"JOIN", "events"}},
		{"CREATE TABLE demo.new_table (id frozen<map<text, |>>)", []string{"TEXT", "address"}, []string{"events"}},
		{"CREATE TYPE demo.new_type (street demo.|)", []string{"address"}, []string{"TEXT", "events", "address_elsewhere"}},
		{"CREATE TABLE other.new_table (street |)", []string{"TEXT", "address_elsewhere"}, []string{"address", "events"}},
		{"CREATE TYPE other.new_type (street demo.|)", nil, []string{"TEXT", "address", "address_elsewhere"}},
		{"CREATE OR REPLACE FUNCTION other.new_fn(street |) RETURNS text", []string{"TEXT", "address_elsewhere"}, []string{"address", "events"}},
		{"ALTER TABLE demo.events ADD note |", []string{"TEXT", "TUPLE"}, []string{"events", "COUNT"}},
		{"CREATE FUNCTION demo.f(value |) RETURNS text", []string{"TEXT", "address"}, []string{"events"}},
		{"CREATE FUNCTION demo.f(value int) RETURNS |", []string{"TEXT", "address"}, []string{"events"}},
		{"CREATE AGGREGATE demo.a(int) SFUNC f STYPE |", []string{"TEXT", "TUPLE"}, []string{"events"}},
		{"CREATE AGGREGATE demo.a(|)", []string{"TEXT", "TUPLE"}, []string{"events"}},
		{"DROP FUNCTION demo.calculate(|)", []string{"TEXT", "TUPLE"}, []string{"events"}},
		{"CREATE TABLE demo.new_table (v vector<float, |>)", nil, []string{"TEXT", "address", "events"}},
		{"SELECT * FROM demo.events ORDER BY created |", []string{"ANN", "ASC", "DESC"}, []string{"JOIN", "OFFSET"}},
		{"SELECT * FROM demo.events ORDER BY created ANN |", []string{"OF"}, []string{"JOIN", "ASC"}},
	} {
		t.Run(check.sql, func(t *testing.T) {
			items := suggestions(t, check.sql, context)
			for _, name := range check.yes {
				if _, found := itemWithLabel(items, name); !found {
					t.Errorf("missing %s", name)
				}
			}
			for _, name := range check.no {
				if _, found := itemWithLabel(items, name); found {
					t.Errorf("invalid suggestion %s", name)
				}
			}
		})
	}
}

func TestCassandraInsertAndUsingKeepTableColumnsVisible(t *testing.T) {
	context := Context{Engine: "cassandra", Keyspace: "demo", Catalog: []Relation{
		{Schema: "demo", Name: "events", Kind: "table", Columns: []string{"tenant", "created", "status"}},
	}}
	for _, sql := range []string{"INSERT INTO demo.events (|)", "INSERT INTO events (tenant, |)", "UPDATE demo.events USING TTL 60 SET |", "DELETE | FROM demo.events"} {
		items := suggestions(t, sql, context)
		for _, name := range []string{"tenant", "created", "status"} {
			if _, found := itemWithLabel(items, name); !found {
				t.Errorf("%s: missing %s", sql, name)
			}
		}
	}
}

func TestCassandraTokenRelationCompletionKeepsParserSyntax(t *testing.T) {
	items := suggestions(t, "SELECT * FROM demo.events WHERE tok|", Context{Engine: "cassandra"})
	item, found := itemWithLabel(items, "TOKEN")
	if !found || item.InsertText != "TOKEN" {
		t.Fatal("token relation was completed as a qualified function")
	}
}

func TestCassandraSignaturesRespectLiteralNestingAndActiveKeyspace(t *testing.T) {
	context := Context{Engine: "cassandra", Keyspace: "demo", Catalog: []Relation{
		{Schema: "other", Name: "calculate", Kind: "function", Signatures: []FunctionSignature{{Parameters: []FunctionParameter{{Name: "wrong", Type: "int"}}, ReturnType: "text"}}},
		{Schema: "demo", Name: "calculate", Kind: "function", Signatures: []FunctionSignature{{Parameters: []FunctionParameter{{Name: "value", Type: "map<text, text>"}, {Name: "scale", Type: "int", Position: 1}}, ReturnType: "int"}}},
	}}
	for _, sql := range []string{
		"SELECT calculate({'one': 'two', 'three': 'four'}, |)",
		"SELECT calculate({field: {'nested': 'one', 'two': 'three'}, other: [1, 2]}, |)",
		"SELECT calculate({'one', 'two', 'three'}, |)",
		"SELECT calculate({1: ['a', 'b'], 2: ['c', 'd']}, |)",
	} {
		help := signatureAt(t, sql, context)
		if help == nil || len(help.Signatures) != 1 || help.Signatures[0].ActiveParameter != 1 || !strings.HasSuffix(help.Signatures[0].Label, " → int") {
			t.Errorf("wrong signature for nested literal: %s: %+v", sql, help)
		}
	}
	if help := signatureAt(t, "SELECT other.calculate(|)", context); help == nil || !strings.HasSuffix(help.Signatures[0].Label, " → text") {
		t.Fatal("qualified function did not override active keyspace")
	}
	context.Keyspace = "unrelated"
	if help := signatureAt(t, "SELECT calculate(|)", context); help != nil {
		t.Fatal("function from another keyspace leaked into signature help")
	}
}

func TestCassandraPopulatedLiteralCountsAsOneSignatureArgument(t *testing.T) {
	context := Context{Engine: "cassandra", Keyspace: "demo", Catalog: []Relation{{Schema: "demo", Name: "choose", Kind: "function", Signatures: []FunctionSignature{
		{ReturnType: "int"},
		{Parameters: []FunctionParameter{{Name: "value", Type: "map<text, text>"}}, ReturnType: "text"},
	}}}}
	for _, sql := range []string{
		"SELECT choose({'one': 'two', 'three': 'four'}|)",
		"SELECT choose([1, 2, 3]|)",
		"SELECT choose((1, 2)|)",
		"SELECT choose({}|)",
	} {
		help := signatureAt(t, sql, context)
		if help == nil || help.ActiveSignature != 1 || help.Signatures[1].ActiveParameter != 0 {
			t.Errorf("literal disappeared from function arity: %s: %+v", sql, help)
		}
	}
}

func TestCassandraSignaturesUseQualifiedTargetTableKeyspace(t *testing.T) {
	context := Context{Engine: "cassandra", Keyspace: "demo", Catalog: []Relation{
		{Schema: "demo", Name: "combine", Kind: "function", Signatures: []FunctionSignature{{ReturnType: "int"}}},
		{Schema: "other", Name: "combine", Kind: "function", Signatures: []FunctionSignature{{ReturnType: "text"}}},
		{Schema: "Quoted", Name: "combine", Kind: "function", Signatures: []FunctionSignature{{ReturnType: "bigint"}}},
	}}
	for _, check := range []struct{ sql, result string }{
		{"SELECT combine(|) FROM other.events", "text"},
		{"SELECT combine(|) FROM events", "int"},
		{"SELECT combine(|) FROM \"Quoted\".events", "bigint"},
		{"INSERT INTO other.events (id, v) VALUES (1, combine(|))", "text"},
		{"UPDATE other.events SET v = combine(|) WHERE id = 1", "text"},
		{"SELECT * FROM other.events WHERE v = combine(|)", "text"},
		{"SELECT combine(1) FROM demo.events; SELECT combine(|) FROM other.events", "text"},
		{"SELECT demo.combine(|) FROM other.events", "int"},
	} {
		help := signatureAt(t, check.sql, context)
		if help == nil || len(help.Signatures) != 1 || !strings.HasSuffix(help.Signatures[0].Label, " → "+check.result) {
			t.Errorf("wrong keyspace for %s: %+v", check.sql, help)
		}
	}
}

func TestCassandraLexingOnlyUsesDoubleDollarStrings(t *testing.T) {
	if diagnostics := Diagnostics("CREATE FUNCTION f() RETURNS text LANGUAGE java AS$$return \"(\";$$", "cassandra"); len(diagnostics) != 0 {
		t.Fatalf("valid CQL function body was not lexed as a string: %v", diagnostics)
	}
	tokens, _ := lex("SELECT $tag$ FROM events", "cassandra")
	for _, token := range tokens {
		if token.kind == stringToken || token.kind == wordToken && strings.Contains(token.value, "$") {
			t.Fatal("PostgreSQL dollar tag was accepted as a CQL string or identifier")
		}
	}
}

func TestCassandraCqlshCommandsHaveClientSpecificDiagnostics(t *testing.T) {
	for _, command := range []string{
		"SOURCE 'local.cql'", "COPY demo.events TO 'local.csv'", "CAPTURE 'local.log'", "CONSISTENCY QUORUM",
		"SERIAL CONSISTENCY LOCAL_SERIAL", "PAGING 100", "EXPAND ON", "TRACING ON", "SHOW VERSION", "HELP SELECT", "LOGIN user", "EXIT", "QUIT",
	} {
		text := "SELECT 1; // ignored client commands\n" + command + ";"
		diagnostics := Diagnostics(text, "cassandra")
		if len(diagnostics) != 1 || !strings.Contains(diagnostics[0].Message, "cqlsh") || diagnostics[0].Start != strings.Index(text, command) {
			t.Errorf("missing CQL client diagnostic for %s: %+v", command, diagnostics)
		}
	}
	for _, text := range []string{
		`SELECT consistency, paging, tracing FROM demo.events;`,
		`LIST ALL PERMISSIONS; DESCRIBE SCHEMA; DESC KEYSPACE demo;`,
		`SELECT 'SOURCE local.cql', $$CONSISTENCY ALL;$$ FROM demo.events;`,
		`"SOURCE"; "HELP";`,
		`CREATE ROLE reader WITH LOGIN = true;`,
	} {
		if diagnostics := Diagnostics(text, "cassandra"); len(diagnostics) != 0 {
			t.Errorf("native CQL or quoted text was rejected: %+v", diagnostics)
		}
	}
	if diagnostics := Diagnostics("SHOW VERSION; COPY t TO 'local.csv';", "postgresql"); len(diagnostics) != 0 {
		t.Fatal("CQL client diagnostics leaked to SQL")
	}
}

func TestCassandraCollectionDelimiterDiagnostics(t *testing.T) {
	for _, text := range []string{
		"INSERT INTO demo.events (id, tags) VALUES (1, {'a', 'b');",
		"SELECT similarity_cosine(embedding, [0.1, 0.2) FROM demo.events;",
		"SELECT [1, 2};",
	} {
		if diagnostics := Diagnostics(text, "cassandra"); len(diagnostics) == 0 {
			t.Errorf("missing collection delimiter diagnostic: %s", text)
		}
	}
	for _, text := range []string{
		"INSERT INTO demo.events (id, v) VALUES (1, {a: [1, 2], b: {'x', 'y'}});",
		`SELECT '{[}]', $$[};$$ FROM demo.events; // [}`,
	} {
		if diagnostics := Diagnostics(text, "cassandra"); len(diagnostics) != 0 {
			t.Errorf("false collection diagnostic: %s: %+v", text, diagnostics)
		}
	}
}

func TestCassandraJSONFunctionsFollowCQLTermAndSelectorContexts(t *testing.T) {
	for _, check := range []struct {
		sql     string
		yes, no []string
	}{
		{"SELECT | FROM demo.events", []string{"TOJSON"}, []string{"FROMJSON"}},
		{"SELECT system.| FROM demo.events", []string{"TOJSON"}, []string{"FROMJSON"}},
		{"INSERT INTO demo.events (id, v) VALUES (1, |)", []string{"FROMJSON", "NOW"}, []string{"TOJSON", "WHERE"}},
		{"INSERT INTO demo.events (id, v) VALUES (1, system.|)", []string{"FROMJSON", "NOW"}, []string{"TOJSON"}},
		{"UPDATE demo.events SET v = | WHERE id = 1", []string{"FROMJSON"}, []string{"TOJSON"}},
		{"SELECT * FROM demo.events WHERE v = |", []string{"FROMJSON"}, []string{"TOJSON"}},
	} {
		items := suggestions(t, check.sql, Context{Engine: "cassandra"})
		for _, name := range check.yes {
			if _, found := itemWithLabel(items, name); !found {
				t.Errorf("%s: missing %s", check.sql, name)
			}
		}
		for _, name := range check.no {
			if _, found := itemWithLabel(items, name); found {
				t.Errorf("%s: invalid %s", check.sql, name)
			}
		}
	}
}
