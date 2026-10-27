package cassandra_test

import (
	"context"
	"encoding/json"
	"os"
	"strings"
	"testing"
	"time"

	"dbeer/helper/internal/protocol"
	"dbeer/helper/internal/sqlcomplete"
)

func TestCassandraLiveRoutineCompletionDeclarations(t *testing.T) {
	if os.Getenv("DBEER_TEST_CASSANDRA_UDF") != "1" {
		t.Skip("Cassandra UDF fixture is not enabled")
	}
	connection := liveConnection(t)
	s := liveOpen(t, connection)
	keyspace := `"` + strings.ReplaceAll(connection.Database, `"`, `""`) + `"`
	step := keyspace + `.completion_step`
	overload := keyspace + `.completion_overload`
	aggregate := keyspace + `.completion_total`
	t.Cleanup(func() {
		ctx, cancel := context.WithTimeout(context.Background(), 20*time.Second)
		defer cancel()
		for _, statement := range []string{
			"DROP AGGREGATE IF EXISTS " + aggregate + "(int)",
			"DROP FUNCTION IF EXISTS " + overload + "(text)",
			"DROP FUNCTION IF EXISTS " + overload + "(int)",
			"DROP FUNCTION IF EXISTS " + step + "(bigint,int)",
		} {
			_ = s.Execute(ctx, protocol.Command{Type: "execute", RequestID: "completion-cleanup", SQL: statement})
		}
	})
	liveSQL(t, s, "CREATE OR REPLACE FUNCTION "+step+"(state bigint, value int) CALLED ON NULL INPUT RETURNS bigint LANGUAGE java AS $$ /* completion_source_body */ return state + value; $$")
	liveSQL(t, s, "CREATE OR REPLACE FUNCTION "+overload+"(value int) CALLED ON NULL INPUT RETURNS int LANGUAGE java AS $$ return value; $$")
	liveSQL(t, s, "CREATE OR REPLACE FUNCTION "+overload+"(value text) CALLED ON NULL INPUT RETURNS text LANGUAGE java AS $$ return value; $$")
	liveSQL(t, s, "CREATE OR REPLACE AGGREGATE "+aggregate+"(int) SFUNC completion_step STYPE bigint INITCOND 0")

	declarations := map[string][]sqlcomplete.FunctionSignature{}
	for page := 0; page < 100; page++ {
		response := liveCatalog(t, s, protocol.CatalogRequest{Kind: "completion", Schema: connection.Database, Page: page})
		if response.Type != "query.result" {
			t.Fatalf("Cassandra routine completion failed: category=%s", response.Category)
		}
		encoded, err := json.Marshal(response)
		if err != nil || strings.Contains(string(encoded), "completion_source_body") {
			t.Fatal("language metadata exposed a routine source body")
		}
		for _, row := range response.Rows {
			record := map[string]string{}
			for i, column := range response.Columns {
				if i < len(row) && row[i] != nil {
					record[column.Name] = *row[i]
				}
			}
			if record["kind"] != "function" {
				continue
			}
			var signatures []sqlcomplete.FunctionSignature
			if err := json.Unmarshal([]byte(record["signatures"]), &signatures); err != nil {
				t.Fatal("routine signatures are not valid language metadata")
			}
			declarations[record["name"]] = signatures
		}
		if len(response.Rows) < 200 {
			break
		}
	}
	if len(declarations["completion_overload"]) != 2 {
		t.Fatal("completion did not preserve both real UDF overloads")
	}
	stepSignatures := declarations["completion_step"]
	if len(stepSignatures) != 1 || len(stepSignatures[0].Parameters) != 2 || stepSignatures[0].Parameters[0].Name != "state" || stepSignatures[0].Parameters[1].Type != "int" || stepSignatures[0].ReturnType != "bigint" {
		t.Fatal("completion did not preserve real UDF names and type declarations")
	}
	aggregateSignatures := declarations["completion_total"]
	if len(aggregateSignatures) != 1 || len(aggregateSignatures[0].Parameters) != 1 || aggregateSignatures[0].Parameters[0].Name != "arg1" || aggregateSignatures[0].Parameters[0].Type != "int" || aggregateSignatures[0].ReturnType != "bigint" {
		t.Fatal("completion did not preserve a real aggregate declaration")
	}
}
