package postgres

import (
	"context"
	"strings"
	"testing"

	"dbeer/helper/internal/protocol"
)

func TestQueryTypeIdentityIncludesDefinitionsAndExecutesOnlyOnce(t *testing.T) {
	f := newChangeFixture(t)
	f.exec("CREATE TYPE " + f.table("mood") + " AS ENUM ('new',''); CREATE TYPE " + f.table("pair") + " AS (label text, n numeric); CREATE DOMAIN " + f.table("bytes") + " AS bytea; CREATE SEQUENCE " + f.table("calls"))
	sql := "SELECT nextval('" + f.table("calls") + "'), 'new'::" + f.table("mood") + ",ARRAY['new']::" + f.table("mood") + "[],ROW('é',9007199254740993.123)::" + f.table("pair") + ",decode('00ff','hex')::" + f.table("bytes")
	run := func() protocol.Response {
		t.Helper()
		response := execute(context.Background(), f.conn, protocol.Command{Type: "execute", SQL: sql})
		if response.Type != "query.result" || len(response.Columns) != 5 || len(response.Rows) != 1 {
			t.Fatal("typed query failed")
		}
		return response
	}
	first := run()
	if f.scalar("SELECT last_value::text FROM "+f.table("calls")) != "1" {
		t.Fatal("type discovery executed caller SQL")
	}
	for _, index := range []int{1, 2, 3} {
		if first.Columns[index].TypeIdentity == "" || strings.HasPrefix(first.Columns[index].NativeType, "oid:") {
			t.Fatal("custom result type lacks stable structural identity")
		}
	}
	if first.Columns[4].Encoding != "base64" || *first.Rows[0][4] != "AP8=" {
		t.Fatal("domain over bytea lost exact binary representation")
	}
	second := run()
	if first.Columns[1].TypeIdentity != second.Columns[1].TypeIdentity {
		t.Fatal("identical types changed identity across queries")
	}
	f.exec("ALTER TYPE " + f.table("mood") + " ADD VALUE 'done'")
	third := run()
	if first.Columns[1].TypeIdentity == third.Columns[1].TypeIdentity || first.Columns[2].TypeIdentity == third.Columns[2].TypeIdentity {
		t.Fatal("enum definition changes were omitted from scalar or array identity")
	}
	if f.scalar("SELECT count(*)::text FROM pg_prepared_statements WHERE name LIKE 'dbeer_types_%'") != "0" {
		t.Fatal("internal described statements leaked into the session")
	}
}

func TestQueryTypeDiscoveryUsesOwningTransactionAndRetainsServerErrors(t *testing.T) {
	f := newChangeFixture(t)
	ctx := context.Background()
	if _, err := f.conn.Exec(ctx, "BEGIN; CREATE TYPE "+f.table("uncommitted")+" AS ENUM ('x')"); err != nil {
		t.Fatal("uncommitted type fixture failed")
	}
	result := execute(ctx, f.conn, protocol.Command{Type: "execute", SQL: "SELECT 'x'::" + f.table("uncommitted")})
	if result.Type != "query.result" || result.Columns[0].TypeIdentity == "" || result.TransactionStatus != "transaction" {
		t.Fatal("type discovery lost the owning transaction")
	}
	result = execute(ctx, f.conn, protocol.Command{Type: "execute", SQL: "ROLLBACK"})
	if result.Type != "query.result" || result.TransactionStatus != "idle" {
		t.Fatal("type discovery changed transaction control")
	}
	result = execute(ctx, f.conn, protocol.Command{Type: "execute", SQL: "SELECT missing_type_fixture_column"})
	if result.Category != "sql" || result.SQLNotExecuted || result.OutcomeUnknown || result.SQLState != "42703" {
		t.Fatal("server parse errors disappeared from executed history")
	}
}

func TestChangesComplexTypesAndBinaryDomainsPreserveFullRowConflicts(t *testing.T) {
	f := newChangeFixture(t)
	f.exec("CREATE TYPE " + f.table("mood") + " AS ENUM ('new','done'); CREATE TYPE " + f.table("pair") + " AS (label text,n numeric); CREATE DOMAIN " + f.table("bytes") + " AS bytea; CREATE TABLE " + f.table("complex") + " (id int PRIMARY KEY, a int[], mood " + f.table("mood") + ", pair " + f.table("pair") + ", span int4range, spans int4multirange, raw " + f.table("bytes") + ")")
	f.exec("INSERT INTO " + f.table("complex") + " VALUES(1,ARRAY[1,NULL,3],'new',ROW('x',1),'[1,3)','{[1,3)}',decode('00ff','hex'))")
	original := f.snapshot("complex", "id=1")
	request := f.request("complex", protocol.RowChange{Kind: "update", Original: original, Values: []protocol.ColumnAssignment{
		changeAssign("a", changeText("{2,NULL,4}")), changeAssign("mood", changeText("done")),
		changeAssign("pair", changeText("(é,9007199254740993.123)")), changeAssign("span", changeText("[2,5)")),
		changeAssign("spans", changeText("{[2,5),[8,10)}")), changeAssign("raw", changeBinary("AAH/")),
	}})
	preview := changes(context.Background(), f.conn, protocol.Command{Type: "changes.preview", Changes: &request})
	if preview.Type != "query.result" || f.scalar("SELECT mood::text FROM "+f.table("complex")) != "new" {
		t.Fatal("complex type preview wrote data or failed")
	}
	if applied := f.apply(request); applied.Type != "query.result" || f.scalar("SELECT encode(raw,'hex') FROM "+f.table("complex")) != "0001ff" {
		t.Fatal("complex values did not pass through typed Preview/Apply")
	}
	original = f.snapshot("complex", "id=1")
	f.exec("UPDATE " + f.table("complex") + " SET a=ARRAY[9] WHERE id=1")
	request = f.request("complex", protocol.RowChange{Kind: "update", Original: original, Values: []protocol.ColumnAssignment{changeAssign("mood", changeText("new"))}})
	if response := f.apply(request); response.Category != "conflict" || response.OutcomeUnknown || f.scalar("SELECT mood::text FROM "+f.table("complex")) != "done" {
		t.Fatal("concurrent complex value edits bypassed full original-row comparison")
	}
}
