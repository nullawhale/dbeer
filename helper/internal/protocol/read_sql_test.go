package protocol

import (
	"encoding/json"
	"reflect"
	"strings"
	"testing"
)

func TestBrowseReadSQLUsesMetadataAndEncodedFrameBudgets(t *testing.T) {
	empty, literalNull := "", "NULL"
	base := Response{Type: "query.result", RequestID: "browse", SessionID: "s", QueryID: "q", TransactionStatus: "idle",
		Columns: []Column{{Index: 0, Name: "nullable"}, {Index: 1, Name: "empty"}, {Index: 2, Name: "literal"}},
		Rows:    [][]*string{{nil, &empty, &literalNull}}, RowCount: 1, DisplayedRowCount: 1, DisplayNotice: "Existing page notice."}
	for _, scenario := range []struct {
		name, sql string
		include   bool
	}{
		{"normal", `SELECT * FROM "public"."records" WHERE "value" = E'NULL' LIMIT 200 OFFSET 400`, true},
		{"native metadata boundary", strings.Repeat("s", MaxFrameBytes/2), true},
		{"native metadata overflow", strings.Repeat("s", MaxFrameBytes/2+1), false},
		{"JSON escape overflow", strings.Repeat("<", MaxFrameBytes/4), false},
	} {
		t.Run(scenario.name, func(t *testing.T) {
			response := base.WithReadSQL(scenario.sql)
			if (response.SQL != "") != scenario.include || !reflect.DeepEqual(response.Rows, base.Rows) || response.Type != base.Type || response.RowCount != base.RowCount {
				t.Fatal("source capture changed row semantics or exceeded the metadata budget")
			}
			encoded, err := json.Marshal(response)
			if err != nil || len(encoded) > MaxFrameBytes {
				t.Fatal("source capture exceeded the encoded frame budget")
			}
			if !scenario.include && (!strings.Contains(response.DisplayNotice, base.DisplayNotice) || !strings.Contains(response.DisplayNotice, "too large to capture")) {
				t.Fatal("omitted source did not retain the page notice and explain the capture limit")
			}
		})
	}
	largeRow := strings.Repeat("r", MaxFrameBytes/2)
	base.Rows = [][]*string{{&largeRow, &empty, &literalNull}}
	response := base.WithReadSQL(strings.Repeat("s", MaxFrameBytes/2))
	if response.SQL != "" || !reflect.DeepEqual(response.Rows, base.Rows) {
		t.Fatal("source and result budgets were checked independently rather than on the complete frame")
	}
	for _, kind := range []string{"error", "query.chunk", "query.started"} {
		if response := (Response{Type: kind}).WithReadSQL("SELECT 1"); response.SQL != "" {
			t.Fatal("source SQL was attached to a non-result frame")
		}
	}
}
