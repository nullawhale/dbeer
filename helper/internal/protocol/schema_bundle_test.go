package protocol

import (
	"encoding/base64"
	"encoding/json"
	"os"
	"strings"
	"testing"

	"dbeer/helper/internal/schemabundle"
)

func TestSchemaBundleSharedFixture(t *testing.T) {
	b, e := os.ReadFile("../../../protocol/fixtures/schema-bundle-v1.json")
	if e != nil {
		t.Fatal(e)
	}
	var f struct {
		Version    int               `json:"version"`
		Capability string            `json:"capability"`
		Commands   []json.RawMessage `json:"commands"`
		Responses  []json.RawMessage `json:"responses"`
		Files      []struct {
			File       schemabundle.File `json:"file"`
			DataBase64 string            `json:"dataBase64"`
		} `json:"files"`
	}
	if json.Unmarshal(b, &f) != nil || f.Version != Version || f.Capability != SchemaBundleCapability || len(f.Commands) != 5 || len(f.Responses) != 5 {
		t.Fatal("invalid fixture")
	}
	for _, raw := range f.Commands {
		command, e := ParseCommand(raw)
		if e != nil || command.SchemaComparison == nil {
			t.Fatal("bundle command rejected")
		}
		encoded, e := json.Marshal(command)
		if e != nil {
			t.Fatal(e)
		}
		if _, e = ParseCommand(encoded); e != nil {
			t.Fatal("bundle command did not round trip")
		}
	}
	for _, file := range f.Files {
		data, e := base64.StdEncoding.DecodeString(file.DataBase64)
		if e != nil || int64(len(data)) != file.File.Bytes {
			t.Fatal("fixture file size differs")
		}
	}
	for _, raw := range f.Responses {
		var response Response
		if json.Unmarshal(raw, &response) != nil || response.SchemaComparison == nil {
			t.Fatal("bundle response not decodable")
		}
		encoded, e := json.Marshal(response)
		if e != nil || !strings.Contains(string(encoded), `"schemaComparison"`) {
			t.Fatal("bundle response lost its envelope")
		}
	}
}
func TestSchemaBundleStrictRequests(t *testing.T) {
	source := `"source":{"connection":{"engine":"postgresql","host":"localhost","port":5432,"database":"fixture","user":"fixture","password":"","sslMode":"disable"}}`
	valid := `{"type":"schema.bundle.start","requestId":"start","schemaComparison":{` + source + `,"schemas":["public"]}}`
	for _, raw := range []string{valid, strings.Replace(valid, `["public"]`, `["é","e\u0301"]`, 1)} {
		if _, e := ParseCommand([]byte(raw)); e != nil {
			t.Fatal("exact names rejected")
		}
	}
	for _, bad := range []string{strings.Replace(valid, `["public"]`, `[]`, 1), strings.Replace(valid, `["public"]`, `["public","public"]`, 1), strings.Replace(valid, `["public"]`, `null`, 1), strings.Replace(valid, `["public"]`, `["public"],"schemas":["private"]`, 1), strings.Replace(valid, `"schemas":`, `"target":{},"schemas":`, 1), strings.Replace(valid, `"postgresql"`, `"cassandra"`, 1), `{"type":"schema.bundle.export","requestId":"e","schemaComparison":{"jobId":"job","valueRef":"../manifest"}}`, `{"type":"schema.bundle.export","requestId":"e","schemaComparison":{"jobId":"job","valueRef":"manifest","offset":1.0}}`, `{"type":"schema.bundle.export","requestId":"e","schemaComparison":{"jobId":"job","valueRef":"manifest","offset":9223372036854775808}}`, `{"type":"schema.bundle.status","requestId":"e","schemaComparison":{"jobId":"job","source":{}}}`, `{"type":"schema.bundle.export","requestId":"e","schemaComparison":{"jobId":"job","valueRef":"manifest","maxBytes":0}}`} {
		if _, e := ParseCommand([]byte(bad)); e == nil {
			t.Fatal("invalid bundle request admitted: " + bad)
		}
	}
}
