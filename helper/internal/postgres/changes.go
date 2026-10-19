package postgres

import (
	"bytes"
	"context"
	"encoding/base64"
	"encoding/hex"
	"encoding/json"
	"errors"
	"fmt"
	"strconv"
	"strings"
	"time"
	"unicode/utf8"

	"dbeer/helper/internal/protocol"
	"github.com/jackc/pgx/v5"
	"github.com/jackc/pgx/v5/pgconn"
)

// Only built-in values with a lossless text or bytea representation participate
// in optimistic comparisons. A table containing another type stays read-only:
// comparing a partially decoded row could miss another client's changes.
const editablePostgresTypeOIDs = "16,17,18,19,20,21,23,25,26,114,142,650,700,701,774,790,829,869,1042,1043,1082,1083,1114,1184,1186,1266,1560,1562,1700,2950,3802"

var postgresChangeTypes = func() map[uint32]bool {
	result := map[uint32]bool{}
	for _, value := range strings.Split(editablePostgresTypeOIDs, ",") {
		oid, _ := strconv.ParseUint(value, 10, 32)
		result[uint32(oid)] = true
	}
	return result
}()

type changeColumn struct {
	name, nativeType string
	oid              uint32
	primaryKey       int
	generated        bool
	canInsert        bool
	canUpdate        bool
}

type changeTable struct {
	name      string
	columns   []changeColumn
	primary   []int
	canInsert bool
	canDelete bool
}

type changeStatement struct {
	operation string
	sql       string
	values    []protocol.CellValue
	types     []uint32
}

type changeFailure struct{ category, message string }

func (failure *changeFailure) Error() string { return failure.message }

func changeInvalid(message string) error  { return &changeFailure{"validation", message} }
func changeConflict(message string) error { return &changeFailure{"conflict", message} }

type changeCommitter func(context.Context, *pgx.Conn) error

func changes(ctx context.Context, conn *pgx.Conn, command protocol.Command) protocol.Response {
	return changesWithCommit(ctx, conn, command, func(ctx context.Context, conn *pgx.Conn) error {
		_, err := conn.Exec(ctx, "COMMIT")
		return err
	})
}

// The committer seam lets integration tests prove the outcome of a real COMMIT
// whose acknowledgement is lost, without sharing mutable production hooks.
func changesWithCommit(ctx context.Context, conn *pgx.Conn, command protocol.Command, commit changeCommitter) protocol.Response {
	started := time.Now()
	failure := func(err error, transaction bool) protocol.Response {
		if transaction {
			rollbackChanges(conn)
		}
		response := changeError(command, ctx, conn, err)
		response.DurationMS = float64(time.Since(started)) / float64(time.Millisecond)
		return response
	}
	if command.Changes == nil || !command.Changes.Valid() || (command.Type != "changes.preview" && command.Type != "changes.apply") {
		return failure(changeInvalid("The table changes are invalid."), false)
	}
	if conn.IsClosed() || transactionStatus(conn) != "idle" {
		return failure(changeInvalid("Table changes require a separate idle session."), false)
	}
	request := *command.Changes
	applying := command.Type == "changes.apply"
	if applying {
		if _, err := conn.Exec(ctx, "BEGIN ISOLATION LEVEL READ COMMITTED"); err != nil {
			return failure(err, true)
		}
		// DDL needs ACCESS EXCLUSIVE. Hold this lock before re-reading metadata,
		// including column order, primary key and generated-column information.
		name := pgx.Identifier{request.Schema, request.Table}.Sanitize()
		if _, err := conn.Exec(ctx, "LOCK TABLE "+name+" IN ROW EXCLUSIVE MODE"); err != nil {
			return failure(err, true)
		}
	}
	table, err := loadChangeTable(ctx, conn, request)
	if err != nil {
		return failure(err, applying)
	}
	statements, err := planChanges(table, request)
	if err != nil {
		return failure(err, applying)
	}
	if !applying {
		response := previewChanges(command, statements)
		response.DurationMS = float64(time.Since(started)) / float64(time.Millisecond)
		return response
	}
	for index, statement := range statements {
		change := request.Changes[index]
		if change.Kind != "insert" {
			if err := compareLockedRow(ctx, conn, table, change.Original); err != nil {
				return failure(err, true)
			}
		}
		values, err := changeParameters(statement.values)
		if err != nil {
			return failure(err, true)
		}
		reader := conn.PgConn().ExecParams(ctx, statement.sql, values, statement.types, nil, nil)
		tag, err := reader.Close()
		if err != nil {
			return failure(err, true)
		}
		if tag.RowsAffected() != 1 {
			return failure(changeConflict("A row disappeared, became inaccessible, or was not changed. No changes were committed."), true)
		}
	}
	if err := ctx.Err(); err != nil {
		return failure(err, true)
	}
	if err := commit(ctx, conn); err != nil {
		var server *pgconn.PgError
		if errors.As(err, &server) && server.Severity != "FATAL" && server.Severity != "PANIC" &&
			server.SeverityUnlocalized != "FATAL" && server.SeverityUnlocalized != "PANIC" && !strings.HasPrefix(server.Code, "08") && server.Code != "40003" {
			return failure(err, true)
		}
		// A transport/cancellation failure during COMMIT cannot prove whether
		// the transaction became durable. Never roll it back and then retry it.
		closeConnection(conn)
		response := protocol.ErrorResponse(command, "connection", "The COMMIT outcome is unknown. Check the affected rows before applying these changes again.")
		response.OutcomeUnknown = true
		response.DurationMS = float64(time.Since(started)) / float64(time.Millisecond)
		return response
	}
	return protocol.Response{Type: "query.result", RequestID: command.RequestID, SessionID: command.SessionID, QueryID: command.QueryID,
		Columns: []protocol.Column{}, Rows: [][]*string{}, CommandTag: fmt.Sprintf("APPLY %d", len(statements)),
		RowCount: int64(len(statements)), TransactionStatus: "idle", DurationMS: float64(time.Since(started)) / float64(time.Millisecond)}
}

