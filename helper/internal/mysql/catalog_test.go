package mysql

import (
	"context"
	"encoding/json"
	"fmt"
	"strings"
	"testing"

	"dbeer/helper/internal/protocol"
	"dbeer/helper/internal/sqlcomplete"
)

func TestMySQLCatalogQuotesIdentifiersAndParameterizesNames(t *testing.T) {
	if QuoteIdentifier("a`b; DROP TABLE x") != "`a``b; DROP TABLE x`" {
		t.Fatal("identifier was not escaped")
	}
	for _, kind := range []string{"columns", "keys", "foreignKeys", "indexes", "constraints", "triggers"} {
		request := protocol.CatalogRequest{Kind: kind, Schema: "private' OR 1=1", Object: "x';DROP TABLE x--", ObjectKind: "table"}
		query, args := catalogQuery(request)
		if strings.Contains(query, request.Schema) || strings.Contains(query, request.Object) || len(args) != 2 || args[0] != request.Schema || args[1] != request.Object {
			t.Fatal("metadata name was inserted into SQL syntax")
		}
	}
}

func TestMySQLForeignKeyCatalogPreservesConstraintColumnOrder(t *testing.T) {
	query, args := catalogQuery(protocol.CatalogRequest{Kind: "foreignKeys", Schema: "source", Object: "child", ObjectKind: "table"})
	for _, fragment := range []string{"AS targetSchema", "AS targetTable", "AS sourceColumn", "AS targetColumn", "AS position", "ORDER BY k.CONSTRAINT_NAME,k.ORDINAL_POSITION"} {
		if !strings.Contains(query, fragment) {
			t.Fatal("foreign key catalog lost a structured field or composite order")
		}
	}
	if strings.Contains(query, "GROUP_CONCAT") || strings.Contains(query, "JSON_ARRAYAGG") || len(args) != 2 {
		t.Fatal("foreign key pairs must be ordered rows with bound source names")
	}
}

func catalogRequest(t *testing.T, session *Session, request protocol.CatalogRequest) protocol.Response {
	t.Helper()
	response := session.Execute(context.Background(), protocol.Command{Type: "catalog", RequestID: "catalog-r", SessionID: "catalog-s", QueryID: "catalog-q", Catalog: &request})
	if response.Type != "query.result" {
		t.Fatalf("catalog %s failed: category=%s SQLSTATE=%s", request.Kind, response.Category, response.SQLState)
	}
	if response.RequestID != "catalog-r" || response.SessionID != "catalog-s" || response.QueryID != "catalog-q" {
		t.Fatal("catalog identifiers changed")
	}
	return response
}

func catalogRow(response protocol.Response, name string) []*string {
	for _, row := range response.Rows {
		if len(row) > 0 && row[0] != nil && *row[0] == name {
			return row
		}
	}
	return nil
}

