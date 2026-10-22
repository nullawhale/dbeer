package protocol

import (
	"encoding/json"
	"os"
	"strings"
	"testing"
)

func TestSchemaSharedWireFixture(t *testing.T) {
	b, e := os.ReadFile("../../../protocol/fixtures/schema-comparison-v1.json")
	if e != nil {
		t.Fatal(e)
	}
	var f struct {
		Version    int               `json:"version"`
		Capability string            `json:"capability"`
		Commands   []json.RawMessage `json:"commands"`
		Responses  []json.RawMessage `json:"responses"`
	}
	if json.Unmarshal(b, &f) != nil || f.Version != Version || f.Capability != SchemaComparisonCapability || len(f.Commands) != 7 {
		t.Fatal("invalid fixture")
	}
	for _, raw := range f.Commands {
		c, e := ParseCommand(raw)
		if e != nil || c.SchemaComparison == nil {
			t.Fatal("schema fixture command rejected")
		}
		encoded, e := json.Marshal(c)
		if e != nil {
			t.Fatal(e)
		}
		if _, e = ParseCommand(encoded); e != nil {
			t.Fatal("schema command failed round trip")
		}
	}
}
func TestSchemaStrictRequestsFailBeforeOpen(t *testing.T) {
	b, _ := os.ReadFile("../../../protocol/fixtures/schema-comparison-v1.json")
	var fixture struct {
		Commands []json.RawMessage `json:"commands"`
	}
	_ = json.Unmarshal(b, &fixture)
	start := string(fixture.Commands[0])
	for _, bad := range []string{strings.Replace(start, `"schemas":`, `"schemas":null,"other":`, 1), strings.Replace(start, `"postgresql"`, `"mysql"`, 1), strings.Replace(start, `"postgresql"`, `"cassandra"`, -1), strings.Replace(start, `"tables": []`, `"tables": null`, 1), strings.Replace(start, `"requestId": "start"`, `"requestId":"start","sql":"SELECT 1"`, 1), strings.Replace(start, `"port": 5432`, `"port":5432,"port":5433`, 1), `{"type":"schema.page","requestId":"p","schemaComparison":{"jobId":"j","collection":"issues","limit":0}}`, `{"type":"schema.value","requestId":"v","schemaComparison":{"jobId":"j","valueRef":"v","offset":null}}`, `{"type":"schema.export","requestId":"e","schemaComparison":{"jobId":"j","maxBytes":1048577}}`} {
		if _, e := ParseCommand([]byte(bad)); e == nil {
			t.Fatal("invalid schema request admitted")
		}
	}
}
