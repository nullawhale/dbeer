package sqllsp

import (
	"dbeer/helper/internal/sqlcomplete"
	"encoding/json"
	"strings"
	"testing"
	"unicode/utf16"
)

func signatureRequest(uri string, p position, id int) map[string]any {
	return rpc("textDocument/signatureHelp", id, map[string]any{"textDocument": map[string]any{"uri": uri}, "position": p})
}

func TestSignatureHelpLifecycleIsolationAndCapabilities(t *testing.T) {
	a, b := "dbeer-sql:///signature-a.sql", "dbeer-sql:///signature-b.sql"
	catalog := []catalogEntry{{Schema: "public", Name: "calculate", Kind: "function", Signatures: []sqlcomplete.FunctionSignature{{ReturnType: "bigint", Parameters: []sqlcomplete.FunctionParameter{{Name: "input_value", Type: "integer"}, {Name: "scale", Type: "integer", Optional: true}}}}}}
	text := "SELECT public.calculate(1, "
	responses := testRun(t, rpc("initialize", 1, nil), configurationMessage(a, "postgresql", catalog), open(a, "sql", text, 1), open(b, "sql", text, 1),
		signatureRequest(a, position{Character: len(text)}, 2), signatureRequest(b, position{Character: len(text)}, 3),
		configurationMessage(a, "postgresql", nil), signatureRequest(a, position{Character: len(text)}, 4),
		rpc("textDocument/didClose", nil, map[string]any{"textDocument": map[string]any{"uri": a}}), signatureRequest(a, position{}, 5), rpc("shutdown", 6, nil), rpc("exit", nil, nil))
	var initialized struct {
		Capabilities map[string]json.RawMessage `json:"capabilities"`
	}
	if json.Unmarshal(responses[0]["result"], &initialized) != nil || initialized.Capabilities["signatureHelpProvider"] == nil {
		t.Fatal("signature capability was not advertised")
	}
	var result signatureResult
	if json.Unmarshal(responses[3]["result"], &result) != nil || len(result.Signatures) != 1 || result.ActiveParameter == nil || *result.ActiveParameter != 1 || !strings.HasSuffix(result.Signatures[0].Label, " → bigint") {
		t.Fatal("signature response lost parameters or result")
	}
	for _, i := range []int{4, 6, 8} {
		if string(responses[i]["result"]) != "null" {
			t.Fatal("signature leaked across document context or close")
		}
	}
}

func TestSignatureLabelOffsetsAreUTF16(t *testing.T) {
	context := configuration{Engine: "postgresql", Catalog: []catalogEntry{{Schema: "public", Name: "function 😀", Kind: "function", Signatures: []sqlcomplete.FunctionSignature{{ReturnType: "text", Parameters: []sqlcomplete.FunctionParameter{{Name: "first 😀", Type: "text"}, {Name: "second", Type: "integer"}}}}}}}
	text := `SELECT public."function 😀"('x', `
	result := signatureHelp(text, len(text), context)
	if result == nil || result.ActiveParameter == nil || *result.ActiveParameter != 1 {
		t.Fatal("missing active signature")
	}
	value := result.Signatures[0]
	units := utf16.Encode([]rune(value.Label))
	span := value.Parameters[1].Label
	if string(utf16.Decode(units[span[0]:span[1]])) != "second: integer" {
		t.Fatal("signature label offsets used UTF-8 bytes instead of UTF-16")
	}
}

func TestSignatureMetadataBounds(t *testing.T) {
	key := catalogEntry{Name: "f", Kind: "function", Signatures: []sqlcomplete.FunctionSignature{{ReturnType: "integer", Parameters: []sqlcomplete.FunctionParameter{{Name: "p", Type: "text"}}}}}
	valid := configuration{URI: "sql:///bounds", Engine: "postgresql", Catalog: []catalogEntry{key}}
	if !boundedConfiguration(valid) {
		t.Fatal("valid signature rejected")
	}
	invalid := valid
	invalid.Catalog = append([]catalogEntry{}, valid.Catalog...)
	invalid.Catalog[0].Signatures = make([]sqlcomplete.FunctionSignature, 33)
	if boundedConfiguration(invalid) {
		t.Fatal("unbounded overload list accepted")
	}
	invalid.Catalog[0] = key
	invalid.Catalog[0].Signatures = []sqlcomplete.FunctionSignature{{ReturnType: "integer", Parameters: []sqlcomplete.FunctionParameter{{Name: "p", Type: ""}}}}
	if boundedConfiguration(invalid) {
		t.Fatal("untyped signature parameter accepted")
	}
}
