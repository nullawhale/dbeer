package protocol

import (
	"encoding/json"
	"os"
	"strings"
	"testing"

	"dbeer/helper/internal/schemabundle"
)

func TestSchemaBundleSourceStrictOneOfAndInspectionContract(t *testing.T) {
	sha := strings.Repeat("a", 64)
	bundle := `{"path":"/synthetic/schema-bundle","allowSQLChanges":true,"engine":"postgresql","manifestSha256":"` + sha + `","contentSha256":"` + sha + `"}`
	mapping := `{"schemas":[{"source":"public","target":"public"}],"tables":[],"types":[]}`
	valid := []string{
		`{"type":"schema.import.start","requestId":"inspect","schemaComparison":{"bundle":{"path":"/synthetic/schema-bundle","allowSQLChanges":false}}}`,
		`{"type":"schema.import.status","requestId":"status","schemaComparison":{"jobId":"job"}}`,
		`{"type":"schema.import.cancel","requestId":"cancel","schemaComparison":{"jobId":"job"}}`,
		`{"type":"schema.import.close","requestId":"close","schemaComparison":{"jobId":"job"}}`,
		`{"type":"schema.start","requestId":"compare","schemaComparison":{"source":{"bundle":` + bundle + `},"target":{"bundle":` + bundle + `},"mappings":` + mapping + `}}`,
	}
	for _, raw := range valid {
		command, e := ParseCommand([]byte(raw))
		if e != nil || command.SchemaComparison == nil {
			t.Fatalf("valid source command rejected: %v", e)
		}
		roundtrip, e := json.Marshal(command)
		if e != nil {
			t.Fatal(e)
		}
		if _, e = ParseCommand(roundtrip); e != nil {
			t.Fatal("source command changed during roundtrip")
		}
	}
	invalid := []string{
		strings.Replace(valid[0], `"path":`, `"Path":`, 1),
		strings.Replace(valid[0], `"allowSQLChanges":false`, `"allowSQLChanges":null`, 1),
		strings.Replace(valid[0], `"allowSQLChanges":false`, `"allowSQLChanges":false,"allowSQLChanges":false`, 1),
		strings.Replace(valid[0], `"allowSQLChanges":false`, `"allowSQLChanges":false,"engine":""`, 1),
		strings.Replace(valid[0], `/synthetic/schema-bundle`, `relative`, 1),
		strings.Replace(valid[4], `"manifestSha256":"`+sha+`",`, "", 1),
		strings.Replace(valid[4], `"source":{"bundle":`, `"source":{"connection":{},"bundle":`, 1),
		strings.Replace(valid[4], `"engine":"postgresql"`, `"engine":"sqlite"`, 1),
	}
	for _, raw := range invalid {
		if _, e := ParseCommand([]byte(raw)); e == nil {
			t.Fatal("ambiguous source command accepted")
		}
	}
	source := schemabundle.Source{Path: "/synthetic/schema-bundle", Engine: "postgresql", ManifestSHA256: sha, ContentSHA256: sha}
	data, e := json.Marshal(SchemaSide{Bundle: &source})
	if e != nil || strings.Contains(string(data), "connection") {
		t.Fatal("offline side fabricated a connection")
	}
	if _, e = json.Marshal(SchemaSide{Connection: Connection{Host: "server"}, Bundle: &source}); e == nil {
		t.Fatal("two source variants silently collapsed")
	}
}

func TestSchemaBundleSourceSharedFixture(t *testing.T) {
	raw, e := os.ReadFile("../../../protocol/fixtures/schema-bundle-source-v1.json")
	if e != nil {
		t.Fatal(e)
	}
	var fixture struct {
		Version    int               `json:"version"`
		Capability string            `json:"capability"`
		Commands   []json.RawMessage `json:"commands"`
		Responses  []json.RawMessage `json:"responses"`
	}
	if json.Unmarshal(raw, &fixture) != nil || fixture.Version != Version || fixture.Capability != SchemaBundleSourceCapability || len(fixture.Commands) != 5 || len(fixture.Responses) != 5 {
		t.Fatal("invalid source fixture")
	}
	for _, raw := range fixture.Commands {
		if command, e := ParseCommand(raw); e != nil || command.SchemaComparison == nil {
			t.Fatal("source fixture command rejected")
		}
	}
	for _, raw := range fixture.Responses {
		var response Response
		if e := json.Unmarshal(raw, &response); e != nil || response.SchemaComparison == nil {
			t.Fatal("source fixture response rejected")
		}
		if _, e := json.Marshal(response); e != nil {
			t.Fatal(e)
		}
	}
}

func TestSchemaSourceCommandsPreserveOriginalUnicode(t *testing.T) {
	data, err := os.ReadFile("../../../protocol/fixtures/schema-bundle-source-v1.json")
	if err != nil {
		t.Fatal(err)
	}
	var fixture struct {
		Valid   []string `json:"validCommandJSON"`
		Invalid []string `json:"invalidCommandJSON"`
	}
	if json.Unmarshal(data, &fixture) != nil || len(fixture.Valid) < 5 || len(fixture.Invalid) < 5 {
		t.Fatal("Unicode fixture missing")
	}
	for _, raw := range fixture.Valid {
		command, err := ParseCommand([]byte(raw))
		if err != nil || command.SchemaComparison == nil {
			t.Fatal("valid source Unicode rejected")
		}
		encoded, err := json.Marshal(command)
		if err != nil {
			t.Fatal(err)
		}
		again, err := ParseCommand(encoded)
		if err != nil || again.SchemaComparison.Bundle.Path != command.SchemaComparison.Bundle.Path {
			t.Fatal("source path changed")
		}
	}
	for _, raw := range fixture.Invalid {
		if _, err := ParseCommand([]byte(raw)); err == nil {
			t.Fatal("malformed schema request Unicode rewritten")
		}
	}
}