func TestMySQLCatalogRealObjectsAndStableBrowse(t *testing.T) {
	session := integrationSession(t)
	schema := integrationSettings(t).Database
	base := fmt.Sprintf("dbeer_catalog_%x", session.connectionID)
	parent, table, view, procedure, function, trigger := base+"_parent", base+"` odd';--", base+"_view", base+"_procedure `\"Ω", base+"_function `\"空", base+"_trigger `\"Ω"
	qualified := func(name string) string { return QuoteIdentifier(schema) + "." + QuoteIdentifier(name) }
	t.Cleanup(func() {
		for _, sql := range []string{"DROP VIEW IF EXISTS " + qualified(view), "DROP PROCEDURE IF EXISTS " + qualified(procedure), "DROP FUNCTION IF EXISTS " + qualified(function), "DROP TABLE IF EXISTS " + qualified(table), "DROP TABLE IF EXISTS " + qualified(parent)} {
			session.Execute(context.Background(), protocol.Command{RequestID: "cleanup", SQL: sql})
		}
	})
	run(t, session, "CREATE TABLE "+qualified(parent)+" (id INT PRIMARY KEY) ENGINE=InnoDB")
	run(t, session, "CREATE TABLE "+qualified(table)+" (id INT NOT NULL, part INT NOT NULL, parent_id INT, label VARCHAR(40) DEFAULT 'ready', computed INT GENERATED ALWAYS AS (part+1) STORED, doc JSON, PRIMARY KEY(id,part), CONSTRAINT "+QuoteIdentifier(base+"_fk")+" FOREIGN KEY(parent_id) REFERENCES "+qualified(parent)+" (id), CONSTRAINT "+QuoteIdentifier(base+"_check")+" CHECK(part>=0), INDEX "+QuoteIdentifier(base+"_idx")+" (label DESC)) ENGINE=InnoDB")
	run(t, session, "CREATE VIEW "+qualified(view)+" AS SELECT id,label FROM "+qualified(table))
	run(t, session, "CREATE PROCEDURE "+qualified(procedure)+"() SELECT 1")
	run(t, session, "CREATE FUNCTION "+qualified(function)+"(input_value INT, scale INT) RETURNS BIGINT DETERMINISTIC NO SQL RETURN input_value * scale")
	run(t, session, "CREATE TRIGGER "+qualified(trigger)+" BEFORE INSERT ON "+qualified(table)+" FOR EACH ROW SET NEW.label=COALESCE(NEW.label,'trigger')")
	run(t, session, "INSERT INTO "+qualified(table)+" (id,part,label) WITH RECURSIVE seq(n) AS (SELECT 1 UNION ALL SELECT n+1 FROM seq WHERE n<205) SELECT 206-n,MOD(n,2),'κόσμος' FROM seq")
	response := catalogRequest(t, session, protocol.CatalogRequest{Kind: "schemas"})
	if catalogRow(response, schema) == nil {
		t.Fatal("accessible schema missing")
	}
	response = catalogRequest(t, session, protocol.CatalogRequest{Kind: "completion", Schema: schema})
	completionRow := catalogRow(response, table)
	var completionColumns []string
	if len(completionRow) != 6 || completionRow[3] == nil || json.Unmarshal([]byte(*completionRow[3]), &completionColumns) != nil || len(completionColumns) != 6 {
		t.Fatal("completion snapshot lost table columns")
	}
	var keys []struct {
		Name         string `json:"name"`
		TargetSchema string `json:"targetSchema"`
		TargetTable  string `json:"targetTable"`
		Columns      []struct {
			Source string `json:"source"`
			Target string `json:"target"`
		} `json:"columns"`
	}
	if completionRow[4] == nil || json.Unmarshal([]byte(*completionRow[4]), &keys) != nil || len(keys) != 1 || keys[0].TargetSchema != schema || keys[0].TargetTable != parent || len(keys[0].Columns) != 1 || keys[0].Columns[0].Source != "parent_id" || keys[0].Columns[0].Target != "id" {
		t.Fatal("completion snapshot lost the foreign key")
	}
	for _, name := range []string{"id", "part", "parent_id", "label", "computed", "doc"} {
		found := false
		for _, column := range completionColumns {
			found = found || column == name
		}
		if !found {
			t.Fatal("completion snapshot lost a column")
		}
	}
	if catalogRow(response, view) == nil || catalogRow(response, function) == nil || catalogRow(response, trigger) != nil {
		t.Fatal("completion snapshot has incorrect object kinds")
	}
	functionRow := catalogRow(response, function)
	var signatures []sqlcomplete.FunctionSignature
	if len(functionRow) != 6 || functionRow[5] == nil || json.Unmarshal([]byte(*functionRow[5]), &signatures) != nil || len(signatures) != 1 || len(signatures[0].Parameters) != 2 || !strings.Contains(strings.ToLower(signatures[0].ReturnType), "bigint") {
		t.Fatal("completion lost the stored function signature")
	}
	byPosition := map[int]sqlcomplete.FunctionParameter{}
	for _, parameter := range signatures[0].Parameters {
		byPosition[parameter.Position] = parameter
	}
	if byPosition[1].Name != "input_value" || byPosition[2].Name != "scale" || byPosition[1].Type != "int" {
		t.Fatal("stored function arguments lost names, types, or positions")
	}
	if empty := catalogRequest(t, session, protocol.CatalogRequest{Kind: "completion", Schema: schema, Page: 100}); len(empty.Rows) != 0 {
		t.Fatal("completion page repeated objects")
	}
	if empty := catalogRequest(t, session, protocol.CatalogRequest{Kind: "completion", Schema: "' OR 1=1 --"}); len(empty.Rows) != 0 {
		t.Fatal("completion schema was interpreted as SQL")
	}
	for _, item := range []struct{ kind, name string }{{"table", table}, {"view", view}, {"procedure", procedure}, {"function", function}, {"trigger", trigger}} {
		response = catalogRequest(t, session, protocol.CatalogRequest{Kind: "objects", Schema: schema, ObjectKind: item.kind})
		row := catalogRow(response, item.name)
		if len(row) != 4 || *row[1] != item.kind || *row[2] != schema || row[3] == nil {
			t.Fatalf("catalog %s metadata missing", item.kind)
		}
		response = catalogRequest(t, session, protocol.CatalogRequest{Kind: "definition", Schema: schema, Object: item.name, ObjectKind: item.kind, Identity: *row[3]})
		if len(response.Rows) != 1 || len(response.Rows[0]) != 2 || !strings.Contains(*response.Rows[0][1], "CREATE") {
			t.Fatalf("%s definition missing", item.kind)
		}
		identity := ""
		if item.kind != "table" && item.kind != "view" {
			identity = *row[3]
		}
		response = catalogRequest(t, session, protocol.CatalogRequest{Kind: "name", Schema: schema, Object: item.name, ObjectKind: item.kind, Identity: identity})
		if len(response.Columns) != 1 || response.Columns[0].Name != "name" || len(response.Rows) != 1 || *response.Rows[0][0] != qualified(item.name) {
			t.Fatalf("%s Copy Name did not return the adapter-quoted qualified identifier", item.kind)
		}
		if identity != "" {
			stale := catalogRequest(t, session, protocol.CatalogRequest{Kind: "name", Schema: schema, Object: item.name, ObjectKind: item.kind, Identity: "stale identity"})
			if len(stale.Rows) != 0 || stale.DisplayNotice == "" {
				t.Fatal("stale object identity was copied")
			}
		}
	}
	request := protocol.CatalogRequest{Kind: "columns", Schema: schema, Object: table, ObjectKind: "table"}
	response = catalogRequest(t, session, request)
	wantNames := []string{"name", "nativeType", "nullable", "default", "generated", "primaryKey", "editable", "editReason"}
	if len(response.Columns) != len(wantNames) {
		t.Fatal("catalog columns shape changed")
	}
	for index, name := range wantNames {
		if response.Columns[index].Name != name {
			t.Fatal("catalog column names changed")
		}
	}
	if row := catalogRow(response, "id"); len(row) != 8 || *row[5] != "1" || *row[6] != "true" || *row[2] != "false" {
		t.Fatal("primary key first ordinal missing")
	}
	if row := catalogRow(response, "part"); len(row) != 8 || *row[5] != "2" {
		t.Fatal("primary key second ordinal missing")
	}
	if row := catalogRow(response, "label"); len(row) != 8 || row[3] == nil || *row[3] != "ready" || *row[2] != "true" {
		t.Fatal("default/nullable metadata missing")
	}
	if row := catalogRow(response, "computed"); len(row) != 8 || *row[4] == "" || *row[6] != "false" || *row[7] == "" {
		t.Fatal("generated column was editable")
	}
	if row := catalogRow(response, "doc"); len(row) != 8 || *row[6] != "true" || *row[7] != "" {
		t.Fatal("JSON metadata did not expose supported editing")
	}
	viewColumns := catalogRequest(t, session, protocol.CatalogRequest{Kind: "columns", Schema: schema, Object: view, ObjectKind: "view"})
	if len(viewColumns.Rows) == 0 || *viewColumns.Rows[0][6] != "false" || !strings.Contains(*viewColumns.Rows[0][7], "Views") {
		t.Fatal("view columns were editable")
	}
	for _, kind := range []string{"keys", "indexes", "constraints", "triggers"} {
		request.Kind = kind
		response = catalogRequest(t, session, request)
		if len(response.Columns) != 3 || len(response.Rows) == 0 {
			t.Fatalf("%s branch missing", kind)
		}
	}
	request.Kind = "select"
	response = catalogRequest(t, session, request)
	if len(response.Columns) != 2 || response.Columns[1].Name != "name" || *response.Rows[0][1] != qualified(table) ||
		!strings.Contains(*response.Rows[0][0], "ORDER BY `id`, `part` LIMIT 200") {
		t.Fatal("quoted SELECT/CopyName missing stable PK order")
	}
	request.Kind = "browse"
	response = catalogRequest(t, session, request)
	if len(response.Rows) != 200 || *response.Rows[0][0] != "1" || *response.Rows[199][0] != "200" {
		t.Fatal("browse was not limited or stable")
	}
	request.Kind, request.Object = "columns", "missing' OR 1=1--"
	response = catalogRequest(t, session, request)
	if len(response.Rows) != 0 || response.DisplayNotice == "" {
		t.Fatal("missing metadata object was not reported safely")
	}
	request.Kind, request.Object = "definition", "missing"
	response = catalogRequest(t, session, request)
	if len(response.Rows) != 0 || response.DisplayNotice == "" {
		t.Fatal("missing object definition was not reported safely")
	}
	response = catalogRequest(t, session, protocol.CatalogRequest{Kind: "search", Search: base})
	if len(response.Rows) < 6 {
		t.Fatal("object search did not include accessible routines/triggers/tables")
	}
	response = catalogRequest(t, session, protocol.CatalogRequest{Kind: "search", Search: "' OR 1=1 --"})
	if len(response.Rows) != 0 {
		t.Fatal("search was interpreted as SQL")
	}
	response = catalogRequest(t, session, protocol.CatalogRequest{Kind: "name", Schema: schema, Object: "missing' OR 1=1 --", ObjectKind: "function"})
	if len(response.Rows) != 0 || response.DisplayNotice == "" {
		t.Fatal("Copy Name treated a missing name as SQL or invented an accessible object")
	}
	if integrationSettings(t).User == "dbeer" {
		denied := session.Execute(context.Background(), protocol.Command{RequestID: "denied", Catalog: &protocol.CatalogRequest{Kind: "definition", Schema: "mysql", Object: "user", ObjectKind: "table"}})
		if denied.Type != "error" || denied.Category != "sql" || !denied.Connected || denied.SQLState == "" || denied.Message != "Cannot load this MySQL catalog branch. Check object availability and permissions." {
			t.Fatal("permission error was not safely isolated to the catalog branch")
		}
	}
	run(t, session, "SELECT 1")
}

