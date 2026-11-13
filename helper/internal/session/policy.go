package session

import (
	"bytes"
	"crypto/rand"
	"encoding/hex"
	"encoding/json"

	"dbeer/helper/internal/adapter"
	"dbeer/helper/internal/protocol"
	"dbeer/helper/internal/queryparams"
	"dbeer/helper/internal/safety"
)

type operationGrant struct {
	token       string
	operations  []protocol.OperationRequest
	next        int
	preparedSQL []string
}

func (owner *owner) invalidateGrant() {
	owner.authMu.Lock()
	owner.grant = nil
	owner.approvedExplainSQL = ""
	owner.authMu.Unlock()
}

func assessOperation(engine string, operation protocol.OperationRequest) protocol.AssessedOperation {
	result := protocol.AssessedOperation{Kind: "read", Statements: []protocol.StatementAssessment{}}
	if operation.Type == "structure.apply" || operation.Type == "import.apply" {
		result.Kind = "write"
		return result
	}
	if operation.Type == "changes.apply" {
		result.Kind = "write"
		for _, change := range operation.Changes.Changes {
			if change.Kind == "delete" {
				result.Kind = "destructive"
			}
		}
		return result
	}
	sql := operation.SQL
	if operation.Type == "execute" && len(operation.Parameters) > 0 {
		bound, err := queryparams.Bind(engine, sql, operation.Parameters)
		if err != nil {
			result.Kind = "unknown"
			return result
		}
		sql = bound.AssessmentSQL
	}
	if operation.Type == "explain.run" && operation.Explain != nil {
		sql = operation.Explain.SQL
	}
	statements := safety.Classify(engine, sql)
	if len(statements) == 0 {
		result.Kind = "unknown"
	}
	for _, statement := range statements {
		kind := string(statement.Kind)
		result.Statements = append(result.Statements, protocol.StatementAssessment{Start: statement.Start, End: statement.End, Kind: kind, Reason: statement.Reason})
		if kind == "unknown" || result.Kind != "unknown" && (kind == "destructive" || kind == "write" && result.Kind == "read") {
			result.Kind = kind
		}
	}
	return result
}

func policyDecision(policy protocol.ExecutionPolicy, operation protocol.AssessedOperation) string {
	if policy.ReadOnly && operation.Kind != "read" {
		return "deny"
	}
	if operation.Kind == "destructive" || operation.Kind == "unknown" || policy.Environment == "production" && operation.Kind == "write" {
		return "confirm"
	}
	return "allow"
}

func (owner *owner) assess(command protocol.Command, engine string, policy protocol.ExecutionPolicy, sessions ...adapter.Session) protocol.Response {
	owner.authMu.Lock()
	defer owner.authMu.Unlock()
	owner.grant = nil
	owner.approvedExplainSQL = ""
	if owner.monitorOnly {
		return protocol.ErrorResponse(command, "policy", "This session is reserved for readonly monitoring.")
	}
	preparedSQL := []string{}
	assessment := &protocol.OperationAssessment{Decision: "allow", Policy: policy, Operations: []protocol.AssessedOperation{}}
	if len(sessions) > 0 {
		if files, ok := sessions[0].(interface{ SQLiteFiles() []string }); ok {
			assessment.SQLiteFiles = files.SQLiteFiles()
		}
	}
	for _, operation := range command.Operations {
		if operation.Type == "command.execute" {
			if len(sessions) == 0 {
				return rejectedCommand(command, "capability", "Native commands are unavailable for this adapter.")
			}
			if _, ok := sessions[0].(adapter.NativeCommandSession); !ok {
				return rejectedCommand(command, "capability", "Native commands are unavailable for this adapter.")
			}
		}
		if operation.Type == "execute" {
			if _, err := queryparams.Bind(engine, operation.SQL, operation.Parameters); err != nil {
				return protocol.ErrorResponse(command, "validation", err.Error())
			}
		}
		if !operation.Valid() {
			return protocol.ErrorResponse(command, "protocol", "Invalid operation assessment.")
		}
		if owner.importOnly && operation.Type != "import.apply" || !owner.importOnly && operation.Type == "import.apply" {
			return protocol.ErrorResponse(command, "policy", "Open a dedicated import session to review table imports.")
		}
		if owner.structureOnly && operation.Type != "structure.apply" {
			return protocol.ErrorResponse(command, "policy", "This session is reserved for the table structure editor.")
		}
		if operation.Type == "structure.apply" {
			if !owner.structureOnly {
				return protocol.ErrorResponse(command, "policy", "Open a dedicated structure session before reviewing DDL.")
			}
			if _, err := owner.structure.Resolve(*operation.Structure); err != nil {
				return protocol.ErrorResponse(command, "conflict", err.Error())
			}
		}
		item := owner.assessRetainedOperation(engine, operation, policy, sessions...)
		if operation.Type == "explain.run" {
			if len(sessions) == 0 {
				return protocol.ErrorResponse(command, "capability", "Visual Explain is unavailable.")
			}
			explain, ok := sessions[0].(adapter.ExplainSession)
			if !ok {
				return protocol.ErrorResponse(command, "capability", "Visual Explain is unavailable.")
			}
			prepared, err := explain.PrepareExplain(*operation.Explain)
			if err != nil {
				return protocol.ErrorResponse(command, "validation", err.Error())
			}
			item.Explain = &prepared.Preview
		}
		sql := ""
		if item.Explain != nil {
			sql = item.Explain.SQL
		}
		preparedSQL = append(preparedSQL, sql)
		assessment.Operations = append(assessment.Operations, item)
		decision := policyDecision(policy, item)
		if operation.Type == "explain.run" && operation.Explain.Mode == "analyze" && decision == "allow" {
			decision = "confirm"
		}
		if decision == "deny" || decision == "confirm" && assessment.Decision == "allow" {
			assessment.Decision = decision
		}
	}
	if len(assessment.Operations) == 0 || len(assessment.Operations) > 1024 {
		return protocol.ErrorResponse(command, "protocol", "Invalid operation assessment.")
	}
	if assessment.Decision != "deny" {
		var random [32]byte
		if _, err := rand.Read(random[:]); err != nil {
			return protocol.ErrorResponse(command, "policy", "Cannot prepare execution authorization.")
		}
		assessment.Authorization = hex.EncodeToString(random[:])
		encoded, _ := json.Marshal(command.Operations)
		var retained []protocol.OperationRequest
		_ = json.Unmarshal(encoded, &retained)
		owner.grant = &operationGrant{token: assessment.Authorization, operations: retained, preparedSQL: preparedSQL}
	}
	return protocol.Response{Type: "operation.assessment", RequestID: command.RequestID, SessionID: owner.id, QueryID: command.QueryID, Assessment: assessment}
}

