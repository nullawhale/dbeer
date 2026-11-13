package mysql

import (
	"context"
	"encoding/json"
	"fmt"
	"reflect"
	"strings"
	"testing"

	"dbeer/helper/internal/protocol"
	wire "github.com/go-mysql-org/go-mysql/mysql"
)

func TestNativeTimestampPolicyIsCanonicalUTCAndRejectsAmbiguity(t *testing.T) {
	for _, test := range []struct{ value, typ, want string }{
		{"2020-01-02 03:04:05", "TIMESTAMP", "2020-01-02 03:04:05.000000"},
		{"2020-01-02 03:04:05.12345", "DATETIME(6)", "2020-01-02 03:04:05.123450"},
		{"2020-01-02 03:04:05", "TIMESTAMP(0)", "2020-01-02 03:04:05.000000"},
	} {
		filter := nativeMyFilter("instant", "text", test.value, "mysql", test.typ)
		value, err := nativeTimestampValue(*filter.NativeValue)
		if err != nil || value != test.want {
			t.Fatal("native UTC timestamp changed date, precision, or zero sentinel")
		}
		request := protocol.CatalogRequest{Schema: "fixture", Object: "typed", Filters: []protocol.CatalogFilter{filter}}
		plan, err := buildBrowsePlanWithCharsets(request, map[string]string{"instant": "timestamp"}, nil, nil, []string{"instant"})
		if err != nil || !strings.Contains(plan.statement, nativeTimestampProjection("instant")+" = CAST(CONVERT(? USING utf8mb4) AS DATETIME(6))") || !strings.Contains(plan.sourceSQL, "AT TIME ZONE '+00:00'") || !strings.Contains(plan.sourceSQL, "AS DATETIME(6))") {
			t.Fatal("native timestamp predicate did not compare canonical UTC datetime values")
		}
		if len(plan.args) != 1 {
			t.Fatal("native timestamp lost its bound operand")
		}
		parameter, ok := plan.args[0].(wire.TypedBytes)
		if !ok || parameter.Type != wire.MYSQL_TYPE_BLOB || string(parameter.Bytes) != test.want {
			t.Fatal("native timestamp changed bound UTC bytes")
		}
	}
	for _, test := range []struct{ value, engine, typ string }{
		{"2020-01-02 03:04:05", "postgresql", "timestamp without time zone"},
		{"2020-01-02 03:04:05", "mysql", "varchar(30)"},
		{"2020-01-02 03:04:05", "mysql", "DATETIME(7)"},
		{"2020-01-02 03:04:05.1234567", "mysql", "TIMESTAMP(6)"},
		{"2020-01-02T03:04:05Z", "mysql", "TIMESTAMP"},
		{"2020-01-02 03:04:05+03:00", "mysql", "TIMESTAMP"},
		{"2021-02-29 03:04:05", "mysql", "DATETIME"},
		{"2020-00-00 00:00:00", "mysql", "TIMESTAMP"},
		{"0000-00-00 00:00:00", "mysql", "TIMESTAMP"},
	} {
		filter := nativeMyFilter("instant", "text", test.value, test.engine, test.typ)
		if _, err := nativeTimestampValue(*filter.NativeValue); err == nil {
			t.Fatal("ambiguous or lossy temporal source was guessed")
		}
	}
}

func TestNativeInvalidFilterListRejectsBeforeMetadata(t *testing.T) {
	value := strings.Repeat("x", protocol.NativeCellFilterValueLimit)
	filter := nativeMyFilter("v", "text", value, "postgresql", "text")
	request := protocol.CatalogRequest{Kind: "browse", Schema: "native_é", Object: "typed_é", ObjectKind: "table", Filters: []protocol.CatalogFilter{filter, filter, filter, filter}}
	if _, valid := request.EffectiveFilterExpression(); valid {
		t.Fatal("overflow fixture did not exceed total native budget")
	}
	session := &Session{} // Any metadata/charset/transport access would panic.
	var notice, source string
	if err := session.catalogSelect(nil, nil, request, &notice, &source); err == nil || err.Error() != "Invalid MySQL filter expression." || source != "" {
		t.Fatal("invalid native list reached native or legacy metadata")
	}
}

