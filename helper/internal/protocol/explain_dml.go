package protocol

import "encoding/json"

const ExplainDMLCapability = "explainDMLV1"

// CurrentSession performs exactly one execution and never controls the user's
// transaction. This is execution authority, never portable artifact authority.
type ExplainWriteIntent struct {
	Disposition               string `json:"disposition"`
	ExpectedTransactionStatus string `json:"expectedTransactionStatus"`
}

func (w ExplainWriteIntent) Valid() bool {
	return w.Disposition == "currentSession" && (w.ExpectedTransactionStatus == "idle" || w.ExpectedTransactionStatus == "transaction")
}
func parseExplainWriteIntent(raw json.RawMessage) (*ExplainWriteIntent, bool) {
	fields, ok := changesObject(raw, "disposition|expectedTransactionStatus", "disposition", "expectedTransactionStatus")
	if !ok {
		return nil, false
	}
	var w ExplainWriteIntent
	if !stringField(fields, "disposition", &w.Disposition) || !stringField(fields, "expectedTransactionStatus", &w.ExpectedTransactionStatus) {
		return nil, false
	}
	return &w, w.Valid()
}

type ExplainDMLSupport struct {
	AnalyzeTargetExecution string   `json:"analyzeTargetExecution"`
	Estimated              bool     `json:"estimated"`
	Analyze                []string `json:"analyze"`
}

func (s ExplainDMLSupport) Valid(engine string) bool {
	if !s.Estimated || s.Analyze == nil || len(s.Analyze) > 4 {
		return false
	}
	if len(s.Analyze) == 0 {
		if s.AnalyzeTargetExecution != "unavailable" {
			return false
		}
	} else if engine == "postgresql" {
		if s.AnalyzeTargetExecution != "executes" {
			return false
		}
	} else if engine == "mysql" {
		if s.AnalyzeTargetExecution != "suppresses" {
			return false
		}
	} else {
		return false
	}
	seen := map[string]bool{}
	for _, form := range s.Analyze {
		if seen[form] {
			return false
		}
		seen[form] = true
		if engine == "postgresql" {
			if form != "insert" && form != "update" && form != "delete" && form != "dataModifyingCTE" {
				return false
			}
		} else if engine == "mysql" {
			if form != "mysqlMultiTableUpdate" && form != "mysqlMultiTableDelete" {
				return false
			}
		} else {
			return false
		}
	}
	return engine == "postgresql" || engine == "mysql" || engine == "sqlite" && len(s.Analyze) == 0
}

type ExplainDMLTarget struct {
	Statement        string `json:"statement"`
	DataModifyingCTE bool   `json:"dataModifyingCTE"`
	MySQLMultiTable  bool   `json:"mysqlMultiTable"`
}

func (t ExplainDMLTarget) Valid(engine string) bool {
	return (t.Statement == "insert" || t.Statement == "update" || t.Statement == "delete" || t.Statement == "select" && t.DataModifyingCTE) && (!t.DataModifyingCTE || engine == "postgresql") && (!t.MySQLMultiTable || engine == "mysql" && (t.Statement == "update" || t.Statement == "delete")) && (engine == "postgresql" || engine == "mysql" || engine == "sqlite")
}

type ExplainDMLResult struct {
	TargetExecution               string           `json:"targetExecution"`
	Target                        ExplainDMLTarget `json:"target"`
	Execution                     string           `json:"execution"`
	Persistence                   string           `json:"persistence"`
	TransactionBefore             string           `json:"transactionBefore"`
	TransactionAfter              string           `json:"transactionAfter"`
	AffectedRowsUnavailableReason string           `json:"affectedRowsUnavailableReason"`
}

func (r ExplainDMLResult) Valid(engine, mode string) bool {
	if !r.Target.Valid(engine) {
		return false
	}
	if r.Execution == "estimated" {
		return mode == "plan" && r.TargetExecution == "notExecuted" && r.Persistence == "notExecuted" && r.TransactionBefore == "" && r.TransactionAfter == "" && r.AffectedRowsUnavailableReason == "notExecuted"
	}
	if mode != "analyze" || engine == "sqlite" || (r.TransactionBefore != "idle" && r.TransactionBefore != "transaction") || (r.TransactionAfter != "idle" && r.TransactionAfter != "transaction" && r.TransactionAfter != "failedTransaction" && r.TransactionAfter != "unknown") {
		return false
	}
	switch r.Execution {
	case "notExecuted":
		return r.TargetExecution == "notExecuted" && r.Persistence == "notExecuted" && r.AffectedRowsUnavailableReason == "notExecuted"
	case "completed":
		if engine == "mysql" {
			return r.TargetExecution == "suppressed" && r.Persistence == "notExecuted" && r.AffectedRowsUnavailableReason == "notReported"
		}
		return r.TargetExecution == "executed" && r.AffectedRowsUnavailableReason == "notReported" && (r.Persistence == "committed" && r.TransactionAfter == "idle" || r.Persistence == "transactionPending" && r.TransactionAfter == "transaction" || r.Persistence == "unknown")
	case "failed", "unknown":
		return r.TargetExecution == "unknown" && r.Persistence == "unknown" && r.AffectedRowsUnavailableReason == "notReported"
	}
	return false
}

func explainDMLForm(t ExplainDMLTarget) string {
	if t.DataModifyingCTE {
		return "dataModifyingCTE"
	}
	if t.MySQLMultiTable {
		if t.Statement == "update" {
			return "mysqlMultiTableUpdate"
		}
		return "mysqlMultiTableDelete"
	}
	return t.Statement
}
