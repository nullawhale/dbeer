package postgres

import (
	"context"
	"encoding/json"
	"strconv"
	"testing"

	"dbeer/helper/internal/protocol"
)

func TestPostgresCatalogColumnEntriesLive(t *testing.T) {
	f := newChangeFixture(t)
	f.exec("CREATE DOMAIN " + f.table("custom_text") + " AS text")
	f.exec("CREATE TABLE " + f.table("typed_columns") + ` ("é" text COLLATE "C", "é" bigint, other varchar(30) COLLATE "POSIX", custom ` + f.table("custom_text") + ")")
	request := protocol.CatalogRequest{Kind: "completion", Schema: f.schema}
	response := catalog(context.Background(), f.conn, protocol.Command{Type: "catalog", Catalog: &request})
	indices := map[string]int{}
	for i, column := range response.Columns {
		indices[column.Name] = i
	}
	if response.Type != "query.result" || indices["columnTypeEntries"] == 0 {
		t.Fatal("ordered completion entries unavailable")
	}
	var entries []protocol.CatalogColumnTypeEntry
	for _, row := range response.Rows {
		if *row[indices["name"]] == "typed_columns" && json.Unmarshal([]byte(*row[indices["columnTypeEntries"]]), &entries) != nil {
			t.Fatal("completion entries invalid")
		}
	}
	if len(entries) != 4 || entries[0].Name != "é" || entries[1].Name != "e\u0301" || entries[0].NativeType != "text" || entries[1].NativeType != "bigint" {
		t.Fatal("ordered type entries changed exact column identities")
	}
	left, right, custom := entries[0].Comparison, entries[2].Comparison, entries[3].Comparison
	if left == nil || right == nil || custom == nil || left.Kind != "text" || left.BaseType != "pg_catalog.text" || left.Charset != "UTF8" || left.CollationSchema != "pg_catalog" || left.CollationName != "C" || left.CollationIdentity == "" || left.CollationIdentity == right.CollationIdentity || custom.Kind != "unknown" || custom.BaseType != "pg_catalog.text" {
		t.Fatal("comparison facts invented or discarded native type/collation identity")
	}
	request.Kind, request.Object, request.ObjectKind = "columns", "typed_columns", "table"
	columns := catalog(context.Background(), f.conn, protocol.Command{Type: "catalog", Catalog: &request})
	comparisonIndex := -1
	for i, column := range columns.Columns {
		if column.Name == "comparison" {
			comparisonIndex = i
		}
	}
	if columns.Type != "query.result" || len(columns.Rows) != 4 || comparisonIndex < 0 {
		t.Fatal("column comparison facts missing")
	}
	for i, row := range columns.Rows {
		var fact protocol.CatalogColumnComparison
		if row[comparisonIndex] == nil || json.Unmarshal([]byte(*row[comparisonIndex]), &fact) != nil || fact != *entries[i].Comparison {
			t.Fatal("paged columns and completion comparison facts disagree")
		}
	}
	if _, err := f.conn.Exec(context.Background(), "SET client_encoding=LATIN1"); err != nil || f.conn.PgConn().ParameterStatus("client_encoding") != "LATIN1" {
		t.Fatal("fixture encoding did not reach the tested connection")
	}
	for _, kind := range []string{"columns", "completion"} {
		request.Kind = kind
		if kind == "completion" {
			request.Object, request.ObjectKind = "", ""
		}
		sink := &nativePGEncodingSink{}
		rejected := catalogWithSink(context.Background(), f.conn, protocol.Command{Type: "catalog", Catalog: &request}, sink)
		if rejected.Type != "error" || rejected.Category != "validation" || len(rejected.Rows) != 0 || len(rejected.Columns) != 0 || rejected.SQL != "" || sink.calls != 0 || f.conn.PgConn().ParameterStatus("client_encoding") != "LATIN1" {
			t.Fatal("non-UTF8 metadata read was executed or settings changed")
		}
	}
	if _, err := f.conn.Exec(context.Background(), "SET client_encoding=UTF8"); err != nil {
		t.Fatal("fixture encoding restoration failed")
	}
}

func TestPostgresCatalogCaptureTypeOIDsLive(t *testing.T) {
	f := newChangeFixture(t)
	f.exec("CREATE DOMAIN " + f.table("binary_key") + " AS bytea")
	f.exec("CREATE TABLE " + f.table("captured_types") + " (n numeric, items integer[], payload " + f.table("binary_key") + ")")
	var domainOID uint32
	if f.conn.QueryRow(context.Background(), "SELECT t.oid FROM pg_catalog.pg_type t JOIN pg_catalog.pg_namespace n ON n.oid=t.typnamespace WHERE n.nspname=$1 AND t.typname='binary_key'", f.schema).Scan(&domainOID) != nil {
		t.Fatal("fixture type identity unavailable")
	}
	request := protocol.CatalogRequest{Kind: "columns", Schema: f.schema, Object: "captured_types", ObjectKind: "table"}
	response := catalog(context.Background(), f.conn, protocol.Command{Type: "catalog", Catalog: &request})
	indices := map[string]int{}
	for i, column := range response.Columns {
		indices[column.Name] = i
	}
	if response.Type != "query.result" || len(response.Rows) != 3 || indices["typeOid"] == 0 || indices["baseTypeOid"] == 0 {
		t.Fatal("captured column type identity unavailable")
	}
	want := [][2]uint32{{1700, 1700}, {1007, 1007}, {domainOID, 17}}
	for i, row := range response.Rows {
		a, ea := strconv.ParseUint(*row[indices["typeOid"]], 10, 32)
		b, eb := strconv.ParseUint(*row[indices["baseTypeOid"]], 10, 32)
		if ea != nil || eb != nil || uint32(a) != want[i][0] || uint32(b) != want[i][1] {
			t.Fatal("captured declaration/base type identity changed")
		}
	}
}