func TestMySQLNativeCellFiltersLiveTimestampUTC(t *testing.T) {
	s := integrationSession(t)
	schema := integrationSettings(t).Database
	name := fmt.Sprintf("native_timestamp_%x", s.connectionID)
	qualified := QuoteIdentifier(schema) + "." + QuoteIdentifier(name)
	t.Cleanup(func() {
		s.Execute(context.Background(), protocol.Command{SQL: "SET time_zone='+00:00',sql_mode=DEFAULT"})
		s.Execute(context.Background(), protocol.Command{SQL: "DROP TABLE IF EXISTS " + qualified})
	})
	run(t, s, "SET time_zone='+00:00',sql_mode=''")
	run(t, s, "CREATE TABLE "+qualified+"(id INT PRIMARY KEY,instant TIMESTAMP(6) NULL,coarse TIMESTAMP NULL) ENGINE=InnoDB")
	run(t, s, "INSERT INTO "+qualified+" VALUES(1,'2020-01-02 03:04:05','2020-01-02 03:04:05'),(2,'2020-01-02 00:04:05',NULL),(3,'2020-01-02 03:04:05.123456',NULL),(4,'0000-00-00 00:00:00','0000-00-00 00:00:00'),(5,NULL,NULL)")
	stored, err := s.work.client.Execute("SELECT MICROSECOND(instant) FROM " + qualified + " WHERE id=3")
	if err != nil {
		t.Fatal("fractional timestamp storage control failed")
	}
	micros, _ := stored.GetInt(0, 0)
	stored.Close()
	if micros != 123456 {
		t.Fatal("owned fractional timestamp was not stored exactly")
	}
	browse := protocol.CatalogRequest{Kind: "browse", Schema: schema, Object: name, ObjectKind: "table"}
	captured := catalogRequest(t, s, browse)
	if len(captured.Rows) != 5 || captured.Rows[0][1] == nil || *captured.Rows[0][1] != "2020-01-02 03:04:05.000000" || captured.Rows[2][1] == nil || *captured.Rows[2][1] != "2020-01-02 03:04:05.123456" {
		t.Fatal("canonical UTC fixture capture failed")
	}
	run(t, s, "SET time_zone='+03:00',sql_mode='STRICT_TRANS_TABLES,NO_ZERO_DATE,NO_ZERO_IN_DATE'")
	before := nativeTemporalSettings(t, s)
	for index, test := range []struct{ column, value, sourceType, id string }{
		{"instant", *captured.Rows[0][1], "TIMESTAMP(6)", "1"},
		{"instant", *captured.Rows[0][1], "DATETIME", "1"},
		{"instant", *captured.Rows[2][1], "TIMESTAMP(6)", "3"},
		{"coarse", *captured.Rows[0][2], "TIMESTAMP(0)", "1"},
	} {
		request := browse
		request.Filters = []protocol.CatalogFilter{nativeMyFilter(test.column, "text", test.value, "mysql", test.sourceType)}
		frame, err := json.Marshal(map[string]any{"type": "catalog", "requestId": "catalog-r", "sessionId": "catalog-s", "queryId": "catalog-q", "catalog": request})
		if err != nil {
			t.Fatal("native temporal raw fixture encoding failed")
		}
		command, err := protocol.ParseCommand(frame)
		if err != nil {
			t.Fatal("native temporal raw catalog request rejected")
		}
		result := s.Execute(context.Background(), command)
		if result.Type != "query.result" {
			t.Fatal("native temporal raw catalog request failed")
		}
		if len(result.Rows) != 1 || *result.Rows[0][0] != test.id {
			t.Fatalf("native TIMESTAMP changed canonical instant in case %d", index)
		}

		if replay := run(t, s, result.SQL); !reflect.DeepEqual(replay.Rows, result.Rows) {
			t.Fatal("native TIMESTAMP source SQL replay changed the UTC instant")
		}
		if nativeTemporalSettings(t, s) != before {
			t.Fatal("native TIMESTAMP filtering changed session timezone or SQL mode")
		}
	}
	for _, filter := range []protocol.CatalogFilter{
		nativeMyFilter("instant", "text", *captured.Rows[0][1], "postgresql", "timestamp without time zone"),
		nativeMyFilter("instant", "text", *captured.Rows[0][1], "mysql", "varchar(26)"),
		nativeMyFilter("instant", "text", *captured.Rows[3][1], "mysql", "TIMESTAMP(6)"),
		nativeMyFilter("coarse", "text", *captured.Rows[3][2], "mysql", "TIMESTAMP(0)"),
	} {
		request := browse
		request.Filters = []protocol.CatalogFilter{filter}
		rejected := s.Execute(context.Background(), protocol.Command{Type: "catalog", Catalog: &request})
		if rejected.Type != "error" || rejected.Category != "validation" || len(rejected.Rows) != 0 || rejected.SQL != "" {
			t.Fatal("unknown temporal semantics were silently reinterpreted")
		}
	}
	if nativeTemporalSettings(t, s) != before {
		t.Fatal("temporal rejection changed session settings")
	}
}