func TestMySQLCatalogReadOnlyReasonsAndDeletedObjects(t *testing.T) {
	session := integrationSession(t)
	schema := integrationSettings(t).Database
	base := fmt.Sprintf("dbeer_readonly_%x", session.connectionID)
	for _, item := range []struct{ name, sql, reason string }{
		{base + "_no_pk", "(id INT) ENGINE=InnoDB", "primary key"},
		{base + "_myisam", "(id INT PRIMARY KEY) ENGINE=MyISAM", "InnoDB"},
	} {
		name := QuoteIdentifier(schema) + "." + QuoteIdentifier(item.name)
		run(t, session, "CREATE TABLE "+name+" "+item.sql)
		response := catalogRequest(t, session, protocol.CatalogRequest{Kind: "columns", Schema: schema, Object: item.name, ObjectKind: "table"})
		if len(response.Rows) != 1 || *response.Rows[0][6] != "false" || !strings.Contains(*response.Rows[0][7], item.reason) {
			t.Fatal("read-only reason missing")
		}
		run(t, session, "DROP TABLE "+name)
		request := protocol.CatalogRequest{Kind: "browse", Schema: schema, Object: item.name, ObjectKind: "table"}
		response = session.Execute(context.Background(), protocol.Command{Type: "catalog", RequestID: "missing-browse", SessionID: "catalog-s", QueryID: "missing-q", Catalog: &request})
		if response.Type != "error" || !response.Connected {
			t.Fatal("deleted browse object did not retain a known failure")
		}
	}
}

