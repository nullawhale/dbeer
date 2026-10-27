package session

import (
	"context"
	"testing"

	"dbeer/helper/internal/protocol"
)

func TestStreamSourceSurvivesOnlyWithItsCompletedColumns(t *testing.T) {
	source := &protocol.ResultSource{Schema: "demo", Table: "items", Columns: []protocol.ResultSourceColumn{{Name: "id", NativeType: "integer", PrimaryKey: 1, TableIndex: 0, Editable: true}}}
	columns := []protocol.Column{{Index: 0, Name: "id", Engine: "postgresql", NativeType: "int4"}}
	for _, test := range []struct {
		name    string
		columns []protocol.Column
		used    int
		retain  bool
	}{
		{"completed", columns, 1024, true}, {"columns omitted", nil, 1024, false}, {"budget exhausted", columns, displayBytes, false},
	} {
		t.Run(test.name, func(t *testing.T) {
			sink := &streamSink{ctx: context.Background(), sets: []*streamSet{{columns: test.columns, sent: 1, seen: 1}}, bytes: test.used}
			summary := protocol.ResultSet{Columns: columns, Rows: [][]*string{}, RowCount: 1, DisplayedRowCount: 1, Source: source}
			if err := sink.End(0, summary); err != nil {
				t.Fatal(err)
			}
			response := sink.finish(protocol.Response{Type: "query.result", Source: source})
			if !response.Streamed || len(response.ResultSets) != 1 || (response.Source != nil) != test.retain || (response.ResultSets[0].Source != nil) != test.retain {
				t.Fatal("stream exposed source without its matching completed columns and budget")
			}
		})
	}
}
