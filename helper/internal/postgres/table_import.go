package postgres

import (
	"context"
	"errors"
	"fmt"
	"strconv"
	"strings"

	"dbeer/helper/internal/protocol"
	ti "dbeer/helper/internal/tableimport"
	"github.com/jackc/pgx/v5"
	"github.com/jackc/pgx/v5/pgconn"
)

type postgresImportTable struct {
	name, fingerprint string
	columns           []ti.Column
}

func loadImportTable(ctx context.Context, conn *pgx.Conn, request protocol.TableImportRequest) (postgresImportTable, error) {
	table := postgresImportTable{name: pgx.Identifier{request.Schema, request.Table}.Sanitize()}
	var oid, kind, persistence, rowSecurity string
	var partition bool
	if err := conn.QueryRow(ctx, `SELECT c.oid::text,c.relkind::text,c.relpersistence::text,c.relispartition,c.relrowsecurity::text FROM pg_catalog.pg_class c JOIN pg_catalog.pg_namespace n ON n.oid=c.relnamespace WHERE n.nspname=$1 AND c.relname=$2`, request.Schema, request.Table).Scan(&oid, &kind, &persistence, &partition, &rowSecurity); err != nil {
		if errors.Is(err, pgx.ErrNoRows) {
			return table, changeInvalid("The import table is unavailable.")
		}
		return table, err
	}
	if kind != "r" || partition || persistence == "t" {
		return table, changeInvalid("Import supports ordinary PostgreSQL base tables.")
	}
	rows, err := conn.Query(ctx, `SELECT a.attname::text,pg_catalog.format_type(a.atttypid,a.atttypmod),a.atttypid::bigint,a.attnotnull,a.atthasdef,a.attidentity::text,a.attgenerated::text,has_column_privilege(c.oid,a.attnum,'INSERT'),a.attnum::text,a.atttypmod::text,a.attcollation::text,COALESCE(pg_catalog.pg_get_expr(d.adbin,d.adrelid),''),t.typnamespace::regnamespace::text,t.typname::text,t.typtype::text FROM pg_catalog.pg_class c JOIN pg_catalog.pg_namespace n ON n.oid=c.relnamespace JOIN pg_catalog.pg_attribute a ON a.attrelid=c.oid AND a.attnum>0 AND NOT a.attisdropped JOIN pg_catalog.pg_type t ON t.oid=a.atttypid LEFT JOIN pg_catalog.pg_attrdef d ON d.adrelid=c.oid AND d.adnum=a.attnum WHERE n.nspname=$1 AND c.relname=$2 ORDER BY a.attnum LIMIT 4097`, request.Schema, request.Table)
	if err != nil {
		return table, err
	}
	defer rows.Close()
	facts := [][]any{{request.Schema, request.Table, oid, kind, persistence, partition, rowSecurity}}
	for rows.Next() {
		var c ti.Column
		var typeOID int64
		var notNull, hasDefault bool
		var identity, generated, ordinal, typmod, collation, defaultSQL, namespace, typeName, typeKind string
		if err := rows.Scan(&c.Name, &c.NativeType, &typeOID, &notNull, &hasDefault, &identity, &generated, &c.Writable, &ordinal, &typmod, &collation, &defaultSQL, &namespace, &typeName, &typeKind); err != nil {
			return table, err
		}
		c.OID, c.Nullable, c.HasDefault, c.Generated, c.Binary = uint32(typeOID), !notNull, hasDefault || identity != "" || generated != "", generated != "" || identity == "a", typeOID == 17
		// User-defined input routines and mutable type definitions need a
		// broader locking contract. Keep this first importer on known builtins.
		c.Supported = namespace == "pg_catalog" && supportedImportPostgresType(typeName)
		table.columns = append(table.columns, c)
		facts = append(facts, []any{c, ordinal, typmod, collation, defaultSQL, identity, generated, namespace, typeName, typeKind})
		if len(table.columns) > 4096 {
			return table, changeInvalid("The import table has too many columns.")
		}
	}
	if err := rows.Err(); err != nil {
		return table, err
	}
	if len(table.columns) == 0 {
		return table, changeInvalid("The import table has no visible columns.")
	}
	if !ti.DescriptionValid(table.columns) {
		return table, changeInvalid("Import metadata exceeds its size limit.")
	}
	table.fingerprint, err = ti.MetadataFingerprint(facts)
	if err != nil {
		return table, changeInvalid("Import metadata exceeds its size limit.")
	}
	return table, nil
}

func supportedImportPostgresType(name string) bool {
	switch name {
	case "bool", "bytea", "int2", "int4", "int8", "numeric", "float4", "float8", "text", "varchar", "bpchar", "name", "uuid", "json", "jsonb", "date", "time", "timetz", "timestamp", "timestamptz", "interval", "inet", "cidr", "macaddr", "macaddr8", "bit", "varbit", "money":
		return true
	}
	return false
}

func postgresImportTemplate(table postgresImportTable, columns []ti.Column) (string, []uint32) {
	names, values, oids := []string{}, []string{}, []uint32{}
	for i, c := range columns {
		names = append(names, pgx.Identifier{c.Name}.Sanitize())
		values = append(values, "$"+strconv.Itoa(i+1))
		oids = append(oids, c.OID)
	}
	return "INSERT INTO " + table.name + " (" + strings.Join(names, ",") + ") VALUES (" + strings.Join(values, ",") + ")", oids
}

