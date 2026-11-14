package mysql

import (
	"context"
	"encoding/hex"
	"fmt"
	"os"
	"reflect"
	"strings"
	"testing"

	"dbeer/helper/internal/protocol"
	wire "github.com/go-mysql-org/go-mysql/mysql"
)

func nativeMyFilter(column, kind, value, engine, native string) protocol.CatalogFilter {
	return protocol.CatalogFilter{Column: column, Operator: "eq", NativeValue: &protocol.NativeCellFilterValue{Cell: protocol.CellValue{Kind: kind, Value: &value}, SourceEngine: engine, SourceType: native, SQLiteStorage: "text"}}
}

func TestMySQLNativeCellFilterPlanKeepsTypesAndBoundOperands(t *testing.T) {
	request := protocol.CatalogRequest{Schema: "demo", Object: "typed", Filters: []protocol.CatalogFilter{
		nativeMyFilter("n", "text", "9007199254740993.000000000000000001", "postgresql", "numeric(40,20)"),
		nativeMyFilter("b", "binary", "AP8=", "mysql", "varbinary(2)"),
		nativeMyFilter("txt", "text", "é e\u0301 NULL", "postgresql", "untrusted'); SELECT --"),
	}}
	actual := map[string]string{"n": "decimal", "b": "varbinary", "txt": "text"}
	plan, err := buildBrowsePlanWithCharsets(request, actual, nil, map[string]string{"txt": "utf8mb4"})
	if err != nil || !strings.Contains(plan.statement, "`n` = CAST(? AS DECIMAL(65,18)) AND `b` = ? AND `txt` = CONVERT(? USING utf8mb4)") || strings.Contains(plan.sourceSQL, "untrusted") {
		t.Fatal("native filter did not use trusted metadata and bound operands")
	}
	want := []any{"9007199254740993.000000000000000001", wire.TypedBytes{Type: wire.MYSQL_TYPE_BLOB, Bytes: []byte{0, 255}}, wire.TypedBytes{Type: wire.MYSQL_TYPE_BLOB, Bytes: []byte("é e\u0301 NULL")}}
	if !reflect.DeepEqual(plan.args, want) {
		t.Fatal("native filter changed exact numeric, binary, or text bytes")
	}
	for _, test := range []struct {
		filter        protocol.CatalogFilter
		kind, charset string
	}{
		{nativeMyFilter("v", "text", "AP8=", "postgresql", "text"), "varbinary", ""},
		{nativeMyFilter("v", "binary", "AP8=", "mysql", "blob"), "text", "utf8mb4"},
		{nativeMyFilter("v", "sqliteText", "/w==", "sqlite", "ANY"), "text", "utf8mb4"},
		{nativeMyFilter("v", "sqliteReal", "3fb999999999999a", "sqlite", "ANY"), "decimal", ""},
		{nativeMyFilter("v", "text", "0.1", "postgresql", "numeric"), "double", ""},
		{nativeMyFilter("v", "text", "1e999999999", "postgresql", "numeric"), "decimal", ""},
		{nativeMyFilter("v", "text", "🌍", "postgresql", "text"), "text", "utf8mb3"},
		{nativeMyFilter("v", "text", "é", "postgresql", "text"), "text", "ascii"},
		{nativeMyFilter("v", "text", "🌍", "postgresql", "text"), "text", "latin1"},
		{nativeMyFilter("v", "text", "x", "postgresql", "text"), "text", "unknown"},
	} {
		request.Filters = []protocol.CatalogFilter{test.filter}
		if _, err := buildBrowsePlanWithCharsets(request, map[string]string{"v": test.kind}, nil, map[string]string{"v": test.charset}); err == nil {
			t.Fatal("lossy or mismatched native operand reached query execution")
		}
	}
	for _, test := range []struct{ charset, value string }{{"latin1", "é €"}, {"ascii", "NULL"}, {"utf8mb3", "é e\u0301"}, {"utf8mb4", "🌍"}} {
		if err := nativeBrowseTextCharset("text", test.charset, test.value); err != nil {
			t.Fatal("representable native text rejected")
		}
	}
}

