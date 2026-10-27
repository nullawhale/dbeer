package postgres

import (
	"context"
	"encoding/base64"
	"reflect"
	"strings"
	"testing"

	"dbeer/helper/internal/protocol"
	"github.com/jackc/pgx/v5"
)

func TestPostgresSQLResultSourceFullAndProjectedKeys(t *testing.T) {
	f := newChangeFixture(t)
	f.exec("CREATE TABLE " + f.table("records") + "(id bigint,part bytea,note text,amount numeric(50,20),PRIMARY KEY(id,part));INSERT INTO " + f.table("records") + " VALUES(9007199254740993,decode('00ff80','hex'),'NULL',9007199254740993.12345678901234567890)")
	ctx := context.Background()
	sink := &storageTestSink{}
	query := "SELECT t.note AS label,t.part,t.id AS external_id,t.amount FROM " + f.table("records") + " AS t WHERE t.id = 9007199254740993 ORDER BY t.part LIMIT 2"
	r := executeParamsSink(ctx, f.conn, protocol.Command{Type: "execute", SQL: query}, query, nil, sink)
	if r.Type != "query.result" || r.Source == nil || r.Source.ReadOnlyReason != "" || r.Source.Schema != f.schema || r.Source.Table != "records" || len(r.Rows) != 1 || len(r.Columns) != 4 || len(r.Rows[0]) != 4 || len(r.StorageTokens) != 0 {
		t.Fatal("full direct SELECT did not expose an editable source without rewriting SQL")
	}
	if r.Columns[0].Name != "label" || r.Columns[2].Name != "external_id" || *r.Rows[0][1] != base64.StdEncoding.EncodeToString([]byte{0, 255, 128}) || *r.Rows[0][2] != "9007199254740993" || *r.Rows[0][3] != "9007199254740993.12345678901234567890" {
		t.Fatal("source discovery changed aliases, order, binary or exact numeric values")
	}
	var mapping []int
	for _, column := range r.Source.Columns {
		mapping = append(mapping, column.TableIndex)
	}
	if !reflect.DeepEqual(mapping, []int{2, 1, 0, 3}) || r.Source.Columns[1].PrimaryKey != 2 || r.Source.Columns[2].PrimaryKey != 1 || sink.summary.Source == nil || len(sink.summary.StorageTokens) != 0 || len(sink.columns) != 4 || len(sink.rows[0]) != 4 {
		t.Fatal("canonical source mapping or streaming summary was lost")
	}
	partial := execute(ctx, f.conn, protocol.Command{Type: "execute", SQL: "SELECT part,id AS key FROM " + f.table("records")})
	if partial.Type != "query.result" || partial.Source == nil || partial.Source.Table != "records" || partial.Source.ReadOnlyReason == "" || len(partial.Source.Columns) != 2 || len(partial.StorageTokens) != 0 {
		t.Fatal("complete projected key did not retain navigation without editing")
	}
	for _, sql := range []string{
		"SELECT id FROM " + f.table("records"),
		"SELECT id,part,id FROM " + f.table("records"),
		"SELECT id,part,note,amount+1 AS amount FROM " + f.table("records"),
		"SELECT a.* FROM " + f.table("records") + " a JOIN " + f.table("records") + " b ON a.id=b.id",
		"WITH rows AS (SELECT * FROM " + f.table("records") + ") SELECT * FROM rows",
		"SELECT * FROM " + f.table("records") + " UNION ALL SELECT * FROM " + f.table("records"),
	} {
		denied := execute(ctx, f.conn, protocol.Command{Type: "execute", SQL: sql})
		if denied.Type != "query.result" || denied.Source == nil || denied.Source.Table != "" || denied.Source.ReadOnlyReason == "" || len(denied.StorageTokens) != 0 {
			t.Fatal("ambiguous, computed or incomplete result exposed a source row")
		}
	}
}

