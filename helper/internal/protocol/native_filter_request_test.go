package protocol

import (
	"encoding/json"
	"os"
	"strings"
	"testing"
)

type nativeRequestFixture struct {
	ValidCatalogJSON   []string
	InvalidCatalogJSON []string
	InvalidJSON        []string
	AggregateBudgets   []struct {
		Representation string
		Copies         int
		PayloadBytes   int
		Escaped        bool
		Valid          bool
	}
}

func readNativeRequestFixture(t *testing.T) nativeRequestFixture {
	t.Helper()
	path := os.Getenv("DBEER_TEST_NATIVE_FILTER_FIXTURE")
	if path == "" {
		path = "../../../protocol/fixtures/native-cell-filter-v1.json"
	}
	data, err := os.ReadFile(path)
	if err != nil {
		t.Fatal("native request fixture unavailable")
	}
	var fixture nativeRequestFixture
	if json.Unmarshal(data, &fixture) != nil || len(fixture.ValidCatalogJSON) < 4 || len(fixture.InvalidCatalogJSON) < 4 || len(fixture.AggregateBudgets) < 4 {
		t.Fatal("native request fixture invalid")
	}
	return fixture
}
func nativeCatalogFrame(raw string) []byte {
	return []byte(`{"type":"catalog","requestId":"r","sessionId":"s","queryId":"q","catalog":` + raw + `}`)
}
func TestNativeFilterCatalogUnicodeRejectsMalformedIdentifiersBeforeRewrite(t *testing.T) {
	fixture := readNativeRequestFixture(t)
	for _, raw := range fixture.InvalidJSON {
		var filter CatalogFilter
		if json.Unmarshal([]byte(raw), &filter) == nil {
			t.Fatal("invalid native filter Unicode/shape accepted")
		}
	}
	for _, raw := range fixture.InvalidCatalogJSON {
		if _, ok := parseCatalog(json.RawMessage(raw)); ok {
			t.Fatal("malformed native catalog identity was rewritten")
		}
		if _, err := ParseCommand(nativeCatalogFrame(raw)); err == nil {
			t.Fatal("malformed catalog identity reached command dispatch")
		}
	}
	for _, raw := range fixture.ValidCatalogJSON {
		request, ok := parseCatalog(json.RawMessage(raw))
		if !ok {
			t.Fatal("valid scalar/literal-backslash native identity rejected")
		}
		command, err := ParseCommand(nativeCatalogFrame(raw))
		if err != nil || command.Catalog == nil {
			t.Fatal("valid native catalog rejected by framing")
		}
		encoded, err := json.Marshal(request)
		if err != nil {
			t.Fatal("valid request could not encode")
		}
		roundTrip, ok := parseCatalog(encoded)
		if !ok || len(roundTrip.Filters) != len(request.Filters) || roundTrip.Filters[0].Column != request.Filters[0].Column {
			t.Fatal("valid native identifier bytes changed")
		}
	}
	for _, key := range []string{"requestId", "sessionId", "queryId"} {
		raw := string(nativeCatalogFrame(fixture.ValidCatalogJSON[0]))
		old := map[string]string{"requestId": "r", "sessionId": "s", "queryId": "q"}[key]
		raw = strings.Replace(raw, `"`+key+`":"`+old+`"`, `"`+key+`":"\ud800"`, 1)
		_, err := ParseCommand([]byte(raw))
		if err == nil {
			t.Fatal("malformed outer native request identifier rewritten")
		}
		failure, ok := err.(*ProtocolError)
		if !ok || failure.RequestID != "" || failure.SessionID != "" || failure.QueryID != "" {
			t.Fatal("rewritten malformed identifier retained in protocol failure")
		}
	}
}
func TestNativeFilterWholeCatalogBudgetRejectsLegacyListsBeforeMetadata(t *testing.T) {
	for _, test := range readNativeRequestFixture(t).AggregateBudgets {
		fill := "x"
		if test.Escaped {
			fill = "\x00"
		}
		filter := nativeFilterWith(strings.Repeat(fill, test.PayloadBytes))
		request := CatalogRequest{Kind: "browse", Schema: "main", Object: "typed", ObjectKind: "table"}
		if test.Representation == "filters" {
			for i := 0; i < test.Copies; i++ {
				request.Filters = append(request.Filters, filter)
			}
		} else {
			expression := &CatalogFilterExpression{Kind: "and"}
			for i := 0; i < test.Copies; i++ {
				copy := filter
				expression.Children = append(expression.Children, CatalogFilterExpression{Kind: "condition", Condition: &copy})
			}
			request.FilterExpression = expression
		}
		if request.Valid() != test.Valid {
			t.Fatal("direct native request aggregate budget mismatch")
		}
		_, effective := request.EffectiveFilterExpression()
		if effective != test.Valid {
			t.Fatal("native request disagreed with normalized expression validity")
		}
		encoded, err := json.Marshal(request)
		if err != nil {
			t.Fatal("fixture encoding failed")
		}
		_, accepted := parseCatalog(encoded)
		if accepted != test.Valid {
			t.Fatal("wire native request aggregate budget bypassed validation")
		}
		_, err = ParseCommand(nativeCatalogFrame(string(encoded)))
		if (err == nil) != test.Valid {
			t.Fatal("native request reached dispatch despite aggregate budget")
		}
	}
}