func tableImport(ctx context.Context, conn *pgx.Conn, command protocol.Command) protocol.Response {
	return tableImportWithCommit(ctx, conn, command, func(ctx context.Context, conn *pgx.Conn) error { _, err := conn.Exec(ctx, "COMMIT"); return err })
}

func tableImportWithCommit(ctx context.Context, conn *pgx.Conn, command protocol.Command, commit changeCommitter) protocol.Response {
	startedRows, currentRow := false, 0
	fail := func(err error, inTransaction bool) protocol.Response {
		if inTransaction {
			rollbackChanges(conn)
		}
		var response protocol.Response
		if errors.Is(err, ti.ErrInvalid) {
			err = changeInvalid(err.Error())
		} else if errors.Is(err, ti.ErrConflict) {
			err = changeConflict(err.Error())
		}
		response = changeError(command, ctx, conn, err)
		response.SQLNotExecuted = !startedRows
		if currentRow > 0 {
			row := currentRow
			response.TableImport = &protocol.TableImportReply{Row: &row}
		}
		return response
	}
	if command.TableImport == nil || !command.TableImport.Valid(command.Type) {
		return fail(changeInvalid("Invalid table import."), false)
	}
	if conn.IsClosed() || transactionStatus(conn) != "idle" {
		return fail(changeInvalid("Import requires a dedicated idle session."), false)
	}
	request := *command.TableImport
	if _, err := conn.Exec(ctx, "BEGIN ISOLATION LEVEL READ COMMITTED"); err != nil {
		return fail(err, true)
	}
	// The relation lock prevents rename/drop/column/default DDL
	// while metadata is re-read and the complete batch is inserted.
	if _, err := conn.Exec(ctx, "SET LOCAL lock_timeout='5s'"); err != nil {
		return fail(err, true)
	}
	name := pgx.Identifier{request.Schema, request.Table}.Sanitize()
	lockMode := "ACCESS SHARE"
	if command.Type == "import.apply" {
		lockMode = "ROW EXCLUSIVE"
	}
	if _, err := conn.Exec(ctx, "LOCK TABLE "+name+" IN "+lockMode+" MODE"); err != nil {
		return fail(err, true)
	}
	table, err := loadImportTable(ctx, conn, request)
	if err != nil {
		return fail(err, true)
	}
	if command.Type == "import.describe" {
		if err := ctx.Err(); err != nil {
			return fail(err, true)
		}
		rollbackChanges(conn)
		if conn.IsClosed() {
			return fail(changeInvalid("The import session could not be recovered."), false)
		}
		return protocol.Response{Type: "import.describe.result", Connected: true, TransactionStatus: "idle", TableImport: &protocol.TableImportReply{Columns: ti.ReplyColumns(table.columns), Fingerprint: table.fingerprint}}
	}
	mapped, err := ti.Validate(table.columns, table.fingerprint, request)
	if err != nil {
		return fail(err, true)
	}
	sql, oids := postgresImportTemplate(table, mapped)
	count := len(request.Rows)
	if command.Type == "import.preview" {
		if err := ctx.Err(); err != nil {
			return fail(err, true)
		}
		rollbackChanges(conn)
		if conn.IsClosed() {
			return fail(changeInvalid("The import session could not be recovered."), false)
		}
		return protocol.Response{Type: "import.preview.result", Connected: true, TransactionStatus: "idle", TableImport: &protocol.TableImportReply{Fingerprint: table.fingerprint, RowCount: &count, SQL: sql}}
	}
	for i, row := range request.Rows {
		currentRow = i + 1
		values, err := changeParameters(row)
		if err != nil {
			return fail(err, true)
		}
		startedRows = true
		reader := conn.PgConn().ExecParams(ctx, sql, values, oids, nil, nil)
		tag, err := reader.Close()
		if err != nil {
			return fail(err, true)
		}
		if tag.RowsAffected() != 1 {
			return fail(changeConflict("The import did not insert exactly one row. No rows were committed."), true)
		}
	}
	currentRow = 0
	if err := ctx.Err(); err != nil {
		return fail(err, true)
	}
	if err := commit(ctx, conn); err != nil {
		var server *pgconn.PgError
		if errors.As(err, &server) && server.Severity != "FATAL" && server.Severity != "PANIC" && server.SeverityUnlocalized != "FATAL" && server.SeverityUnlocalized != "PANIC" && !strings.HasPrefix(server.Code, "08") && server.Code != "40003" {
			return fail(err, true)
		}
		closeConnection(conn)
		response := protocol.ErrorResponse(command, "connection", "The import COMMIT outcome is unknown. Verify the table before importing again.")
		response.OutcomeUnknown = true
		return response
	}
	return protocol.Response{Type: "import.apply.result", Connected: true, TransactionStatus: "idle", TableImport: &protocol.TableImportReply{RowCount: &count}, CommandTag: fmt.Sprintf("IMPORT %d", count)}
}
