package mysql

import (
	"context"
	"errors"
	"strings"
	"time"

	"dbeer/helper/internal/protocol"
	ti "dbeer/helper/internal/tableimport"
	wire "github.com/go-mysql-org/go-mysql/mysql"
)

type mysqlImportTable struct {
	name, fingerprint string
	columns           []ti.Column
}

func mysqlImportRows(execution *changeExecution, sql string, args ...any) ([][]*string, error) {
	result, err := execution.query(sql, args...)
	if err != nil {
		return nil, err
	}
	defer result.Close()
	if result.RowNumber() > 4096 {
		return nil, editFailure("validation", "The import table has too many columns.")
	}
	rows := make([][]*string, result.RowNumber())
	metadataBytes := 0
	for i := range rows {
		rows[i] = make([]*string, len(result.Fields))
		for j := range result.Fields {
			if result.Values[i][j].Type == wire.FieldValueTypeNull {
				continue
			}
			value, err := result.GetString(i, j)
			if err != nil {
				return nil, err
			}
			metadataBytes += len(value)
			if len(value) > 1024*1024 || metadataBytes > 4*1024*1024 {
				return nil, editFailure("validation", "Import metadata exceeds its size limit.")
			}
			value = strings.Clone(value)
			rows[i][j] = &value
		}
	}
	return rows, nil
}

func loadMySQLImportTable(execution *changeExecution, request protocol.TableImportRequest) (mysqlImportTable, error) {
	table := mysqlImportTable{name: QuoteIdentifier(request.Schema) + "." + QuoteIdentifier(request.Table)}
	meta, err := mysqlImportRows(execution, `SELECT TABLE_TYPE,ENGINE,TABLE_COLLATION,CREATE_OPTIONS,CAST(CREATE_TIME AS CHAR) FROM information_schema.TABLES WHERE TABLE_SCHEMA=? AND TABLE_NAME=? LIMIT 2`, request.Schema, request.Table)
	if err != nil {
		return table, err
	}
	if len(meta) != 1 || myText(meta[0], 0) != "BASE TABLE" || myText(meta[0], 1) != "InnoDB" {
		return table, editFailure("validation", "Import supports MySQL InnoDB base tables.")
	}
	rows, err := mysqlImportRows(execution, `SELECT COLUMN_NAME,COLUMN_TYPE,DATA_TYPE,IS_NULLABLE,COLUMN_DEFAULT,EXTRA,COALESCE(GENERATION_EXPRESSION,''),CHARACTER_SET_NAME,COLLATION_NAME,ORDINAL_POSITION,PRIVILEGES FROM information_schema.COLUMNS WHERE TABLE_SCHEMA=? AND TABLE_NAME=? ORDER BY ORDINAL_POSITION LIMIT 4097`, request.Schema, request.Table)
	if err != nil {
		return table, err
	}
	if len(rows) == 0 {
		return table, editFailure("validation", "The import table has no visible columns.")
	}
	for _, row := range rows {
		dataType, extra, generated := myText(row, 2), myText(row, 5), myText(row, 6)
		column := ti.Column{TableImportColumn: protocol.TableImportColumn{Name: myText(row, 0), NativeType: myText(row, 1), Nullable: myText(row, 3) == "YES", HasDefault: row[4] != nil || strings.Contains(extra, "auto_increment") || generated != "", Generated: generated != "" || strings.Contains(extra, "VIRTUAL GENERATED") || strings.Contains(extra, "STORED GENERATED"), Binary: binaryType(dataType) || myText(row, 7) == "binary"}, Writable: strings.Contains(","+strings.ToLower(myText(row, 10))+",", ",insert,"), Supported: supportedMySQLImportType(dataType)}
		table.columns = append(table.columns, column)
	}
	if !ti.DescriptionValid(table.columns) {
		return table, editFailure("validation", "Import metadata exceeds its size limit.")
	}
	table.fingerprint, err = ti.MetadataFingerprint([]any{request.Schema, request.Table, meta, rows})
	if err != nil {
		return table, editFailure("validation", "Import metadata exceeds its size limit.")
	}
	return table, nil
}

func supportedMySQLImportType(kind string) bool {
	switch kind {
	case "tinyint", "smallint", "mediumint", "int", "bigint", "decimal", "numeric", "float", "double", "bit", "char", "varchar", "tinytext", "text", "mediumtext", "longtext", "binary", "varbinary", "tinyblob", "blob", "mediumblob", "longblob", "date", "datetime", "timestamp", "time", "year", "json", "enum", "set":
		return true
	}
	return false
}

func mysqlImportTemplate(table mysqlImportTable, columns []ti.Column) string {
	names, values := []string{}, []string{}
	for _, c := range columns {
		names = append(names, QuoteIdentifier(c.Name))
		values = append(values, "?")
	}
	return "INSERT INTO " + table.name + " (" + strings.Join(names, ",") + ") VALUES (" + strings.Join(values, ",") + ")"
}