func TestMySQLNativeCellFiltersLive(t *testing.T) {
	session := integrationSession(t)
	schema := integrationSettings(t).Database
	name := fmt.Sprintf("dbeer_native_filters_%x", session.connectionID)
	qualified := QuoteIdentifier(schema) + "." + QuoteIdentifier(name)
	t.Cleanup(func() {
		session.Execute(context.Background(), protocol.Command{SQL: "SET NAMES utf8mb4"})
		session.Execute(context.Background(), protocol.Command{SQL: "DROP TABLE IF EXISTS " + qualified})
	})
	run(t, session, "CREATE TABLE "+qualified+" (id int PRIMARY KEY,n decimal(40,20),txt text CHARACTER SET utf8mb4,b varbinary(2)) ENGINE=InnoDB")
	run(t, session, "INSERT INTO "+qualified+" VALUES (1,9007199254740993.000000000000000001,'',X'00ff'),(2,0,'NULL',X'00ff'),(3,0,CONVERT(X'c3a9' USING utf8mb4),X'01'),(4,0,CONVERT(X'610062' USING utf8mb4),X'01')")
	leaf := func(f protocol.CatalogFilter) protocol.CatalogFilterExpression {
		return protocol.CatalogFilterExpression{Kind: "condition", Condition: &f}
	}
	expr := protocol.CatalogFilterExpression{Kind: "and", Children: []protocol.CatalogFilterExpression{
		{Kind: "or", Children: []protocol.CatalogFilterExpression{leaf(nativeMyFilter("n", "text", "9007199254740993.000000000000000001", "postgresql", "numeric(40,20)")), leaf(nativeMyFilter("txt", "text", "NULL", "postgresql", "text"))}},
		leaf(nativeMyFilter("b", "binary", "AP8=", "postgresql", "bytea")),
	}}
	request := protocol.CatalogRequest{Kind: "browse", Schema: schema, Object: name, ObjectKind: "table", FilterExpression: &expr}
	response := catalogRequest(t, session, request)
	if len(response.Rows) != 2 || *response.Rows[0][0] != "1" || *response.Rows[1][0] != "2" {
		t.Fatal("native grouped filters changed exact numeric or binary comparison")
	}
	if rerun := run(t, session, response.SQL); response.SQL == "" || !reflect.DeepEqual(response.Rows, rerun.Rows) {
		t.Fatal("native filter source SQL changed returned rows")
	}
	request.FilterExpression = nil
	for _, f := range []protocol.CatalogFilter{nativeMyFilter("txt", "text", "", "mysql", "varchar(10)"), nativeMyFilter("n", "text", "9007199254740993.000000000000000001", "postgresql", "numeric(40,20)")} {
		request.Filters = []protocol.CatalogFilter{f}
		response = catalogRequest(t, session, request)
		if len(response.Rows) != 1 || *response.Rows[0][0] != "1" {
			t.Fatal("native exact/empty operand matched incorrectly")
		}
	}
	request.Filters = []protocol.CatalogFilter{nativeMyFilter("txt", "text", "a\x00b", "mysql", "varchar(10)")}
	response = catalogRequest(t, session, request)
	if len(response.Rows) != 1 || *response.Rows[0][0] != "4" {
		t.Fatal("native text NUL bytes changed")
	}
	if rerun := run(t, session, response.SQL); !reflect.DeepEqual(response.Rows, rerun.Rows) {
		t.Fatal("native text NUL source SQL changed returned rows")
	}
	run(t, session, "SET NAMES latin1")
	before := nativeCharsetSettings(t, session)
	if before != [3]string{"latin1", "latin1", "latin1"} {
		t.Fatal("synthetic session charset change did not reach the server")
	}
	// The driver encodes []byte as MYSQL_TYPE_STRING. The server therefore
	// interprets those bytes through latin1 before the UTF8 CONVERT. A BLOB
	// wire parameter must retain the original octets until that conversion.
	// CHARSET(?) reports the inferred prepared expression charset (latin1)
	// for both values; it does not reveal their transport representation.
	probe, err := session.work.client.Execute(`SELECT HEX(CONVERT(? USING utf8mb4)),HEX(CONVERT(? USING utf8mb4)),CHARSET(?),CHARSET(?)`,
		[]byte("é"), wire.TypedBytes{Type: wire.MYSQL_TYPE_BLOB, Bytes: []byte("é")},
		[]byte("é"), wire.TypedBytes{Type: wire.MYSQL_TYPE_BLOB, Bytes: []byte("é")})
	if err != nil {
		t.Fatal("synthetic wire charset probe failed")
	}
	ordinary, _ := probe.GetString(0, 0)
	binary, _ := probe.GetString(0, 1)
	ordinaryCharset, _ := probe.GetString(0, 2)
	binaryCharset, _ := probe.GetString(0, 3)
	if ordinary != "C383C2A9" || binary != "C3A9" || ordinaryCharset != "latin1" || binaryCharset != "latin1" {
		probe.Close()
		t.Fatal("server changed native parameter octets or prepared expression charset semantics")
	}
	probe.Close()
	// A BLOB operand protects its value, but latin1 still cannot retain
	// Unicode SQL identifiers and result text. Reject the whole browse before
	// resolving a target or returning rows; do not repair the user's session.
	for _, filter := range []protocol.CatalogFilter{
		nativeMyFilter("txt", "text", "é", "postgresql", "text"),
		nativeMyFilter("b", "binary", "AP8=", "postgresql", "bytea"),
	} {
		request.Filters = []protocol.CatalogFilter{filter}
		nativeEncodingRejected(t, session, request)
		if after := nativeCharsetSettings(t, session); after != before {
			t.Fatal("native browse changed source session charset settings")
		}
	}
	run(t, session, "SET NAMES utf8mb4")
	if count := run(t, session, "SELECT count(*) FROM "+qualified); len(count.Rows) != 1 || *count.Rows[0][0] != "4" {
		t.Fatal("native browse mutated fixture")
	}
}

