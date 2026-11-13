package sqlite

import (
	"context"
	"testing"

	"dbeer/helper/internal/protocol"
)

func TestSQLiteCellFiltersBindLoadedStorageValues(t *testing.T) {
	s, _ := openCore(t, false)
	runCore(t, s, `CREATE TABLE typed(id INTEGER PRIMARY KEY, v)`)
	runCore(t, s, `INSERT INTO typed VALUES (1,9223372036854775807),(2,1.5),(3,'1.5'),(4,X'00ff80'),(5,CAST(X'610062' AS TEXT)),(6,NULL),(7,X'')`)
	for _, test := range []struct {
		value protocol.SQLiteValue
		id    string
	}{
		{protocol.SQLiteValue{Type: "integer", Value: "9223372036854775807"}, "1"},
		{protocol.SQLiteValue{Type: "real", Value: "3ff8000000000000"}, "2"},
		{protocol.SQLiteValue{Type: "text", Value: "MS41"}, "3"},
		{protocol.SQLiteValue{Type: "blob", Value: "AP+A"}, "4"},
		{protocol.SQLiteValue{Type: "text", Value: "YQBi"}, "5"},
		{protocol.SQLiteValue{Type: "blob"}, "7"},
	} {
		request := protocol.CatalogRequest{Kind: "browse", Schema: "main", Object: "typed", ObjectKind: "table", FilterExpression: &protocol.CatalogFilterExpression{Kind: "condition", Condition: &protocol.CatalogFilter{Column: "v", Operator: "eq", SQLiteValue: &test.value}}}
		r := s.Execute(context.Background(), protocol.Command{Type: "catalog", RequestID: "r", SessionID: "s", QueryID: "q", Catalog: &request})
		if r.Type != "query.result" || len(r.SQLiteValues) != 1 || r.SQLiteValues[0][0].Value != test.id {
			t.Fatalf("typed operand %s did not match its stored value", test.value.Type)
		}
	}
}
