package session

import (
	"bytes"
	"crypto/rand"
	"encoding/hex"
	"encoding/json"

	"dbeer/helper/internal/adapter"
	"dbeer/helper/internal/protocol"
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
	if operation.Type == "structure.apply" {
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
	preparedSQL := []string{}
	assessment := &protocol.OperationAssessment{Decision: "allow", Policy: policy, Operations: []protocol.AssessedOperation{}}
	for _, operation := range command.Operations {
		if !operation.Valid() {
			return protocol.ErrorResponse(command, "protocol", "Invalid operation assessment.")
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
		item := owner.assessRetainedOperation(engine, operation)
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
		owner.grant = &operationGrant{token: assessment.Authorization, operations: command.Operations, preparedSQL: preparedSQL}
	}
	return protocol.Response{Type: "operation.assessment", RequestID: command.RequestID, SessionID: owner.id, QueryID: command.QueryID, Assessment: assessment}
}

func (owner *owner) authorize(command protocol.Command, engine string, policy protocol.ExecutionPolicy) bool {
	if command.Type != "execute" && command.Type != "explain.run" && command.Type != "changes.apply" && command.Type != "structure.apply" {
		return true
	}
	if owner.structureOnly && command.Type != "structure.apply" || command.Type != "structure.apply" && command.Structure != nil {
		owner.invalidateGrant()
		return false
	}
	operation := protocol.OperationRequest{Type: command.Type, SQL: command.SQL, Export: command.Export, Changes: command.Changes, Explain: command.Explain}
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
	if !operation.Valid() {
		owner.invalidateGrant()
		return false
	}
	owner.authMu.Lock()
	defer owner.authMu.Unlock()
	if policyDecision(policy, owner.assessRetainedOperation(engine, operation)) == "deny" {
		owner.grant = nil
		return false
	}
	if command.Authorization == "" {
		if command.Type == "structure.apply" {
			owner.grant = nil
			return false
		}
		owner.grant = nil
		return command.Type != "explain.run" && policyDecision(policy, owner.assessRetainedOperation(engine, operation)) == "allow"
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

func (owner *owner) assessRetainedOperation(engine string, operation protocol.OperationRequest) protocol.AssessedOperation {
	result := assessOperation(engine, operation)
	if operation.Type == "structure.apply" && operation.Structure != nil {
		if plan, err := owner.structure.Resolve(*operation.Structure); err == nil && plan.Destructive {
			result.Kind = "destructive"
		}
	}
	return result
}