// Read settings through the actual server session. Clone values before closing
// the pooled result buffer; no connection configuration is changed here.
func nativeCharsetSettings(t *testing.T, session *Session) [3]string {
	t.Helper()
	result, err := session.work.client.Execute(`SELECT @@character_set_client,@@character_set_connection,@@character_set_results`)
	if err != nil {
		t.Fatal("synthetic session charset settings unavailable")
	}
	defer result.Close()
	var settings [3]string
	for index := range settings {
		value, err := result.GetString(0, index)
		if err != nil {
			t.Fatal("synthetic session charset settings could not be decoded")
		}
		settings[index] = strings.Clone(value)
	}
	return settings
}

func nativeEncodingRejected(t *testing.T, session *Session, request protocol.CatalogRequest) {
	t.Helper()
	sink := &nativeEncodingSink{}
	response := session.ExecuteWithSink(context.Background(), protocol.Command{Type: "catalog", Catalog: &request}, sink)
	if sink.calls != 0 {
		t.Fatal("unsafe native browse streamed metadata or values")
	}
	if response.Type != "error" || response.Category != "validation" || response.Message != nativeBrowseEncodingMessage || len(response.Rows) != 0 || len(response.Columns) != 0 || response.SQL != "" {
		t.Fatal("unsafe native browse did not reject before target lookup and output")
	}
}

