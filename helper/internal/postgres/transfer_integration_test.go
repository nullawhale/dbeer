package postgres

import (
	"context"
	"encoding/base64"
	"io"
	"strings"
	"testing"
	"time"

	dt "dbeer/helper/internal/datatransfer"
	"dbeer/helper/internal/protocol"
	"github.com/jackc/pgx/v5"
)

func transferText(value string) protocol.CellValue {
	return protocol.CellValue{Kind: "text", Value: &value}
}
func transferRows(rows [][]protocol.CellValue) dt.RowReader {
	index := 0
	return func() ([]protocol.CellValue, error) {
		if index == len(rows) {
			return nil, io.EOF
		}
		row := rows[index]
		index++
		return row, nil
	}
}
func TestPostgresTransferCreatesTypedRowsAndRefusesCollision(t *testing.T) {
	fixture := newChangeFixture(t)
	ctx, cancel := context.WithTimeout(context.Background(), 10*time.Second)
	defer cancel()
	session := &Session{conn: fixture.conn}
	columns := []protocol.TransferColumn{{SourceIndex: 0, Name: "exact", Type: "integer"}, {SourceIndex: 1, Name: "payload", Type: "binary"}, {SourceIndex: 2, Name: "note", Type: "text", Nullable: true}}
	statement, identity, err := session.TransferPreview(ctx, fixture.schema, "new_table", columns)
	if err != nil || !strings.Contains(statement, "CREATE TABLE") {
		t.Fatal("typed create preview failed")
	}
	binary := base64.StdEncoding.EncodeToString([]byte{0, 0xff, '\t', '\n'})
	rows := [][]protocol.CellValue{{transferText("9007199254740993"), {Kind: "binary", Value: &binary}, transferText("")}, {transferText("-9223372036854775808"), {Kind: "binary", Value: &binary}, {Kind: "null"}}}
	out, err := session.TransferApply(ctx, fixture.schema, "new_table", identity, columns, transferRows(rows), func(int64) {})
	if err != nil || !out.TableCreated || out.Rows != 2 || out.OutcomeUnknown {
		t.Fatal("typed create/apply failed")
	}
	var exact, note string
	var length int
	if err = fixture.observer.QueryRow(ctx, "SELECT exact::text,encode(payload,'hex'),length(note) FROM "+fixture.table("new_table")+" WHERE note IS NOT NULL").Scan(&exact, &note, &length); err != nil || exact != "9007199254740993" || note != "00ff090a" || length != 0 {
		t.Fatal("typed source values or empty text changed")
	}
	if _, _, err = session.TransferPreview(ctx, fixture.schema, "new_table", columns); err == nil {
		t.Fatal("existing destination could be overwritten")
	}
	_, identity, err = session.TransferPreview(ctx, fixture.schema, "bad_table", columns)
	if err != nil {
		t.Fatal("cannot prepare rollback fixture")
	}
	bad := [][]protocol.CellValue{{transferText("not an integer"), {Kind: "binary", Value: &binary}, transferText("text")}}
	out, err = session.TransferApply(ctx, fixture.schema, "bad_table", identity, columns, transferRows(bad), func(int64) {})
	if err == nil || out.TableCreated || out.OutcomeUnknown {
		t.Fatal("failed PostgreSQL data conversion did not roll back CREATE")
	}
	var exists bool
	if fixture.observer.QueryRow(ctx, "SELECT to_regclass($1) IS NOT NULL", pgx.Identifier{fixture.schema, "bad_table"}.Sanitize()).Scan(&exists) != nil || exists {
		t.Fatal("failed PostgreSQL transfer left a created table")
	}
}
func TestPostgresTransferSnapshotCapturesNoPrimaryKeyAndRejectsSchemaDrift(t *testing.T) {
	fixture := newChangeFixture(t)
	ctx, cancel := context.WithTimeout(context.Background(), 10*time.Second)
	defer cancel()
	fixture.exec("CREATE TABLE " + fixture.table("source") + " (id bigint,note text,payload bytea,real_value real)")
	fixture.exec("INSERT INTO " + fixture.table("source") + " VALUES (9007199254740993,'NULL',decode('00ff','hex'),0.1),(NULL,'',NULL,NULL)")
	session := &Session{conn: fixture.conn}
	description, err := session.TransferDescribe(ctx, fixture.schema, "source")
	if err != nil {
		t.Fatal("table without primary key was not describable")
	}
	var rows [][]protocol.CellValue
	_, err = session.TransferCapture(ctx, fixture.schema, "source", description.Digest, func(row []protocol.CellValue) error { rows = append(rows, row); return nil })
	if err != nil || len(rows) != 2 || *rows[0][0].Value != "9007199254740993" || rows[0][2].Kind != "binary" || rows[1][0].Kind != "null" || *rows[1][1].Value != "" || *rows[0][3].Value != "0.10000000149011612" {
		t.Fatal("source snapshot lost exact values, nulls or float32 widening")
	}
	fixture.exec("ALTER TABLE " + fixture.table("source") + " ADD COLUMN changed integer")
	if _, err = session.TransferCapture(ctx, fixture.schema, "source", description.Digest, func([]protocol.CellValue) error { return nil }); err == nil {
		t.Fatal("source column mapping accepted changed metadata")
	}
}

func TestPostgresTransferRefusesAnExistingSQLTransaction(t *testing.T) {
	fixture := newChangeFixture(t)
	ctx, cancel := context.WithTimeout(context.Background(), 5*time.Second)
	defer cancel()
	fixture.exec("CREATE TABLE " + fixture.table("source") + " (id BIGINT)")
	if _, err := fixture.conn.Exec(ctx, "BEGIN"); err != nil {
		t.Fatal("cannot open SQL transaction fixture")
	}
	defer fixture.conn.Exec(context.Background(), "ROLLBACK")
	session := &Session{conn: fixture.conn}
	columns := []protocol.TransferColumn{{SourceIndex: 0, Name: "id", Type: "integer"}}
	if _, err := session.TransferDescribe(ctx, fixture.schema, "source"); err == nil {
		t.Fatal("transfer description accepted a SQL-tab transaction")
	}
	if _, err := session.TransferCapture(ctx, fixture.schema, "source", "unused", func([]protocol.CellValue) error { return nil }); err == nil {
		t.Fatal("transfer capture accepted a SQL-tab transaction")
	}
	if _, _, err := session.TransferPreview(ctx, fixture.schema, "target", columns); err == nil {
		t.Fatal("transfer preview accepted a SQL-tab transaction")
	}
	if _, err := session.TransferApply(ctx, fixture.schema, "target", "unused", columns, transferRows(nil), func(int64) {}); err == nil {
		t.Fatal("transfer apply accepted a SQL-tab transaction")
	}
	if session.TransactionStatus() != "transaction" {
		t.Fatal("transfer committed or rolled back the independent SQL transaction")
	}
}