func nativeTemporalSettings(t *testing.T, s *Session) [2]string {
	t.Helper()
	result, err := s.work.client.Execute(`SELECT @@time_zone,@@sql_mode`)
	if err != nil {
		t.Fatal("synthetic temporal session settings unavailable")
	}
	defer result.Close()
	var settings [2]string
	for i := range settings {
		value, err := result.GetString(0, i)
		if err != nil {
			t.Fatal("synthetic temporal settings undecodable")
		}
		settings[i] = strings.Clone(value)
	}
	return settings
}

func TestMySQLNativeCellFiltersLiveInvalidListBeforeMetadata(t *testing.T) {
	session := integrationSession(t)
	t.Cleanup(func() { session.Execute(context.Background(), protocol.Command{SQL: "SET NAMES utf8mb4"}) })
	run(t, session, "SET NAMES latin1")
	before := nativeCharsetSettings(t, session)
	filter := nativeMyFilter("v", "text", strings.Repeat("x", protocol.NativeCellFilterValueLimit), "postgresql", "text")
	request := protocol.CatalogRequest{Kind: "browse", Schema: "missing_native_é", Object: "typed_é", ObjectKind: "table", Filters: []protocol.CatalogFilter{filter, filter, filter, filter}}
	raw, err := json.Marshal(map[string]any{"type": "catalog", "requestId": "native-overflow-r", "sessionId": "native-overflow-s", "queryId": "native-overflow-q", "catalog": request})
	if err != nil {
		t.Fatal("native budget wire fixture encoding failed")
	}
	if _, err := protocol.ParseCommand(raw); err == nil {
		t.Fatal("raw over-budget native list bypassed protocol validation")
	}
	sink := &nativeEncodingSink{}
	rejected := session.ExecuteWithSink(context.Background(), protocol.Command{Type: "catalog", Catalog: &request}, sink)
	if rejected.Type != "error" || rejected.Category != "validation" || (rejected.Message != "Invalid MySQL catalog request." && rejected.Message != "Invalid MySQL filter expression.") || len(rejected.Rows) != 0 || len(rejected.Columns) != 0 || rejected.SQL != "" || sink.calls != 0 {
		t.Fatal("over-budget native list reached encoding, target metadata, or output")
	}
	if nativeCharsetSettings(t, session) != before {
		t.Fatal("invalid native list changed source encoding settings")
	}
}
