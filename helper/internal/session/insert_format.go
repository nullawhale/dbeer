package session

import (
	"encoding/json"

	"dbeer/helper/internal/insertformat"
	"dbeer/helper/internal/mysql"
	"dbeer/helper/internal/postgres"
	"dbeer/helper/internal/protocol"
)

// Offline formatting is routed before session lookup and never reaches an
// owner, connection opener, execution policy or database command queue.
func formatInserts(command protocol.Command) protocol.Response {
	if command.Insert == nil || !command.Insert.Valid() || command.SessionID != "" || command.QueryID != "" {
		return protocol.ErrorResponse(command, "validation", insertformat.ErrInvalid.Error())
	}
	var sql string
	var err error
	switch command.Insert.Engine {
	case "postgresql":
		sql, err = postgres.FormatInserts(*command.Insert)
	case "mysql":
		sql, err = mysql.FormatInserts(*command.Insert)
	}
	if err != nil {
		return protocol.ErrorResponse(command, "validation", err.Error())
	}
	response := protocol.Response{Type: "insertSQL", RequestID: command.RequestID, SQL: sql}
	frame, err := json.Marshal(response)
	if err != nil || len(frame) > protocol.MaxFrameBytes {
		return protocol.ErrorResponse(command, "validation", insertformat.ErrTooLarge.Error())
	}
	return response
}