func loadChangeTable(ctx context.Context, conn *pgx.Conn, request protocol.ChangesRequest) (changeTable, error) {
	table := changeTable{name: pgx.Identifier{request.Schema, request.Table}.Sanitize()}
	var kind string
	err := conn.QueryRow(ctx, `SELECT c.relkind::text, has_table_privilege(c.oid,'INSERT'),has_table_privilege(c.oid,'DELETE')
FROM pg_catalog.pg_class c JOIN pg_catalog.pg_namespace n ON n.oid=c.relnamespace
WHERE n.nspname=$1 AND c.relname=$2`, request.Schema, request.Table).Scan(&kind, &table.canInsert, &table.canDelete)
	if errors.Is(err, pgx.ErrNoRows) {
		return table, changeInvalid("The table is unavailable or access was denied.")
	}
	if err != nil {
		return table, err
	}
	if kind != "r" && kind != "p" {
		return table, changeInvalid("Only PostgreSQL base tables support data editing.")
	}
	rows, err := conn.Query(ctx, `SELECT a.attname::text, pg_catalog.format_type(a.atttypid,a.atttypmod),a.atttypid::bigint,
COALESCE((SELECT key.ordinality FROM pg_catalog.pg_index i CROSS JOIN LATERAL unnest(i.indkey) WITH ORDINALITY key(attnum,ordinality)
 WHERE i.indrelid=c.oid AND i.indisprimary AND i.indisvalid AND key.ordinality<=i.indnkeyatts AND key.attnum=a.attnum),0)::integer,
(a.attgenerated<>'' OR a.attidentity='a'),has_column_privilege(c.oid,a.attnum,'INSERT'),has_column_privilege(c.oid,a.attnum,'UPDATE')
FROM pg_catalog.pg_class c JOIN pg_catalog.pg_namespace n ON n.oid=c.relnamespace
JOIN pg_catalog.pg_attribute a ON a.attrelid=c.oid AND a.attnum>0 AND NOT a.attisdropped
WHERE n.nspname=$1 AND c.relname=$2 ORDER BY a.attnum`, request.Schema, request.Table)
	if err != nil {
		return table, err
	}
	defer rows.Close()
	for rows.Next() {
		var column changeColumn
		var oid int64
		if err := rows.Scan(&column.name, &column.nativeType, &oid, &column.primaryKey, &column.generated, &column.canInsert, &column.canUpdate); err != nil {
			return table, err
		}
		column.oid = uint32(oid)
		if !postgresChangeTypes[column.oid] {
			return table, changeInvalid("This table contains an unsupported type and is read only.")
		}
		table.columns = append(table.columns, column)
	}
	if err := rows.Err(); err != nil {
		return table, err
	}
	if len(table.columns) != len(request.Columns) {
		return table, changeConflict("The table structure changed. Reload the table before applying changes.")
	}
	primaryCount := 0
	for index, column := range table.columns {
		snapshot := request.Columns[index]
		if snapshot.Name != column.name || snapshot.Engine != "postgresql" || snapshot.NativeType != column.nativeType {
			return table, changeConflict("The table structure changed. Reload the table before applying changes.")
		}
		if column.primaryKey > primaryCount {
			primaryCount = column.primaryKey
		}
	}
	if primaryCount == 0 {
		return table, changeInvalid("The table has no primary key and is read only.")
	}
	table.primary = make([]int, primaryCount)
	for index := range table.primary {
		table.primary[index] = -1
	}
	for index, column := range table.columns {
		if column.primaryKey > 0 {
			table.primary[column.primaryKey-1] = index
		}
	}
	for _, index := range table.primary {
		if index < 0 {
			return table, changeInvalid("The table primary key is unavailable.")
		}
	}
	return table, nil
}