func TestPostgresSQLResultSourceLossyTypesKeepExactKeyNavigation(t *testing.T) {
	f := newChangeFixture(t)
	f.exec("CREATE TYPE " + f.table("lossy") + ";CREATE FUNCTION " + f.table("lossy_in") + "(cstring) RETURNS " + f.table("lossy") + " AS 'int4in' LANGUAGE internal IMMUTABLE STRICT;CREATE FUNCTION " + f.table("lossy_out") + "(" + f.table("lossy") + ") RETURNS cstring AS 'boolout' LANGUAGE internal IMMUTABLE STRICT;CREATE TYPE " + f.table("lossy") + " (INPUT=" + f.table("lossy_in") + ",OUTPUT=" + f.table("lossy_out") + ",INTERNALLENGTH=4,PASSEDBYVALUE,ALIGNMENT=int4,STORAGE=plain);CREATE TABLE " + f.table("records") + "(id integer PRIMARY KEY,day date,value double precision,custom " + f.table("lossy") + ",note text);INSERT INTO " + f.table("records") + " VALUES(1,DATE '2026-04-05',1.234567890123456,'1','original')")
	ctx := context.Background()
	if _, err := f.conn.Exec(ctx, "SET DateStyle='SQL, DMY';SET extra_float_digits=-3"); err != nil {
		t.Fatal("source rendering fixture failed")
	}
	r := execute(ctx, f.conn, protocol.Command{Type: "execute", SQL: "SELECT note AS text,value,day,id,custom FROM " + f.table("records")})
	if r.Type != "query.result" || r.Source == nil || r.Source.Table != "records" || !strings.Contains(r.Source.ReadOnlyReason, "storage evidence") || len(r.StorageTokens) != 0 || len(r.Rows) != 1 || r.Source.Columns[1].Editable || r.Source.Columns[2].Editable || r.Source.Columns[4].Editable {
		t.Fatal("contextual or custom-lossy original values gained tokenless editing or lost exact-key navigation")
	}
	var style, digits string
	if err := f.conn.QueryRow(ctx, "SELECT pg_catalog.current_setting('DateStyle'),pg_catalog.current_setting('extra_float_digits')").Scan(&style, &digits); err != nil || style != "SQL, DMY" || digits != "-3" {
		t.Fatal("source discovery changed query-session rendering")
	}
}

func TestPostgresSQLResultSourceExactOriginalApplyAndConflict(t *testing.T) {
	f := newChangeFixture(t)
	f.exec("CREATE TABLE " + f.table("records") + "(id integer PRIMARY KEY,note text,amount numeric(50,20));INSERT INTO " + f.table("records") + " VALUES(1,'original',9007199254740993.12345678901234567890)")
	ctx := context.Background()
	read := func() protocol.Response {
		t.Helper()
		r := execute(ctx, f.conn, protocol.Command{Type: "execute", SQL: "SELECT amount,note AS label,id FROM " + f.table("records")})
		if r.Type != "query.result" || r.Source == nil || r.Source.ReadOnlyReason != "" || len(r.Rows) != 1 || len(r.StorageTokens) != 0 {
			t.Fatal("exact original result unavailable")
		}
		return r
	}
	request := func(r protocol.Response, text string) protocol.ChangesRequest {
		t.Helper()
		original := make([]protocol.CellValue, len(r.Source.Columns))
		for index, column := range r.Source.Columns {
			original[column.TableIndex] = protocol.CellValue{Kind: "text", Value: r.Rows[0][index]}
		}
		return f.request("records", protocol.RowChange{Kind: "update", Original: original, Values: []protocol.ColumnAssignment{changeAssign("note", changeText(text))}})
	}
	first := request(read(), "changed")
	if preview := changes(ctx, f.conn, protocol.Command{Type: "changes.preview", Changes: &first}); preview.Type != "query.result" {
		t.Fatal("SQL-result preview failed")
	}
	if applied := f.apply(first); applied.Type != "query.result" || f.scalar("SELECT note FROM "+f.table("records")) != "changed" {
		t.Fatal("SQL-result original-row Apply failed")
	}
	stale := request(read(), "overwritten")
	f.exec("UPDATE " + f.table("records") + " SET amount=9007199254740993.12345678901234567891")
	if applied := f.apply(stale); applied.Category != "conflict" || f.scalar("SELECT note FROM "+f.table("records")) != "changed" {
		t.Fatal("exact original snapshot did not detect a concurrent nonedited column")
	}
}