type catalogIdentitySink struct{ rows [][]string }

func (sink *catalogIdentitySink) Begin(_ int, _ []protocol.Column) error { return nil }
func (sink *catalogIdentitySink) Row(_ int, values []*string) error {
	// Snapshot values now, like an already encoded/acknowledged query.chunk.
	row := make([]string, len(values))
	for index, value := range values {
		if value != nil {
			row[index] = *value
		}
	}
	sink.rows = append(sink.rows, row)
	return nil
}
func (sink *catalogIdentitySink) End(_ int, _ protocol.ResultSet) error { return nil }

func TestMySQLCatalogStreamsBoundedUnicodeIdentitiesBeforeCopyName(t *testing.T) {
	session := integrationSession(t)
	schema := integrationSettings(t).Database
	base := fmt.Sprintf("n%x_", session.connectionID)
	table := base + "table"
	names := map[string]string{
		"function":  base + strings.Repeat("猫", 48) + "函",
		"procedure": base + strings.Repeat("猫", 48) + "程",
		"trigger":   base + strings.Repeat("猫", 48) + "触",
	}
	qualified := func(name string) string { return QuoteIdentifier(schema) + "." + QuoteIdentifier(name) }
	t.Cleanup(func() {
		for _, sql := range []string{"DROP FUNCTION IF EXISTS " + qualified(names["function"]), "DROP PROCEDURE IF EXISTS " + qualified(names["procedure"]), "DROP TABLE IF EXISTS " + qualified(table)} {
			session.Execute(context.Background(), protocol.Command{RequestID: "cleanup", SQL: sql})
		}
	})
	run(t, session, "CREATE TABLE "+qualified(table)+" (id INT)")
	run(t, session, "CREATE FUNCTION "+qualified(names["function"])+"() RETURNS INT DETERMINISTIC NO SQL RETURN 1")
	run(t, session, "CREATE PROCEDURE "+qualified(names["procedure"])+"() SELECT 1")
	run(t, session, "CREATE TRIGGER "+qualified(names["trigger"])+" BEFORE INSERT ON "+qualified(table)+" FOR EACH ROW SET NEW.id=NEW.id")
	for kind, name := range names {
		if len(name) <= protocol.MaxIDBytes {
			t.Fatal("fixture must exceed the identity byte limit")
		}
		var previousIdentity string
		for _, request := range []protocol.CatalogRequest{
			{Kind: "objects", Schema: schema, ObjectKind: kind},
			{Kind: "search", Schema: schema, Search: name},
		} {
			sink := &catalogIdentitySink{}
			response := session.ExecuteWithSink(context.Background(), protocol.Command{Type: "catalog", RequestID: "stream", SessionID: "catalog", QueryID: "copy", Stream: true, Catalog: &request}, sink)
			if response.Type != "query.result" {
				t.Fatal("catalog stream failed")
			}
			var identity string
			for _, row := range sink.rows {
				if len(row) == 4 && row[0] == name && row[1] == kind {
					identity = row[3]
				}
			}
			if identity == "" || len(identity) > protocol.MaxIDBytes || identity == name || (previousIdentity != "" && previousIdentity != identity) {
				t.Fatal("streamed objects/search identity was not normalized before delivery")
			}
			previousIdentity = identity
			copied := catalogRequest(t, session, protocol.CatalogRequest{Kind: "name", Schema: schema, Object: name, ObjectKind: kind, Identity: identity})
			if len(copied.Rows) != 1 || *copied.Rows[0][0] != qualified(name) {
				t.Fatal("streamed identity could not be used by Copy Name")
			}
		}
	}
}