// Only the opt-in disposable runner creates these two owned schemas. MySQL
// identifiers are BMP-only; supplementary Unicode is exercised in text values.
func TestMySQLNativeCellFiltersLiveUnicodeIdentifiers(t *testing.T) {
	schema, shadowSchema := os.Getenv("DBEER_TEST_MYSQL_NATIVE_SCHEMA"), os.Getenv("DBEER_TEST_MYSQL_NATIVE_SHADOW_SCHEMA")
	if schema == "" || shadowSchema == "" {
		t.Skip("disposable Unicode native filter fixture required")
	}
	session := integrationSession(t)
	table := fmt.Sprintf("native_é_%x", session.connectionID)
	shadowTable := strings.ReplaceAll(table, "é", "Ã©")
	column, payloadColumn := "clé", "résultat"
	shadowColumn, shadowPayloadColumn := "clÃ©", "rÃ©sultat"
	target := QuoteIdentifier(schema) + "." + QuoteIdentifier(table)
	shadow := QuoteIdentifier(shadowSchema) + "." + QuoteIdentifier(shadowTable)
	t.Cleanup(func() {
		session.Execute(context.Background(), protocol.Command{SQL: "SET NAMES utf8mb4"})
		session.Execute(context.Background(), protocol.Command{SQL: "DROP TABLE IF EXISTS " + target})
		session.Execute(context.Background(), protocol.Command{SQL: "DROP TABLE IF EXISTS " + shadow})
	})
	run(t, session, "CREATE TABLE "+target+" (id INT PRIMARY KEY,"+QuoteIdentifier(column)+" TEXT,"+QuoteIdentifier(payloadColumn)+" TEXT) ENGINE=InnoDB DEFAULT CHARACTER SET utf8mb4 COLLATE utf8mb4_bin")
	run(t, session, "CREATE TABLE "+shadow+" (id INT PRIMARY KEY,"+QuoteIdentifier(shadowColumn)+" TEXT,"+QuoteIdentifier(shadowPayloadColumn)+" TEXT) ENGINE=InnoDB DEFAULT CHARACTER SET utf8mb4 COLLATE utf8mb4_bin")
	original := "é e\u0301 🌍 a\x00b"
	encoded := hex.EncodeToString([]byte(original))
	run(t, session, "INSERT INTO "+target+" VALUES(1,CONVERT(X'c3a9' USING utf8mb4),CONVERT(X'"+encoded+"' USING utf8mb4))")
	run(t, session, "INSERT INTO "+shadow+" VALUES(1,CONVERT(X'c3a9' USING utf8mb4),'wrong-target')")
	request := protocol.CatalogRequest{Kind: "browse", Schema: schema, Object: table, ObjectKind: "table", Filters: []protocol.CatalogFilter{nativeMyFilter(column, "text", "é", "postgresql", "text")}}
	response := catalogRequest(t, session, request)
	if len(response.Rows) != 1 || len(response.Rows[0]) != 3 || *response.Rows[0][2] != original || len(response.Columns) != 3 || response.Columns[1].Name != column || response.Columns[2].Name != payloadColumn {
		t.Fatal("native browse changed Unicode object names, metadata, or full text bytes")
	}
	if rerun := run(t, session, response.SQL); !reflect.DeepEqual(response.Rows, rerun.Rows) {
		t.Fatal("Unicode native source SQL changed objects or values")
	}
	for _, setting := range []string{
		"SET character_set_client=latin1",
		"SET character_set_connection=latin1",
		"SET character_set_results=latin1",
		"SET character_set_client=utf8mb3",
		"SET character_set_connection=utf8mb3",
		"SET character_set_results=utf8mb3",
		"SET character_set_results=NULL",
		"SET NAMES latin1",
	} {
		run(t, session, "SET NAMES utf8mb4")
		run(t, session, setting)
		before := nativeCharsetSettings(t, session)
		nativeEncodingRejected(t, session, request)
		missing := request
		missing.Schema += "_missing_é"
		nativeEncodingRejected(t, session, missing)
		if after := nativeCharsetSettings(t, session); after != before {
			t.Fatal("native Unicode rejection changed source session settings")
		}
	}
	run(t, session, "SET NAMES utf8mb4")
	restored := catalogRequest(t, session, request)
	if !reflect.DeepEqual(response.Rows, restored.Rows) {
		t.Fatal("native Unicode guard changed stored values or source settings")
	}
}