func (owner *owner) authorize(command protocol.Command, engine string, policy protocol.ExecutionPolicy, sessions ...adapter.Session) bool {
	if owner.monitorOnly {
		return command.Type == "monitor.snapshot" || command.Type == "monitor.schema"
	}
	if command.Type != "execute" && command.Type != "command.execute" && command.Type != "explain.run" && command.Type != "changes.apply" && command.Type != "structure.apply" && command.Type != "import.apply" {
		return true
	}
	if owner.structureOnly && command.Type != "structure.apply" || command.Type != "structure.apply" && command.Structure != nil {
		owner.invalidateGrant()
		return false
	}
	if owner.importOnly && command.Type != "import.apply" || !owner.importOnly && command.Type == "import.apply" {
		owner.invalidateGrant()
		return false
	}
	operation := protocol.OperationRequest{NativeCommand: command.NativeCommand, TableImport: command.TableImport, Type: command.Type, SQL: command.SQL, Parameters: command.Parameters, Export: command.Export, Changes: command.Changes, Explain: command.Explain}
	if command.Type == "command.execute" {
		if command.SessionID != owner.id {
			owner.invalidateGrant()
			return false
		}
		operation.QueryID = command.QueryID
	}
	if command.Type == "structure.apply" {
		if !owner.structureOnly || command.Structure == nil || !command.Structure.Valid(command.Type) || command.Structure.Apply == nil {
			owner.invalidateGrant()
			return false
		}
		operation.Structure = command.Structure.Apply
		if _, err := owner.structure.Resolve(*operation.Structure); err != nil {
			owner.invalidateGrant()
			return false
		}
	}
	if operation.Type == "execute" {
		if _, err := queryparams.Bind(engine, operation.SQL, operation.Parameters); err != nil {
			owner.invalidateGrant()
			return false
		}
	}
	if !operation.Valid() {
		owner.invalidateGrant()
		return false
	}
	owner.authMu.Lock()
	defer owner.authMu.Unlock()
	if policyDecision(policy, owner.assessRetainedOperation(engine, operation, policy, sessions...)) == "deny" {
		owner.grant = nil
		return false
	}
	if command.Authorization == "" {
		if command.Type == "structure.apply" {
			owner.grant = nil
			return false
		}
		owner.grant = nil
		return command.Type != "command.execute" && command.Type != "explain.run" && policyDecision(policy, owner.assessRetainedOperation(engine, operation, policy, sessions...)) == "allow"
	}
	grant := owner.grant
	if grant == nil || grant.token != command.Authorization || grant.next >= len(grant.operations) {
		owner.grant = nil
		return false
	}
	expected, _ := json.Marshal(grant.operations[grant.next])
	actual, _ := json.Marshal(operation)
	if !bytes.Equal(expected, actual) {
		owner.grant = nil
		return false
	}
	if command.Type == "explain.run" {
		if grant.next >= len(grant.preparedSQL) || grant.preparedSQL[grant.next] == "" {
			owner.grant = nil
			return false
		}
		owner.approvedExplainSQL = grant.preparedSQL[grant.next]
	}
	grant.next++
	if grant.next == len(grant.operations) {
		owner.grant = nil
	}
	return true
}

func (owner *owner) takeApprovedExplainSQL() string {
	owner.authMu.Lock()
	defer owner.authMu.Unlock()
	sql := owner.approvedExplainSQL
	owner.approvedExplainSQL = ""
	return sql
}

func (owner *owner) assessRetainedOperation(engine string, operation protocol.OperationRequest, policy protocol.ExecutionPolicy, sessions ...adapter.Session) protocol.AssessedOperation {
	result := assessOperation(engine, operation)
	if operation.Type == "command.execute" {
		result.Kind, result.Statements = "unknown", []protocol.StatementAssessment{}
		if operation.NativeCommand != nil && len(sessions) > 0 {
			if native, ok := sessions[0].(adapter.NativeCommandSession); ok {
				switch kind := native.ClassifyNativeCommand(*operation.NativeCommand); kind {
				case "read", "write", "destructive":
					result.Kind = kind
				}
			}
		}
		return result
	}
	if policy.ReadOnly && len(sessions) > 0 {
		if readonly, ok := sessions[0].(adapter.ReadOnlyOperationSession); ok && readonly.IsReadOnlyOperation(operation) {
			result.Kind = "read"
			for i := range result.Statements {
				result.Statements[i].Kind = "read"
				result.Statements[i].Reason = "adapter_readonly_session_operation"
			}
		}
	}
	if operation.Type == "structure.apply" && operation.Structure != nil {
		if plan, err := owner.structure.Resolve(*operation.Structure); err == nil && plan.Destructive {
			result.Kind = "destructive"
		}
	}
	return result
}
