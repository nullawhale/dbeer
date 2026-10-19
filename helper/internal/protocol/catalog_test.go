package protocol

import (
	"encoding/json"
	"reflect"
	"strings"
	"testing"
)

func TestCatalogRequestValidationAndCorrelation(t *testing.T) {
	for _, request := range []CatalogRequest{
		{Kind: "schemas"},
		{Kind: "search", Search: "%_"},
		{Kind: "search", Schema: "schema", Search: "quoted'name"},
		{Kind: "objects", Schema: "schema", ObjectKind: "table"},
		{Kind: "objects", Schema: "schema", ObjectKind: "procedure"},
		{Kind: "columns", Schema: "schema", Object: "table"},
		{Kind: "keys", Schema: "schema", Object: "table"},
		{Kind: "indexes", Schema: "schema", Object: "table"},
		{Kind: "constraints", Schema: "schema", Object: "table"},
		{Kind: "triggers", Schema: "schema", Object: "table"},
		{Kind: "definition", Schema: "schema", Object: "overloaded", ObjectKind: "function", Identity: "1234"},
		{Kind: "definition", Schema: "schema", Object: "trigger", ObjectKind: "trigger", Identity: "4567"},
		{Kind: "name", Schema: "schema", Object: "表\"name", ObjectKind: "table"},
		{Kind: "name", Schema: "schema", Object: "view", ObjectKind: "view"},
		{Kind: "name", Schema: "schema", Object: "overloaded", ObjectKind: "function"},
		{Kind: "name", Schema: "schema", Object: "overloaded", ObjectKind: "function", Identity: "1234"},
		{Kind: "name", Schema: "schema", Object: "procedure", ObjectKind: "procedure", Identity: "4567"},
		{Kind: "name", Schema: "schema", Object: "trigger", ObjectKind: "trigger", Identity: "5678"},
		{Kind: "select", Schema: "schema", Object: "table\";--", ObjectKind: "table"},
		{Kind: "browse", Schema: "schema", Object: "view", ObjectKind: "view"},
	} {
		command := Command{Type: "catalog", RequestID: "catalog-request", SessionID: "catalog-session", QueryID: "catalog-query", Catalog: &request}
		frame, err := json.Marshal(command)
		if err != nil {
			t.Fatal(err)
		}
		decoded, err := ParseCommand(frame)
		if err != nil || decoded.Catalog == nil || !reflect.DeepEqual(*decoded.Catalog, request) || decoded.RequestID != command.RequestID || decoded.SessionID != command.SessionID || decoded.QueryID != command.QueryID {
			t.Fatalf("catalog kind %q failed validation or lost correlation", request.Kind)
		}
	}
}

func TestInvalidCatalogRequestsAreSafe(t *testing.T) {
	for _, catalog := range []string{
		`null`, `[]`, `{}`, `{"kind":"unknown"}`, `{"kind":"schemas","schema":"unexpected"}`,
		`{"kind":"schemas","sql":"secret-input"}`, `{"kind":"schemas","schema":null}`,
		`{"kind":"objects","schema":"schema"}`, `{"kind":"objects","schema":"schema","objectKind":"sqlite"}`,
		`{"kind":"browse","schema":"schema","object":"table","objectKind":"function"}`,
		`{"kind":"columns","schema":"schema","object":"table","identity":"unexpected"}`,
		`{"kind":"schemas","search":"unexpected"}`, `{"kind":"search"}`, `{"kind":"search","search":null}`,
		`{"kind":"search","search":"name","objectKind":"table"}`,
		`{"kind":"schemas","kind":"secret-input"}`,
		`{"kind":"name","schema":"schema","object":"name"}`,
		`{"kind":"name","schema":"schema","object":"name","objectKind":"index"}`,
		`{"kind":"name","schema":"schema","object":"name","objectKind":"table","identity":"secret-input"}`,
		`{"kind":"name","schema":"schema","object":"name","objectKind":"table","identity":""}`,
		`{"kind":"name","schema":"schema","object":"name","objectKind":"view","search":"secret-input"}`,
		`{"kind":"name","schema":"schema","object":"name","objectKind":"view","search":""}`,
		`{"kind":"name","schema":"schema","object":"name","objectKind":"function","page":0}`,
		`{"kind":"name","schema":"schema","object":"name","objectKind":"function","page":1}`,
		`{"kind":"name","schema":"schema","object":"name","objectKind":"function","sort":[{"column":"x","direction":"asc"}]}`,
		`{"kind":"name","schema":"schema","object":"name","objectKind":"function","sort":[]}`,
		`{"kind":"name","schema":"schema","object":"name","objectKind":"function","filters":[{"column":"x","operator":"isNull"}]}`,
		`{"kind":"name","schema":"schema","object":"name","objectKind":"function","filters":[]}`,
		`{"kind":"columns","schema":"schema","object":"null\u0000byte"}`,
		`{"kind":"columns","schema":"schema","object":"` + strings.Repeat("x", 1025) + `"}`,
	} {
		frame := `{"type":"catalog","requestId":"request","sessionId":"session","queryId":"query","catalog":` + catalog + `}`
		_, err := ParseCommand([]byte(frame))
		if err == nil || strings.Contains(err.Error(), "secret-input") {
			t.Fatal("invalid catalog request was accepted or leaked input")
		}
	}
}