func planChanges(table changeTable, request protocol.ChangesRequest) ([]changeStatement, error) {
	byName := map[string]changeColumn{}
	for _, column := range table.columns {
		byName[column.name] = column
	}
	targets := map[string]bool{}
	statements := make([]changeStatement, 0, len(request.Changes))
	for _, change := range request.Changes {
		statement := changeStatement{operation: change.Kind, values: []protocol.CellValue{}, types: []uint32{}}
		bind := func(value protocol.CellValue, column changeColumn) string {
			statement.values = append(statement.values, value)
			statement.types = append(statement.types, column.oid)
			return "$" + strconv.Itoa(len(statement.values))
		}
		if change.Kind != "insert" {
			key := make([]protocol.CellValue, len(table.primary))
			for index, ordinal := range table.primary {
				key[index] = change.Original[ordinal]
			}
			encoded, _ := json.Marshal(key)
			if targets[string(encoded)] {
				return nil, changeInvalid("The same row cannot be changed twice in one Apply.")
			}
			targets[string(encoded)] = true
			for index, value := range change.Original {
				if err := validateChangeValue(value, table.columns[index], false); err != nil {
					return nil, err
				}
			}
		}
		names, expressions := []string{}, []string{}
		for _, assignment := range change.Values {
			column := byName[assignment.Column]
			if column.generated || (change.Kind == "insert" && !column.canInsert) || (change.Kind == "update" && !column.canUpdate) {
				return nil, changeInvalid("A generated column or a column without write permission cannot be changed.")
			}
			if err := validateChangeValue(assignment.Value, column, true); err != nil {
				return nil, err
			}
			names = append(names, pgx.Identifier{column.name}.Sanitize())
			if assignment.Value.Kind == "default" {
				expressions = append(expressions, "DEFAULT")
			} else {
				expressions = append(expressions, bind(assignment.Value, column))
			}
		}
		where := func() string {
			predicates := make([]string, len(table.primary))
			for index, ordinal := range table.primary {
				column := table.columns[ordinal]
				predicates[index] = pgx.Identifier{column.name}.Sanitize() + "=" + bind(change.Original[ordinal], column)
			}
			return strings.Join(predicates, " AND ")
		}
		switch change.Kind {
		case "insert":
			if len(names) == 0 && !table.canInsert {
				return nil, changeInvalid("INSERT permission is unavailable.")
			}
			statement.sql = "INSERT INTO " + table.name + " DEFAULT VALUES"
			if len(names) > 0 {
				statement.sql = "INSERT INTO " + table.name + " (" + strings.Join(names, ",") + ") VALUES (" + strings.Join(expressions, ",") + ")"
			}
		case "update":
			assignments := make([]string, len(names))
			for index := range names {
				assignments[index] = names[index] + "=" + expressions[index]
			}
			statement.sql = "UPDATE " + table.name + " SET " + strings.Join(assignments, ",") + " WHERE " + where()
		case "delete":
			if !table.canDelete {
				return nil, changeInvalid("DELETE permission is unavailable.")
			}
			statement.sql = "DELETE FROM " + table.name + " WHERE " + where()
		}
		statements = append(statements, statement)
	}
	return statements, nil
}

func validateChangeValue(value protocol.CellValue, column changeColumn, allowDefault bool) error {
	if !value.Valid(allowDefault) || value.Kind == "binary" && column.oid != 17 || value.Kind == "text" && column.oid == 17 {
		return changeInvalid("A change contains a value incompatible with its column type.")
	}
	return nil
}

func changeParameters(values []protocol.CellValue) ([][]byte, error) {
	parameters := make([][]byte, len(values))
	for index, value := range values {
		switch value.Kind {
		case "null":
		case "text":
			parameters[index] = []byte(*value.Value)
		case "binary":
			decoded, err := base64.StdEncoding.DecodeString(*value.Value)
			if err != nil {
				return nil, changeInvalid("A binary value is not valid Base64.")
			}
			parameters[index] = []byte("\\x" + hex.EncodeToString(decoded))
		default:
			return nil, changeInvalid("A parameter is not a concrete value.")
		}
	}
	return parameters, nil
}

