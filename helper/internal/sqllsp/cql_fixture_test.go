package sqllsp

import (
	"encoding/json"
	"os"
	"strings"
	"testing"
	"unicode/utf16"
)

func TestCQLSharedCatalogAndSignatureFixture(t *testing.T) {
	var fixture struct {
		Version        int
		Keyspace       string
		CatalogRecords []map[string]string
		Signatures     []struct {
			Text, Parameter, ReturnType string
			OffsetUTF16                 int
		}
	}
	data, err := os.ReadFile("../../../protocol/fixtures/cql-language-v1.json")
	if err != nil || json.Unmarshal(data, &fixture) != nil || fixture.Version != 1 {
		t.Fatal("CQL language fixture unavailable or malformed")
	}
	c := configuration{URI: "dbeer-sql:///cql-fixture", Engine: "cassandra", Keyspace: fixture.Keyspace}
	for _, row := range fixture.CatalogRecords {
		entry := catalogEntry{Schema: row["schema"], Name: row["name"], Kind: row["kind"]}
		for _, field := range []struct {
			name  string
			value any
		}{{"columns", &entry.Columns}, {"partitionKeys", &entry.PartitionKeys}, {"clusteringColumns", &entry.ClusteringColumns}, {"staticColumns", &entry.StaticColumns}, {"signatures", &entry.Signatures}} {
			if text := row[field.name]; text != "" {
				if err := json.Unmarshal([]byte(text), field.value); err != nil {
					t.Fatalf("invalid %s in catalog fixture", field.name)
				}
			}
		}
		c.Catalog = append(c.Catalog, entry)
	}
	if !boundedConfiguration(c) {
		t.Fatal("shared CQL metadata rejected at LSP boundary")
	}
	for _, check := range fixture.Signatures {
		t.Run(check.Text, func(t *testing.T) {
			offset := len(check.Text)
			if check.OffsetUTF16 > 0 {
				var ok bool
				offset, ok = offsetAt(check.Text, position{Character: check.OffsetUTF16})
				if !ok {
					t.Fatal("invalid fixture caret position")
				}
			}
			help := signatureHelp(check.Text, offset, c)
			if help == nil || help.ActiveSignature >= len(help.Signatures) || help.ActiveParameter == nil {
				t.Fatal("missing CQL signature help")
			}
			value := help.Signatures[help.ActiveSignature]
			span := value.Parameters[*help.ActiveParameter].Label
			units := utf16.Encode([]rune(value.Label))
			if string(utf16.Decode(units[span[0]:span[1]])) != check.Parameter || !strings.HasSuffix(value.Label, " → "+check.ReturnType) {
				t.Fatalf("incorrect active CQL signature: %s", value.Label)
			}
		})
	}
}
