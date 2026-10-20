package cassandra

import (
	"context"
	"errors"
	"strings"
	"testing"

	"dbeer/helper/internal/protocol"
	gocql "github.com/apache/cassandra-gocql-driver/v2"
)

func ptr(value string) *string { return &value }
func TestCassandraBrowseRejectsFilteringAndInvalidClusteringSort(t *testing.T) {
	columns := []tableColumn{{name: "tenant", kind: "partition_key", position: 0}, {name: "region", kind: "partition_key", position: 1}, {name: "created", kind: "clustering", position: 0, order: "desc"}, {name: "id", kind: "clustering", position: 1, order: "asc"}, {name: "body", kind: "regular"}, {name: "label", kind: "regular", indexed: true}}
	for i := range columns {
		columns[i].nativeType = "int"
	}
	pk := []protocol.CatalogFilter{{Column: "tenant", Operator: "eq", Value: ptr("a' OR true")}, {Column: "region", Operator: "eq", Value: ptr("west")}}
	tests := []struct {
		name    string
		filters []protocol.CatalogFilter
		sort    []protocol.CatalogSort
		valid   bool
	}{
		{name: "scan", valid: true},
		{name: "partial partition", filters: pk[:1]},
		{name: "full partition", filters: pk, valid: true},
		{name: "clustering gap", filters: append(append([]protocol.CatalogFilter{}, pk...), protocol.CatalogFilter{Column: "id", Operator: "eq", Value: ptr("1")})},
		{name: "non-key filter", filters: []protocol.CatalogFilter{{Column: "body", Operator: "eq", Value: ptr("value")}}},
		{name: "indexed eq", filters: []protocol.CatalogFilter{{Column: "label", Operator: "eq", Value: ptr("value")}}, valid: true},
		{name: "indexed contains", filters: []protocol.CatalogFilter{{Column: "label", Operator: "contains", Value: ptr("value")}}},
		{name: "global sort", sort: []protocol.CatalogSort{{Column: "created", Direction: "asc"}}},
		{name: "natural order", filters: pk, sort: []protocol.CatalogSort{{Column: "created", Direction: "desc"}, {Column: "id", Direction: "asc"}}, valid: true},
		{name: "reverse order", filters: pk, sort: []protocol.CatalogSort{{Column: "created", Direction: "asc"}, {Column: "id", Direction: "desc"}}, valid: true},
		{name: "mixed incompatible order", filters: pk, sort: []protocol.CatalogSort{{Column: "created", Direction: "asc"}, {Column: "id", Direction: "asc"}}},
		{name: "ordered suffix after eq", filters: append(append([]protocol.CatalogFilter{}, pk...), protocol.CatalogFilter{Column: "created", Operator: "eq", Value: ptr("1")}), sort: []protocol.CatalogSort{{Column: "id", Direction: "asc"}}, valid: true},
	}
	for _, test := range tests {
		t.Run(test.name, func(t *testing.T) {
			sql, values, err := browseStatement(protocol.CatalogRequest{Kind: "browse", Schema: `a"b`, Object: "records", Filters: test.filters, Sort: test.sort}, columns)
			if (err == nil) != test.valid {
				t.Fatalf("valid=%v err=%v sql=%s", test.valid, err, sql)
			}
			if err == nil {
				if strings.Contains(sql, "ALLOW FILTERING") || strings.Contains(sql, "COUNT(") || strings.Contains(sql, "OFFSET") || strings.Contains(sql, "a' OR true") {
					t.Fatalf("unsafe generated CQL: %s", sql)
				}
				if len(values) != len(test.filters) {
					t.Fatal("values lost")
				}
			}
		})
	}
}
func TestCassandraSchemaFingerprintIncludesAllColumnProperties(t *testing.T) {
	original := []tableColumn{{name: "id", nativeType: "int", kind: "partition_key", position: 0}}
	fingerprint := schemaFingerprint(original)
	for _, change := range []tableColumn{{name: "other", nativeType: "int", kind: "partition_key", position: 0}, {name: "id", nativeType: "bigint", kind: "partition_key", position: 0}, {name: "id", nativeType: "int", kind: "clustering", position: 0}, {name: "id", nativeType: "int", kind: "partition_key", position: 1}, {name: "id", nativeType: "int", kind: "partition_key", position: 0, indexed: true}} {
		if fingerprint == schemaFingerprint([]tableColumn{change}) {
			t.Fatal("schema change did not invalidate fingerprint")
		}
	}
}

func TestCassandraTableDefinitionPreservesClusteringOrderAndWarnsAboutOmittedTTL(t *testing.T) {
	columns := []tableColumn{{name: "tenant", nativeType: "int", kind: "partition_key"}, {name: "created", nativeType: "timestamp", kind: "clustering", order: "desc"}, {name: "id", nativeType: "int", kind: "clustering", order: "asc", position: 1}, {name: "shared", nativeType: "text", kind: "static"}}
	definition := tableDefinition("ks", "events", columns)
	for _, want := range []string{`WITH CLUSTERING ORDER BY ("created" DESC, "id" ASC)`, `"shared" text STATIC`, "Partial table definition", "default_time_to_live", "not a complete schema recreation script"} {
		if !strings.Contains(definition, want) {
			t.Fatalf("missing %q from table definition", want)
		}
	}
}

func TestCassandraGeneratedFiltersRejectComplexTypesBeforeDriverExecution(t *testing.T) {
	for _, nativeType := range []string{"frozen<tuple<int, text>>", "tuple<int,text>", "frozen<address>", "address", "ks.address", `"ks"."address"`, "list<text>", "set<int>", "map<text,int>", "vector<float,3>", ""} {
		columns := []tableColumn{{name: "key", nativeType: nativeType, kind: "partition_key"}}
		request := protocol.CatalogRequest{Kind: "browse", Schema: "ks", Object: "records", ObjectKind: "table", Filters: []protocol.CatalogFilter{{Column: "key", Operator: "eq", Value: ptr("(1, 'value')")}}}
		if sql, values, err := browseStatement(request, columns); !errors.Is(err, errBrowseType) || sql != "" || values != nil {
			t.Fatalf("unsupported %s reached query generation", nativeType)
		}
	}
	for _, nativeType := range []string{"ascii", "text", "varchar", "int", "bigint", "smallint", "tinyint", "counter", "uuid", "timeuuid", "inet", "date", "duration", "blob", "boolean", "varint", "decimal", "float", "double", "timestamp", "time"} {
		columns := []tableColumn{{name: "key", nativeType: nativeType, kind: "partition_key"}}
		if _, _, err := browseStatement(protocol.CatalogRequest{Schema: "ks", Object: "records", Filters: []protocol.CatalogFilter{{Column: "key", Operator: "eq", Value: ptr("value")}}}, columns); err != nil {
			t.Fatalf("supported scalar %s rejected", nativeType)
		}
	}
	// A schema change or a malformed scalar may still be caught by the driver's
	// authoritative prepared type. Preserve its local validation semantics.
	_, err := (textParameter{Value: "not-an-integer"}).MarshalCQL(native(gocql.TypeInt))
	if !errors.Is(err, errBrowse) {
		t.Fatal("invalid scalar did not remain a local conversion failure")
	}
	response := safeError(protocol.Command{Type: "catalog"}, context.Background(), err, false, true)
	if response.Category != "validation" || !response.Connected || response.OutcomeUnknown || response.SQLState != "" {
		t.Fatalf("local invalid value pretends connection loss: %#v", response)
	}
}
