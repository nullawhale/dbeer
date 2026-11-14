package mariadb

import (
	"context"

	"dbeer/helper/internal/protocol"
	wire "github.com/go-mysql-org/go-mysql/mysql"
)

func mariadbStorageToken(values []wire.FieldValue) (string, error) {
	return MariaDBStorageToken(values)
}

func (s *Session) featureUnavailable(command protocol.Command) protocol.Response {
	response := protocol.ErrorResponse(command, "unsupported", "This MariaDB feature is not implemented in this private stage. No SQL was executed.")
	response.SQLNotExecuted = command.Type == "execute" || command.Type == "explain.run"
	response.Connected, response.TransactionStatus = !s.closed.Load(), s.TransactionStatus()
	return response
}

func (s *Session) ExecuteChanges(ctx context.Context, command protocol.Command) protocol.Response {
	return s.executeMariaDBChanges(ctx, command)
}
func (s *Session) executeTableImport(ctx context.Context, command protocol.Command) protocol.Response {
	return s.executeMariaDBTableImport(ctx, command)
}