func (session *Session) executeTableImport(ctx context.Context, command protocol.Command) protocol.Response {
	session.mu.Lock()
	defer session.mu.Unlock()
	startedRows, currentRow := false, 0
	failure := func(err error) protocol.Response {
		if errors.Is(err, ti.ErrInvalid) {
			err = editFailure("validation", err.Error())
		} else if errors.Is(err, ti.ErrConflict) {
			err = editFailure("conflict", err.Error())
		}
		response := session.changeError(command, ctx, err)
		// This closure is used only before any COMMIT is attempted. Transport
		// loss while configuring/reading the import session cannot commit rows.
		response.OutcomeUnknown = false
		if response.Message == "MySQL session could not be recovered. The command outcome is unknown." {
			response.Message = "The import connection closed. No imported rows were committed."
		}
		response.SQLNotExecuted = !startedRows
		return response
	}
	if command.TableImport == nil || !command.TableImport.Valid(command.Type) {
		return failure(editFailure("validation", "Invalid table import."))
	}
	if session.closed.Load() || session.TransactionStatus() != "idle" {
		return failure(editFailure("validation", "Import requires a dedicated idle session."))
	}
	ctx, cancel := context.WithTimeout(ctx, ExecuteTimeout)
	defer cancel()
	if deadline, ok := ctx.Deadline(); ok {
		_ = session.work.transport.SetDeadline(deadline.Add(RecoveryTimeout))
	}
	execution := session.newChangeExecution(ctx)
	defer execution.finish()
	defer func() {
		if !session.closed.Load() {
			_ = session.work.transport.SetDeadline(time.Time{})
		}
	}()
	rollback := func(cause error) protocol.Response {
		if errors.Is(cause, ti.ErrInvalid) {
			cause = editFailure("validation", cause.Error())
		} else if errors.Is(cause, ti.ErrConflict) {
			cause = editFailure("conflict", cause.Error())
		}
		response := session.rollbackChanges(execution, command, cause)
		// Generated import SQL never sends COMMIT before this branch. An
		// InnoDB connection loss therefore cannot commit these inserted rows.
		response.OutcomeUnknown = false
		response.SQLNotExecuted = !startedRows
		if response.Message == "MySQL session could not be recovered. The command outcome is unknown." {
			response.Message = "The import connection closed. No imported rows were committed."
		}
		if currentRow > 0 {
			row := currentRow
			response.TableImport = &protocol.TableImportReply{Row: &row}
		}
		return response
	}
	// These settings affect only this dedicated import connection. Strict
	// conversion and warnings make silent truncation/coercion a batch failure.
	result, err := execution.query("SET SESSION sql_mode=CONCAT_WS(',',@@SESSION.sql_mode,'STRICT_ALL_TABLES','NO_ZERO_DATE','NO_ZERO_IN_DATE','ERROR_FOR_DIVISION_BY_ZERO'), explicit_defaults_for_timestamp=ON, time_zone='+00:00', lock_wait_timeout=5, innodb_lock_wait_timeout=5")
	if result != nil {
		result.Close()
	}
	if err != nil {
		return failure(err)
	}
	result, err = execution.query("BEGIN")
	if result != nil {
		result.Close()
	}
	if err != nil {
		return rollback(err)
	}
	request := *command.TableImport
	// Open the actual target within the transaction to retain its metadata
	// lock, then re-read every column/default/engine fact under that lock.
	name := QuoteIdentifier(request.Schema) + "." + QuoteIdentifier(request.Table)
	result, err = execution.query("SELECT * FROM " + name + " LIMIT 0")
	if result != nil {
		result.Close()
	}
	if err != nil {
		return rollback(err)
	}
	table, err := loadMySQLImportTable(execution, request)
	if err != nil {
		return rollback(err)
	}
	finishRead := func(reply *protocol.TableImportReply) protocol.Response {
		if err := ctx.Err(); err != nil {
			return rollback(err)
		}
		execution.finish()
		result, err := session.work.client.Execute("ROLLBACK")
		if result != nil {
			result.Close()
		}
		if err != nil {
			session.Close()
			response := failure(editFailure("connection", "The import session could not be recovered."))
			return response
		}
		session.updateTransaction()
		return protocol.Response{Type: command.Type + ".result", Connected: true, TransactionStatus: "idle", TableImport: reply}
	}
	if command.Type == "import.describe" {
		return finishRead(&protocol.TableImportReply{Columns: ti.ReplyColumns(table.columns), Fingerprint: table.fingerprint})
	}
	mapped, err := ti.Validate(table.columns, table.fingerprint, request)
	if err != nil {
		return rollback(err)
	}
	sql, count := mysqlImportTemplate(table, mapped), len(request.Rows)
	if command.Type == "import.preview" {
		return finishRead(&protocol.TableImportReply{Fingerprint: table.fingerprint, RowCount: &count, SQL: sql})
	}
	for i, row := range request.Rows {
		currentRow = i + 1
		args, err := bindCells(row)
		if err != nil {
			return rollback(err)
		}
		startedRows = true
		result, err = execution.query(sql, args...)
		if result != nil {
			if err == nil && (result.Warnings != 0 || result.AffectedRows != 1) {
				err = editFailure("validation", "The server reported a conversion warning or did not insert exactly one row. No imported rows were committed.")
			}
			result.Close()
		}
		if err != nil {
			return rollback(err)
		}
	}
	currentRow = 0
	if err := ctx.Err(); err != nil {
		return rollback(err)
	}
	commit := func() error {
		result, err := execution.query("COMMIT")
		if result != nil {
			result.Close()
		}
		return err
	}
	if session.commitOverride != nil {
		err = session.commitOverride(commit)
	} else {
		err = commit()
	}
	if err != nil {
		execution.finish()
		session.Close()
		response := protocol.ErrorResponse(command, "connection", "The import COMMIT outcome is unknown. Verify the table before importing again.")
		response.OutcomeUnknown = true
		return response
	}
	execution.finish()
	session.updateTransaction()
	return protocol.Response{Type: "import.apply.result", Connected: true, TransactionStatus: "idle", TableImport: &protocol.TableImportReply{RowCount: &count}}
}
