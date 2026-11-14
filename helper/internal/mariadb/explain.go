package mariadb

import (
	"context"
	"errors"

	"dbeer/helper/internal/adapter"
	"dbeer/helper/internal/protocol"
	wire "github.com/go-mysql-org/go-mysql/mysql"
)

func (s *Session) ExplainSupport() protocol.ExplainSupport {
	version, comment, identity := s.nativeServerObservation()
	support := protocol.ExplainSupport{Engine: "mariadb", ServerVersion: version, Format: "json", Modes: []string{}}
	if identity == "" || !supportedNativeVersion(version, comment) {
		support.UnavailableReason = "Visual Explain requires a verified MariaDB 10.11.9+ or 11.4.3+ physical session."
		return support
	}
	support.Modes = []string{"plan", "analyze"}
	support.DML = &protocol.ExplainDMLSupport{Estimated: true,
		EstimatedForms: []string{"update", "delete", "mysqlMultiTableUpdate", "mysqlMultiTableDelete"},
		Analyze:        []string{"update", "delete", "mysqlMultiTableUpdate", "mysqlMultiTableDelete"}, AnalyzeTargetExecution: "executes"}
	return support
}

func (s *Session) PrepareExplain(r protocol.ExplainRequest) (adapter.PreparedExplain, error) {
	return adapter.PrepareExplain(s.ExplainSupport(), r)
}

func (s *Session) ExecuteExplain(ctx context.Context, command protocol.Command) protocol.Response {
	if command.Explain == nil {
		response := protocol.ErrorResponse(command, "validation", "A current MariaDB Explain request is required.")
		response.SQLNotExecuted, response.Connected, response.TransactionStatus = true, !s.closed.Load(), s.TransactionStatus()
		return response
	}
	prepared, err := s.PrepareExplain(*command.Explain)
	if err == nil && prepared.Preview.SQL != command.PreparedExplainSQL {
		err = errors.New("Explain requires fresh authorization of the exact prepared SQL.")
	}
	if err != nil {
		response := protocol.ErrorResponse(command, "validation", err.Error())
		response.SQLNotExecuted, response.Connected, response.TransactionStatus = true, !s.closed.Load(), s.TransactionStatus()
		response.ExplainDML = adapter.ExplainDMLOutcome(prepared, response)
		return response
	}
	capture := &adapter.ExplainCapture{}
	sent := false
	response := s.executeWith(ctx, command, func(collector *collector, result *wire.Result) error {
		s.updateTransaction()
		if !adapter.ExplainWriteContextMatches(command.Explain, s.TransactionStatus()) {
			return &adapter.ConnectionError{Category: "conflict", Message: "The DML Analyze transaction context changed before dispatch. Review it again."}
		}
		if err := ctx.Err(); err != nil {
			return &adapter.ConnectionError{Category: "cancelled", Message: "Explain was cancelled before the statement was sent."}
		}
		sent = true
		if len(prepared.Bound.Parameters) > 0 {
			bound := prepared.Bound
			bound.SQL = prepared.Preview.SQL
			return s.executeBoundResults(bound, collector, result)
		}
		// One server execution, with the native MariaDB prefix. Parsing failure
		// retains raw evidence; it never authorizes a second Analyze or format.
		return s.executeResults(prepared.Preview.SQL, collector, result)
	}, capture)
	if !sent && response.Type == "error" {
		response.SQLNotExecuted = true
		response.OutcomeUnknown = false
	}
	if response.Type != "error" {
		response.Connected = !s.closed.Load()
	}
	return adapter.FinishExplain(ctx, command, response, prepared, capture, parseMariaDBExplainJSON)
}