type nativeEncodingSink struct{ calls int }

func (s *nativeEncodingSink) Begin(int, []protocol.Column) error { s.calls++; return nil }
func (s *nativeEncodingSink) Row(int, []*string) error           { s.calls++; return nil }
func (s *nativeEncodingSink) End(int, protocol.ResultSet) error  { s.calls++; return nil }

func TestNativeBrowseMetadataQueriesKeepCaseModesAndExactNames(t *testing.T) {
	exact, err := nativeBrowseTargetSQL(0)
	if err != nil || strings.Contains(exact, "LOWER(") || !strings.Contains(exact, "BINARY TABLE_SCHEMA=BINARY ?") || !strings.Contains(exact, "BINARY TABLE_NAME=BINARY ?") {
		t.Fatal("case-sensitive server did not retain exact identities")
	}
	for _, mode := range []int64{1, 2} {
		query, err := nativeBrowseTargetSQL(mode)
		if err != nil || !strings.Contains(query, "BINARY LOWER(TABLE_SCHEMA)=BINARY LOWER(?)") || !strings.Contains(query, "BINARY LOWER(TABLE_NAME)=BINARY LOWER(?)") {
			t.Fatal("server case aliases could fold accents or lose canonical names")
		}
	}
	if _, err := nativeBrowseTargetSQL(3); err == nil {
		t.Fatal("unknown server case semantics guessed")
	}
	for _, query := range []string{nativePrimaryKeyQuery, nativeBrowseColumnsQuery} {
		if !strings.Contains(query, "BINARY TABLE_SCHEMA=BINARY ?") || !strings.Contains(query, "BINARY TABLE_NAME=BINARY ?") {
			t.Fatal("native target metadata could mix collation-equivalent objects")
		}
	}
}

