package mariadb

import (
	"context"
	"errors"
	"strings"
	"time"

	"dbeer/helper/internal/protocol"
	ti "dbeer/helper/internal/tableimport"
)

type mariaDBImportTable struct {
	name, fingerprint string
	columns           []ti.Column
}

func loadMariaDBImportTable(execution *changeExecution, request protocol.TableImportRequest) (mariaDBImportTable, error) {
	table := mariaDBImportTable{name: QuoteIdentifier(request.Schema) + "." + QuoteIdentifier(request.Table)}
	meta, err := mariaDBBaseTable(execution, request.Schema, request.Table)
	if err != nil {
		return table, err
	}
	rows, err := mariaDBMetadataRows(execution, `SELECT COLUMN_NAME,COLUMN_TYPE,DATA_TYPE,IS_NULLABLE,COLUMN_DEFAULT,EXTRA,COALESCE(GENERATION_EXPRESSION,''),CHARACTER_SET_NAME,COLLATION_NAME,ORDINAL_POSITION,PRIVILEGES FROM information_schema.COLUMNS WHERE BINARY TABLE_SCHEMA=BINARY ? AND BINARY TABLE_NAME=BINARY ? ORDER BY ORDINAL_POSITION LIMIT 4097`, request.Schema, request.Table)
	if err != nil {
		return table, err
	}
	if len(rows) == 0 {
		return table, editFailure("validation", "The import table has no visible columns.")
	}
	for i, row := range rows {
		kind, extra, generated := rowText(row, 2), rowText(row, 5), rowText(row, 6)
		ordinal, ok := rowInt(row, 9)
		if !ok || ordinal != i+1 {
			return table, editFailure("validation", "The import table has incomplete ordered columns.")
		}
		serverGenerated := generated != "" || strings.Contains(strings.ToUpper(extra), "GENERATED")
		column := ti.Column{TableImportColumn: protocol.TableImportColumn{Name: rowText(row, 0), NativeType: rowText(row, 1), Nullable: rowText(row, 3) == "YES", HasDefault: row[4] != nil || strings.Contains(strings.ToLower(extra), "auto_increment") || serverGenerated, Generated: serverGenerated, Binary: mariaDBBinaryType(kind) || rowText(row, 7) == "binary" || (kind == "enum" || kind == "set") && rowText(row, 7) == ""}, Writable: strings.Contains(","+strings.ToLower(rowText(row, 10))+",", ",insert,"), Supported: MariaDBEditableKind(kind)}
		table.columns = append(table.columns, column)
	}
	if !ti.DescriptionValid(table.columns) {
		return table, editFailure("validation", "The import column metadata exceeds its supported bounds.")
	}
	periodColumns := make([]MariaDBPeriodColumn, len(rows))
	for i, row := range rows {
		periodColumns[i] = MariaDBPeriodColumn{Name: rowText(row, 0), NativeType: rowText(row, 1), DataType: rowText(row, 2), Generated: rowText(row, 6)}
	}
	periods, err := MariaDBSystemPeriods(execution.query, request.Schema, request.Table, rowText(meta[0], 0), periodColumns)
	if err != nil {
		return table, err
	}
	table.fingerprint, err = ti.MetadataFingerprint([]any{"mariadb", request.Schema, request.Table, meta, rows, periods})
	if err != nil {
		return table, editFailure("validation", "The import metadata exceeds its supported bounds.")
	}
	return table, nil
}

func mariaDBImportTemplate(table mariaDBImportTable, columns []ti.Column, scope mariaDBWriteScope) string {
	names, values := []string{}, []string{}
	for _, column := range columns {
		names = append(names, QuoteIdentifier(column.Name))
		values = append(values, "?")
	}
	return scope.wrap("INSERT INTO " + table.name + " (" + strings.Join(names, ",") + ") VALUES (" + strings.Join(values, ",") + ")")
}

func importFailure(err error) error {
	if errors.Is(err, ti.ErrInvalid) {
		return editFailure("validation", err.Error())
	}
	if errors.Is(err, ti.ErrConflict) {
		return editFailure("conflict", err.Error())
	}
	return err
}

