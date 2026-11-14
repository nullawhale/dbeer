package mysql

import (
	"context"
	"dbeer/helper/internal/protocol"
	"fmt"
	"strings"
	"testing"
)

func TestNativeMySQLActualTextFloatProvenance(t *testing.T) {
	session := integrationSession(t)
	name := QuoteIdentifier(fmt.Sprintf("dbeer_native_float_%d", session.connectionID))
	run(t, session, "CREATE TABLE "+name+"(id INT PRIMARY KEY,value FLOAT)")
	t.Cleanup(func() { run(t, session, "DROP TABLE IF EXISTS "+name) })
	run(t, session, "INSERT INTO "+name+" VALUES(1,1.00000011920928955078125),(2,1.0000002384185791015625)")
	command := protocol.Command{Type: "execute", RequestID: "native-float", ResultValues: protocol.NativeResultValuesFormat, SQL: "SELECT value FROM " + name + " ORDER BY id"}
	text := session.Execute(context.Background(), command)
	if text.Type != "query.result" || len(text.NativeValues) != 2 || len(text.Rows) != 2 {
		t.Fatal("actual native FLOAT text result missing")
	}
	for _, row := range text.NativeValues {
		if row[0].Kind != "native" || !strings.HasPrefix(row[0].TypeIdentity, "unresolved:") {
			t.Fatal("rounded text was promoted to original IEEE bits")
		}
	}
	if *text.NativeValues[0][0].Value != *text.NativeValues[1][0].Value {
		t.Fatal("fixture does not exercise adjacent FLOAT text collapse")
	}
	command.SQL = "SELECT value FROM " + name + " WHERE id>=:first ORDER BY id"
	command.Parameters = []protocol.QueryParameter{myParameter("first", "integer", "1")}
	actual := session.Execute(context.Background(), command)
	if actual.Type != "query.result" || len(actual.NativeValues) != 2 || actual.NativeValues[0][0].Kind != "float32" || actual.NativeValues[1][0].Kind != "float32" || *actual.NativeValues[0][0].Value != "3f800001" || *actual.NativeValues[1][0].Value != "3f800002" {
		t.Fatal("actual binary float widths or adjacent payloads changed")
	}
	command.ResultValues = ""
	command.Parameters = nil
	command.SQL = "SELECT value FROM " + name + " ORDER BY id"
	legacy := session.Execute(context.Background(), command)
	if legacy.Type != "query.result" || legacy.NativeValues != nil || len(legacy.Rows) != 2 || *legacy.Rows[0][0] != *text.Rows[0][0] {
		t.Fatal("legacy display ABI changed")
	}
}

func TestNativeMySQLActualBrowseAndTransactionProvenance(t *testing.T) {
	session := integrationSession(t)
	rawName := fmt.Sprintf("dbeer_native_boundary_%d", session.connectionID)
	name := QuoteIdentifier(rawName)
	run(t, session, "CREATE TABLE "+name+"(id INT PRIMARY KEY,value FLOAT,precise DOUBLE UNSIGNED,note VARCHAR(30)) ENGINE=InnoDB")
	t.Cleanup(func() { run(t, session, "DROP TABLE IF EXISTS "+name) })
	run(t, session, "INSERT INTO "+name+" VALUES(1,1.00000011920928955078125,1.0000000000000002,'kept')")
	command := protocol.Command{Type: "execute", RequestID: "unsigned", SQL: "SELECT precise FROM " + name, ResultValues: protocol.NativeResultValuesFormat}
	unsigned := session.Execute(context.Background(), command)
	if unsigned.Type != "query.result" || len(unsigned.NativeValues) != 1 || unsigned.NativeValues[0][0].Kind != "native" || unsigned.NativeValues[0][0].NativeType != "DOUBLE UNSIGNED" || *unsigned.NativeValues[0][0].Value != "1.0000000000000002" {
		t.Fatal("actual unsigned DOUBLE native text/flags changed")
	}
	browse := protocol.Command{Type: "catalog", RequestID: "browse", ResultValues: protocol.NativeResultValuesFormat, Catalog: &protocol.CatalogRequest{Kind: "browse", Schema: "dbeer", Object: rawName, ObjectKind: "table"}}
	shown := session.Execute(context.Background(), browse)
	if shown.Type != "query.result" || len(shown.NativeValues) != 1 || shown.NativeValues[0][1].Kind != "native" || shown.NativeValues[0][1].NativeType != "DOUBLE" {
		t.Fatal("unfiltered native browse did not preserve original text provenance")
	}
	id := "1"
	browse.Catalog.Filters = []protocol.CatalogFilter{{Column: "id", Operator: "eq", Value: &id}}
	filtered := session.Execute(context.Background(), browse)
	if filtered.Type != "query.result" || len(filtered.NativeValues) != 1 || filtered.NativeValues[0][1].Kind != "float64" || *filtered.NativeValues[0][1].Value != "3ff0000020000000" {
		t.Fatal("filtered binary browse lost proven promoted float payload")
	}
	run(t, session, "SET autocommit=0")
	command.SQL = "SELECT id,note FROM " + name
	firstRead := session.Execute(context.Background(), command)
	if firstRead.Type != "query.result" || firstRead.TransactionStatus != "transaction" || firstRead.Source == nil || !strings.Contains(firstRead.Source.ReadOnlyReason, "outside an explicit transaction") || len(firstRead.NativeValues) != 1 {
		t.Fatal("actual EOF transaction was not authoritative before source attachment")
	}
	run(t, session, "ROLLBACK")
	run(t, session, "SET autocommit=1")
}
