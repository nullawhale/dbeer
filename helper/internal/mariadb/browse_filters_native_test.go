package mariadb

import (
	"context"
	"dbeer/helper/internal/protocol"
	"fmt"
	"reflect"
	"strings"
	"testing"
	"time"
)

func TestMariaDBBrowseFiltersPreserveLiteralAndNativeTypesLive(t *testing.T) {
	s := dataIntegrationSession(t)
	schema := dataIntegrationSettings(t).Database
	name := fmt.Sprintf("g1_filter_%d", time.Now().UnixNano())
	q := QuoteIdentifier(schema) + "." + QuoteIdentifier(name)
	dataRun(t, s, "SET SESSION time_zone='+00:00'")
	dataRun(t, s, "CREATE TABLE "+q+"(id INT PRIMARY KEY,v VARCHAR(50),b VARBINARY(8),n DECIMAL(65,38),stamp TIMESTAMP(6) NULL) ENGINE=InnoDB")
	defer dataRun(t, s, "DROP TABLE IF EXISTS "+q)
	dataRun(t, s, "INSERT INTO "+q+" VALUES(1,'',X'00FF',0.12345678901234567890123456789012345678,'2024-01-02 03:04:05.123456'),(2,'NULL',X'',NULL,NULL),(3,NULL,NULL,0.12345678901234567890123456789012345679,'2024-01-02 04:04:05.123456')")
	dataRun(t, s, "SET SESSION time_zone='+03:00'")
	native := func(kind, value string) *protocol.NativeCellFilterValue {
		return &protocol.NativeCellFilterValue{SourceEngine: "mariadb", SourceType: kind, Cell: protocol.CellValue{Kind: "text", Value: &value}, SQLiteStorage: "preserve"}
	}
	execute := func(filters []protocol.CatalogFilter, tree *protocol.CatalogFilterExpression, want string) {
		t.Helper()
		r := protocol.CatalogRequest{Kind: "browse", Schema: schema, Object: name, ObjectKind: "table", Filters: filters, FilterExpression: tree}
		response := s.catalogBrowse(context.Background(), protocol.Command{Type: "catalog", Catalog: &r})
		if response.Type != "query.result" || len(response.Rows) != 1 || response.Rows[0][0] == nil || *response.Rows[0][0] != want {
			t.Fatalf("native filtered browse disagreed with exact selected row: %s/%s", response.Category, response.SQLState)
		}
		r.Kind = "select"
		source := s.catalogBrowse(context.Background(), protocol.Command{Type: "catalog", Catalog: &r})
		if source.Type != "query.result" || len(source.Rows) != 1 || source.Rows[0][0] == nil {
			t.Fatal("standalone native filter SQL unavailable")
		}
		copied := dataRun(t, s, *source.Rows[0][0])
		if !reflect.DeepEqual(response.Rows, copied.Rows) {
			t.Fatal("executed and standalone native filter predicates differ")
		}
	}
	empty := ""
	raw := "AP8="
	execute([]protocol.CatalogFilter{{Column: "v", Operator: "eq", NativeValue: native("varchar(50)", empty)}}, nil, "1")
	execute([]protocol.CatalogFilter{{Column: "n", Operator: "eq", NativeValue: native("decimal(65,38)", "0.12345678901234567890123456789012345679")}}, nil, "3")
	execute([]protocol.CatalogFilter{{Column: "b", Operator: "eq", Value: &raw}}, nil, "1")
	execute([]protocol.CatalogFilter{{Column: "stamp", Operator: "eq", NativeValue: native("timestamp(6)", "2024-01-02 03:04:05.123456")}}, nil, "1")
	condition := protocol.CatalogFilter{Column: "v", Operator: "isNull"}
	tree := protocol.CatalogFilterExpression{Kind: "or", Children: []protocol.CatalogFilterExpression{{Kind: "condition", Condition: &condition}, {Kind: "condition", Condition: &protocol.CatalogFilter{Column: "n", Operator: "eq", NativeValue: native("decimal(65,38)", "0.12345678901234567890123456789012345679")}}}}
	execute(nil, &tree, "3")
	mode := dataRun(t, s, "SELECT @@SESSION.sql_mode").Rows
	if len(mode) != 1 || mode[0][0] == nil {
		t.Fatal("native mode unavailable")
	}
	text := *mode[0][0]
	if !strings.Contains(text, "EMPTY_STRING_IS_NULL") {
		text += ",EMPTY_STRING_IS_NULL"
	}
	for _, c := range text {
		if !(c >= 'A' && c <= 'Z' || c >= '0' && c <= '9' || c == '_' || c == ',') {
			t.Fatal("unexpected native fixture mode")
		}
	}
	dataRun(t, s, "SET SESSION sql_mode='"+text+"'")
	before := dataRun(t, s, "SELECT @@SESSION.sql_mode,@@SESSION.time_zone").Rows
	execute([]protocol.CatalogFilter{{Column: "v", Operator: "eq", NativeValue: native("varchar(50)", empty)}}, nil, "1")
	if !reflect.DeepEqual(before, dataRun(t, s, "SELECT @@SESSION.sql_mode,@@SESSION.time_zone").Rows) {
		t.Fatal("native filtering changed session state")
	}
}