func compareLockedRow(ctx context.Context, conn *pgx.Conn, table changeTable, original []protocol.CellValue) error {
	quoted := make([]string, len(table.columns))
	for index, column := range table.columns {
		quoted[index] = pgx.Identifier{column.name}.Sanitize()
	}
	values := make([]protocol.CellValue, len(table.primary))
	types := make([]uint32, len(table.primary))
	predicates := make([]string, len(table.primary))
	for index, ordinal := range table.primary {
		values[index], types[index] = original[ordinal], table.columns[ordinal].oid
		predicates[index] = quoted[ordinal] + "=$" + strconv.Itoa(index+1)
	}
	parameters, err := changeParameters(values)
	if err != nil {
		return err
	}
	reader := conn.PgConn().ExecParams(ctx, "SELECT "+strings.Join(quoted, ",")+" FROM "+table.name+" WHERE "+strings.Join(predicates, " AND ")+" FOR UPDATE", parameters, types, nil, nil)
	matched, rows := true, 0
	for reader.NextRow() {
		rows++
		for index, value := range reader.Values() {
			actual := protocol.CellValue{Kind: "null"}
			if value != nil {
				text := string(value)
				actual.Kind = "text"
				if table.columns[index].oid == 17 {
					decoded, binaryErr := decodeBytea(value)
					if binaryErr != nil {
						matched = false
						continue
					}
					actual.Kind, text = "binary", base64.StdEncoding.EncodeToString(decoded)
				}
				if !utf8.ValidString(text) {
					matched = false
					continue
				}
				actual.Value = &text
			}
			matched = matched && sameChangeCell(actual, original[index])
		}
	}
	_, err = reader.Close()
	if err != nil {
		return err
	}
	if rows != 1 || !matched {
		return changeConflict("A row was changed or deleted by another client. No changes were committed. Reload and compare the data.")
	}
	return nil
}

func sameChangeCell(lhs, rhs protocol.CellValue) bool {
	if lhs.Kind != rhs.Kind {
		return false
	}
	if lhs.Kind == "null" {
		return true
	}
	if lhs.Value == nil || rhs.Value == nil {
		return false
	}
	if lhs.Kind == "binary" {
		left, err1 := base64.StdEncoding.DecodeString(*lhs.Value)
		right, err2 := base64.StdEncoding.DecodeString(*rhs.Value)
		return err1 == nil && err2 == nil && bytes.Equal(left, right)
	}
	return *lhs.Value == *rhs.Value
}

func rollbackChanges(conn *pgx.Conn) {
	if conn.IsClosed() {
		return
	}
	ctx, cancel := context.WithTimeout(context.Background(), 5*time.Second)
	defer cancel()
	if _, err := conn.Exec(ctx, "ROLLBACK"); err != nil || transactionStatus(conn) != "idle" {
		closeConnection(conn)
	}
}

func changeError(command protocol.Command, ctx context.Context, conn *pgx.Conn, err error) protocol.Response {
	var failure *changeFailure
	if errors.As(err, &failure) {
		response := protocol.ErrorResponse(command, failure.category, failure.message)
		response.Connected = !conn.IsClosed()
		if response.Connected {
			response.TransactionStatus = transactionStatus(conn)
		}
		return response
	}
	response := queryError(command, ctx, conn, err)
	// No COMMIT was sent on this path. Even a lost ROLLBACK acknowledgement
	// cannot turn this explicit transaction into committed row changes.
	response.OutcomeUnknown, response.ErrorPosition = false, 0
	response.Message = "The table changes were not committed. Resolve the error and apply them again."
	if response.Category == "cancelled" {
		response.Message = "The table changes were cancelled. No changes were committed."
	} else if response.Category == "timeout" {
		response.Message = "The table changes timed out. No changes were committed."
	}
	return response
}

func previewChanges(command protocol.Command, statements []changeStatement) protocol.Response {
	response := protocol.Response{Type: "query.result", RequestID: command.RequestID, SessionID: command.SessionID, QueryID: command.QueryID,
		TransactionStatus: "idle", CommandTag: fmt.Sprintf("PREVIEW %d", len(statements)), RowCount: int64(len(statements)),
		Columns: []protocol.Column{{Index: 0, Name: "operation", Engine: "postgresql", NativeType: "text", TypeOID: 25},
			{Index: 1, Name: "sql", Engine: "postgresql", NativeType: "text", TypeOID: 25},
			{Index: 2, Name: "parameters", Engine: "postgresql", NativeType: "json", TypeOID: 114}}, Rows: [][]*string{}}
	for _, statement := range statements {
		parameters, _ := json.Marshal(statement.values)
		operation, sql, bindings := statement.operation, statement.sql, string(parameters)
		response.Rows = append(response.Rows, []*string{&operation, &sql, &bindings})
	}
	response.DisplayedRowCount = len(response.Rows)
	encoded, err := json.Marshal(response)
	if err != nil || len(encoded) > MaxResultBytes {
		response = protocol.ErrorResponse(command, "validation", "The change preview exceeds 8 MiB. Reduce the number or size of pending changes.")
		response.Connected, response.TransactionStatus = true, "idle"
	}
	return response
}
