package adapter

import "dbeer/helper/internal/protocol"

// SQL completion comes from the existing collector, never from plan row counts.
// TransactionPending covers transactional data only; sequences, nontransactional
// storage, triggers and external effects may not be reversible.
func ExplainDMLOutcome(p PreparedExplain, response protocol.Response) *protocol.ExplainDMLResult {
	if p.Request.Mode == "plan" && response.Type == "error" {
		return nil
	}
	if p.Preview.DML == nil || p.Request.Mode == "analyze" && p.Request.WriteIntent == nil {
		return nil
	}
	r := &protocol.ExplainDMLResult{Target: *p.Preview.DML, Execution: "estimated", Persistence: "notExecuted", AffectedRowsUnavailableReason: "notExecuted", TargetExecution: "notExecuted"}
	if p.Request.Mode == "plan" {
		return r
	}
	r.TransactionBefore = p.Request.WriteIntent.ExpectedTransactionStatus
	r.TransactionAfter = response.TransactionStatus
	acknowledged := response.AcknowledgedTransactionStatus == "idle" || response.AcknowledgedTransactionStatus == "transaction"
	if acknowledged && response.SQLCompleted {
		r.TransactionAfter = response.AcknowledgedTransactionStatus
	} else if response.Type == "error" && (response.OutcomeUnknown || !response.Connected) {
		r.TransactionAfter = "unknown"
	}
	if r.TransactionAfter != "idle" && r.TransactionAfter != "transaction" && r.TransactionAfter != "failedTransaction" {
		r.TransactionAfter = "unknown"
	}
	r.Execution = "unknown"
	r.TargetExecution = "unknown"
	r.Persistence = "unknown"
	r.AffectedRowsUnavailableReason = "notReported"
	if response.SQLNotExecuted {
		r.Execution = "notExecuted"
		r.TargetExecution = "notExecuted"
		r.Persistence = "notExecuted"
		r.AffectedRowsUnavailableReason = "notExecuted"
	} else if response.Type != "error" || response.SQLCompleted {
		// SQLCompleted proves execution only. A successful collector also drained
		// the final transaction acknowledgement; cleanup errors may lack it.
		r.Execution = "completed"
		r.TargetExecution = "executed"
		if p.Preview.Support.DML != nil && p.Preview.Support.DML.AnalyzeTargetExecution == "suppresses" {
			r.TargetExecution = "suppressed"
			r.Persistence = "notExecuted"
			return r
		}
		if (response.Type != "error" || acknowledged) && !response.OutcomeUnknown {
			if r.TransactionAfter == "idle" {
				r.Persistence = "committed"
			} else if r.TransactionAfter == "transaction" {
				r.Persistence = "transactionPending"
			}
		}
	} else if response.OutcomeUnknown || !response.Connected || r.TransactionAfter == "unknown" {
		r.Execution = "unknown"
	} else {
		r.Execution = "failed"
	}

	return r
}

// Recheck after every preflight: a reviewed idle/transaction state is part of
// write authority, not an instruction to start or finish a transaction.
func ExplainWriteContextMatches(r *protocol.ExplainRequest, status string) bool {
	return r == nil || r.WriteIntent == nil || r.Context != nil && r.WriteIntent.Valid() && r.Context.TransactionStatus == status && r.WriteIntent.ExpectedTransactionStatus == status
}
