package session

import (
	"context"
	"encoding/json"
	"unicode/utf8"

	"dbeer/helper/internal/adapter"
	"dbeer/helper/internal/protocol"
)

func nativeCommandAvailable(physical adapter.Session, command protocol.Command) bool {
	_, ok := physical.(adapter.NativeCommandSession)
	return ok && command.NativeCommand != nil && command.NativeCommand.Valid() && command.ResultValues == protocol.NativeResultValuesFormat && !command.Stream && command.Export == nil
}

// The existing session owner admits, authorizes, starts and cancels this work.
func runNativeCommand(ctx context.Context, physical adapter.Session, command protocol.Command) protocol.Response {
	if !nativeCommandAvailable(physical, command) {
		return rejectedCommand(command, "capability", "Native commands are unavailable for this adapter.")
	}
	response := physical.(adapter.NativeCommandSession).ExecuteNativeCommand(ctx, command)
	correlated := response.RequestID == command.RequestID && response.SessionID == command.SessionID && response.QueryID == command.QueryID
	valid := correlated && response.Type == "error" && len(response.Message) <= 1024 && utf8.ValidString(response.Message)
	if correlated && response.Type == "query.result" {
		displayBudget := 0
		valid = nativeCommandRowsValid(response.Columns, response.Rows, response.NativeValues, response.DisplayedRowCount, &displayBudget) && response.RowCount >= 0 &&
			nativeCommandTextValid(&displayBudget, response.CommandTag, response.DisplayNotice, response.TransactionStatus) &&
			response.Source == nil && response.SQLiteValues == nil && response.StorageTokens == nil && response.SQL == "" && !response.Streamed
		var budget protocol.NativeMatrixBudget
		for _, row := range response.NativeValues {
			valid = budget.Append(row, len(response.Columns)) && valid
		}
		if len(response.ResultSets) > 16 {
			valid = false
		}
		for _, set := range response.ResultSets {
			valid = nativeCommandRowsValid(set.Columns, set.Rows, set.NativeValues, set.DisplayedRowCount, &displayBudget) && set.RowCount >= 0 &&
				nativeCommandTextValid(&displayBudget, set.CommandTag, set.DisplayNotice) && set.Source == nil && set.SQLiteValues == nil && set.StorageTokens == nil && valid
			for _, row := range set.NativeValues {
				valid = budget.Append(row, len(set.Columns)) && valid
			}
		}
	}
	if !valid {
		return nativeCommandUnavailable(physical, command, response, correlated)
	}
	encoded, err := json.Marshal(response)
	if valid && err == nil && len(encoded) <= displayBytes {
		return response
	}
	return nativeCommandUnavailable(physical, command, response, correlated)
}

func nativeCommandUnavailable(physical adapter.Session, command protocol.Command, response protocol.Response, correlated bool) protocol.Response {
	failure := protocol.ErrorResponse(command, "protocol", "The native command response is unavailable. Inspect its outcome before retrying.")
	failure.Connected, failure.TransactionStatus = true, physical.TransactionStatus()
	failure.SQLCompleted = correlated && response.Type == "query.result"
	failure.OutcomeUnknown = !failure.SQLCompleted
	return failure
}

func nativeCommandRowsValid(columns []protocol.Column, rows [][]*string, native [][]protocol.NativeValue, displayed int, budget *int) bool {
	if native == nil || displayed != len(rows) || len(rows) > displayRows || !protocol.NativeMatrixValid(native, len(rows), len(columns)) {
		return false
	}
	for index, column := range columns {
		if column.Index != index || column.Encoding != "" && column.Encoding != "base64" || !nativeCommandTextValid(budget, column.Name, column.Engine, column.NativeType, column.TypeIdentity, column.Encoding) {
			return false
		}
	}
	for _, row := range rows {
		if len(row) != len(columns) {
			return false
		}
		for _, value := range row {
			if value != nil && !nativeCommandTextValid(budget, *value) {
				return false
			}
		}
	}
	return true
}

func nativeCommandTextValid(budget *int, values ...string) bool {
	for _, value := range values {
		if len(value) > displayBytes-*budget || !utf8.ValidString(value) {
			return false
		}
		*budget += len(value)
	}
	return true
}
