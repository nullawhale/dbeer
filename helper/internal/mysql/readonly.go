package mysql

import (
	"context"
	"errors"

	"dbeer/helper/internal/protocol"
)

func (session *Session) SetReadOnly(ctx context.Context, enabled bool) error {
	if session.TransactionStatus() != "idle" {
		return errors.New("Finish the current transaction before changing read-only mode.")
	}
	sql := "SET SESSION TRANSACTION READ WRITE"
	if enabled {
		sql = "SET SESSION TRANSACTION READ ONLY"
	}
	response := session.Execute(ctx, protocol.Command{SQL: sql})
	if response.Type != "query.result" || response.TransactionStatus != "idle" || response.OutcomeUnknown {
		return errors.New("MySQL read-only mode could not be configured.")
	}
	return nil
}