func TestMySQLNativeCellFiltersLiveMetadataIdentity(t *testing.T) {
	schema, accentSchema := os.Getenv("DBEER_TEST_MYSQL_NATIVE_SCHEMA"), os.Getenv("DBEER_TEST_MYSQL_NATIVE_ACCENT_SCHEMA")
	if schema == "" || accentSchema == "" {
		t.Skip("disposable native metadata identity fixture required")
	}
	session := integrationSession(t)
	modeResult, err := session.work.client.Execute(`SELECT @@lower_case_table_names`)
	if err != nil {
		t.Fatal("server case mode unavailable")
	}
	mode, err := modeResult.GetInt(0, 0)
	modeResult.Close()
	if err != nil {
		t.Fatal("server case mode undecodable")
	}
	suffix := fmt.Sprintf("_%x", session.connectionID)
	type object struct{ schema, table, key, kind, value, id string }
	pairs := []struct {
		name    string
		objects [2]object
	}{
		{"accent_table", [2]object{{schema, "identity_e" + suffix, "text_id", "text", "AP8=", "11"}, {schema, "identity_é" + suffix, "binary_id", "binary", "AP8=", "22"}}},
		{"accent_schema", [2]object{{schema, "identity_schema" + suffix, "text_id", "text", "AP8=", "11"}, {accentSchema, "identity_schema" + suffix, "binary_id", "binary", "AP8=", "22"}}},
	}
	if mode == 0 {
		pairs = append(pairs, struct {
			name    string
			objects [2]object
		}{"case_table", [2]object{{schema, "identity_Case" + suffix, "text_id", "text", "AP8=", "11"}, {schema, "identity_case" + suffix, "binary_id", "binary", "AP8=", "22"}}})
	}
	for _, pair := range pairs {
		t.Run(pair.name, func(t *testing.T) {
			for _, obj := range pair.objects {
				qualified := QuoteIdentifier(obj.schema) + "." + QuoteIdentifier(obj.table)
				t.Cleanup(func() {
					session.Execute(context.Background(), protocol.Command{SQL: "DROP TABLE IF EXISTS " + qualified})
				})
				typ, literal := "TEXT", "'AP8='"
				if obj.kind == "binary" {
					typ, literal = "VARBINARY(4)", "X'00ff'"
				}
				run(t, session, "CREATE TABLE "+qualified+"("+QuoteIdentifier(obj.key)+" INT PRIMARY KEY,v "+typ+") ENGINE=InnoDB DEFAULT CHARACTER SET utf8mb4")
				run(t, session, "INSERT INTO "+qualified+" VALUES("+obj.id+","+literal+")")
			}
			for _, obj := range pair.objects {
				filter := nativeMyFilter("v", obj.kind, obj.value, "postgresql", "text")
				request := protocol.CatalogRequest{Kind: "browse", Schema: obj.schema, Object: obj.table, ObjectKind: "table", Filters: []protocol.CatalogFilter{filter}}
				response := catalogRequest(t, session, request)
				if len(response.Rows) != 1 || *response.Rows[0][0] != obj.id || len(response.Columns) != 2 || response.Columns[0].Name != obj.key || !strings.Contains(response.SQL, "ORDER BY "+QuoteIdentifier(obj.key)) {
					t.Fatal("native metadata mixed collation-equivalent objects, primary keys, or scalar types")
				}
				legacy := request
				legacy.Filters = []protocol.CatalogFilter{{Column: "v", Operator: "eq", Value: &obj.value}}
				legacyResponse := catalogRequest(t, session, legacy)
				if len(legacyResponse.Rows) != 1 || *legacyResponse.Rows[0][0] != obj.id || legacyResponse.Columns[0].Name != obj.key || !strings.Contains(legacyResponse.SQL, "ORDER BY "+QuoteIdentifier(obj.key)) {
					t.Fatal("legacy scalar browse mixed collation-equivalent object, key, or type metadata")
				}
				columns := catalogRequest(t, session, protocol.CatalogRequest{Kind: "columns", Schema: obj.schema, Object: obj.table, ObjectKind: "table"})
				if len(columns.Rows) != 2 || *columns.Rows[0][0] != obj.key || *columns.Rows[1][0] != "v" {
					t.Fatal("catalog columns merged accent/case-distinct objects")
				}
				alias := request
				alias.Schema = strings.ToUpper(alias.Schema)
				alias.Object = strings.ToUpper(alias.Object)
				if mode == 0 {
					rejected := session.Execute(context.Background(), protocol.Command{Type: "catalog", Catalog: &alias})
					if rejected.Type != "error" || rejected.Category != "validation" || rejected.Message != nativeBrowseIdentityMessage || len(rejected.Rows) != 0 || rejected.SQL != "" {
						t.Fatal("case-sensitive native identity fell back to an alias")
					}
				} else {
					actual := catalogRequest(t, session, alias)
					if !reflect.DeepEqual(actual.Rows, response.Rows) || actual.SQL != response.SQL {
						t.Fatal("legitimate server case alias did not resolve canonically")
					}
				}
				wrong := request
				if obj.kind == "text" {
					wrong.Filters = []protocol.CatalogFilter{nativeMyFilter("v", "binary", "AP8=", "postgresql", "bytea")}
				} else {
					wrong.Filters = []protocol.CatalogFilter{nativeMyFilter("v", "text", "AP8=", "postgresql", "text")}
				}
				rejected := session.Execute(context.Background(), protocol.Command{Type: "catalog", Catalog: &wrong})
				if rejected.Type != "error" || rejected.Category != "validation" || len(rejected.Rows) != 0 || rejected.SQL != "" {
					t.Fatal("native type mismatch used mixed metadata or reached data execution")
				}
			}
		})
	}
}