func TestPostgresSQLResultSourceRejectsUnavailableSessionsAndRelations(t *testing.T) {
	f := newChangeFixture(t)
	f.exec("CREATE TABLE " + f.table("records") + "(id integer PRIMARY KEY,note text);INSERT INTO " + f.table("records") + " VALUES(1,'original');CREATE VIEW " + f.table("view") + " AS SELECT * FROM " + f.table("records") + ";CREATE TABLE " + f.table("keyless") + "(id integer);INSERT INTO " + f.table("keyless") + " VALUES(1);CREATE TABLE " + f.table("child") + "() INHERITS(" + f.table("records") + ");CREATE TABLE " + f.table("dates") + "(id date PRIMARY KEY);INSERT INTO " + f.table("dates") + " VALUES(DATE '2026-04-05')")
	ctx := context.Background()
	if _, err := f.conn.Exec(ctx, "CREATE TEMP TABLE source_temp(id integer PRIMARY KEY);INSERT INTO source_temp VALUES(1)"); err != nil {
		t.Fatal("temporary source fixture failed")
	}
	for _, sql := range []string{
		"SELECT * FROM " + f.table("view"),
		"SELECT * FROM " + f.table("keyless"),
		"SELECT * FROM " + f.table("records"),
		"SELECT * FROM " + f.table("dates"),
		"SELECT * FROM source_temp",
	} {
		r := execute(ctx, f.conn, protocol.Command{Type: "execute", SQL: sql})
		if r.Type != "query.result" || r.Source == nil || r.Source.Table != "" || r.Source.ReadOnlyReason == "" || len(r.StorageTokens) != 0 {
			t.Fatal("view, keyless, inherited, contextual key or temporary source exposed actions")
		}
	}
	if _, err := f.conn.Exec(ctx, "BEGIN"); err != nil {
		t.Fatal("source transaction fixture failed")
	}
	r := execute(ctx, f.conn, protocol.Command{Type: "execute", SQL: "SELECT * FROM source_temp"})
	if r.Type != "query.result" || r.TransactionStatus != "transaction" || r.Source == nil || !strings.Contains(r.Source.ReadOnlyReason, "transaction") || r.Source.Table != "" {
		t.Fatal("source discovery changed or exposed an explicit query transaction")
	}
	if _, err := f.conn.Exec(ctx, "ROLLBACK"); err != nil {
		t.Fatal("source transaction cleanup failed")
	}
}

func TestPostgresSQLResultSourceDoesNotReplayPredicate(t *testing.T) {
	f := newChangeFixture(t)
	f.exec("CREATE TABLE " + f.table("records") + "(id integer PRIMARY KEY,note text);INSERT INTO " + f.table("records") + " VALUES(1,'original');CREATE TABLE " + f.table("observed") + "(query text);CREATE FUNCTION " + f.table("matches") + "(integer,integer) RETURNS boolean LANGUAGE plpgsql VOLATILE AS $$BEGIN INSERT INTO " + f.table("observed") + " VALUES(pg_catalog.current_query()); RETURN $1 OPERATOR(pg_catalog.=) $2; END$$;CREATE OPERATOR " + pgx.Identifier{f.schema}.Sanitize() + ".= (LEFTARG=integer,RIGHTARG=integer,FUNCTION=" + f.table("matches") + ")")
	ctx := context.Background()
	if _, err := f.conn.Exec(ctx, "SET search_path="+pgx.Identifier{f.schema}.Sanitize()+",pg_catalog"); err != nil {
		t.Fatal("predicate source fixture failed")
	}
	r := execute(ctx, f.conn, protocol.Command{Type: "execute", SQL: "SELECT * FROM " + f.table("records") + " WHERE id = 1"})
	if r.Type != "query.result" || r.Source == nil || r.Source.ReadOnlyReason != "" || len(r.Rows) != 1 || len(r.StorageTokens) != 0 {
		t.Fatal("direct result was rewritten or lost safe original evidence")
	}
	if count := f.scalar("SELECT count(*)::text FROM " + f.table("observed")); count != "1" {
		t.Fatal("source discovery replayed the caller predicate")
	}
	if observed := f.scalar("SELECT query FROM " + f.table("observed")); strings.Contains(observed, "__dbeer_storage") || strings.Contains(observed, "pgrow-v1/") {
		t.Fatal("source discovery rewrote the caller statement")
	}
}
