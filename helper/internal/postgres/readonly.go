package postgres

import (
	"context"
	"errors"

	"dbeer/helper/internal/protocol"
)

func (session *Session) SetReadOnly(ctx context.Context, enabled bool) error {
	if session.TransactionStatus() != "idle" {
		return errors.New("Finish the current transaction before changing read-only mode.")
	}
	sql := "SET SESSION CHARACTERISTICS AS TRANSACTION READ WRITE"
	if enabled {
		sql = "SET SESSION CHARACTERISTICS AS TRANSACTION READ ONLY"
	}
	ctx, cancel := context.WithTimeout(ctx, ExecuteTimeout)
	defer cancel()
	// Use the normal bounded execution and cancellation recovery path. A lost
	// response must never be interpreted as successfully installing the mode.
	response := session.Execute(ctx, protocol.Command{SQL: sql})
	if response.Type != "query.result" || response.TransactionStatus != "idle" || response.OutcomeUnknown {
		return errors.New("PostgreSQL read-only mode could not be configured.")
	}
	return nil
}