func (session *Session) executeMariaDBTableImport(ctx context.Context, command protocol.Command) protocol.Response {
	session.mu.Lock()
	defer session.mu.Unlock()
	startedRows, currentRow := false, 0
	failure := func(err error) protocol.Response {
		response := session.changeError(command, ctx, importFailure(err))
		response.SQLNotExecuted = !startedRows
		return response
	}
	if command.TableImport == nil || !command.TableImport.Valid(command.Type) || !mariaDBNameValid(command.TableImport.Schema) || !mariaDBNameValid(command.TableImport.Table) {
		return failure(editFailure("validation", "Invalid MariaDB table import."))
	}
	if session.closed.Load() || session.TransactionStatus() != "idle" {
		return failure(editFailure("validation", "Import requires a separate idle session."))
	}
	ctx, cancel := context.WithTimeout(ctx, ExecuteTimeout)
	defer cancel()
	if deadline, ok := ctx.Deadline(); ok {
		_ = session.work.transport.SetDeadline(deadline.Add(RecoveryTimeout))
	}
	execution := session.newChangeExecution(ctx)
	defer func() {
		execution.finish()
		if !session.closed.Load() {
			_ = session.work.transport.SetDeadline(time.Time{})
		}
	}()
	rollback := func(cause error) protocol.Response {
		response := session.rollbackChanges(execution, command, importFailure(cause))
		response.SQLNotExecuted = !startedRows
		if currentRow > 0 {
			row := currentRow
			response.TableImport = &protocol.TableImportReply{Row: &row}
		}
		return response
	}
	scope, err := loadMariaDBWriteScope(execution)
	if err != nil {
		return failure(err)
	}
	request := *command.TableImport
	result, err := execution.query("BEGIN")
	if result != nil {
		result.Close()
	}
	if err != nil {
		return failure(err)
	}
	name := QuoteIdentifier(request.Schema) + "." + QuoteIdentifier(request.Table)
	result, err = execution.query(scope.wrap("SELECT * FROM " + name + " LIMIT 0"))
	if result != nil {
		result.Close()
	}
	if err != nil {
		return rollback(err)
	}
	table, err := loadMariaDBImportTable(execution, request)
	if err != nil {
		return rollback(err)
	}
	finishRead := func(reply *protocol.TableImportReply) protocol.Response {
		if err := scope.verify(execution); err != nil {
			return rollback(err)
		}
		execution.finish()
		result, err := session.work.client.Execute("ROLLBACK AND NO CHAIN NO RELEASE")
		if result != nil {
			result.Close()
		}
		if err != nil {
			session.Close()
			return failure(editFailure("connection", "The read-only import preview connection could not be recovered."))
		}
		session.updateTransaction()
		return protocol.Response{Type: command.Type + ".result", RequestID: command.RequestID, SessionID: command.SessionID, Connected: true, TransactionStatus: "idle", TableImport: reply}
	}
	if command.Type == "import.describe" {
		return finishRead(&protocol.TableImportReply{Columns: ti.ReplyColumns(table.columns), Fingerprint: table.fingerprint})
	}
	mapped, err := ti.Validate(table.columns, table.fingerprint, request)
	if err != nil {
		return rollback(err)
	}
	sql, count := mariaDBImportTemplate(table, mapped, scope), len(request.Rows)
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
				err = editFailure("validation", "The server reported a conversion warning or did not insert exactly one row. The import was not committed.")
			}
			result.Close()
		}
		if err != nil {
			return rollback(err)
		}
	}
	currentRow = 0
	if err := scope.verify(execution); err != nil {
		return rollback(err)
	}
	return session.commitRowBatch(execution, command, func() protocol.Response {
		return protocol.Response{Type: "import.apply.result", RequestID: command.RequestID, SessionID: command.SessionID, Connected: true, TransactionStatus: "idle", TableImport: &protocol.TableImportReply{RowCount: &count}}
	})
}
