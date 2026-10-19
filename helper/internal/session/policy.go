package session

import (
	"bytes"
	"crypto/rand"
	"encoding/hex"
	"encoding/json"

	"dbeer/helper/internal/protocol"
	"dbeer/helper/internal/safety"
)

type operationGrant struct {
	token      string
	operations []protocol.OperationRequest
	next       int
}

func (owner *owner) invalidateGrant() {
	owner.authMu.Lock()
	owner.grant = nil
	owner.authMu.Unlock()
}

func assessOperation(engine string, operation protocol.OperationRequest) protocol.AssessedOperation {
	result := protocol.AssessedOperation{Kind: "read", Statements: []protocol.StatementAssessment{}}
	if operation.Type == "changes.apply" {
		result.Kind = "write"
		for _, change := range operation.Changes.Changes {
			if change.Kind == "delete" {
				result.Kind = "destructive"
			}
		}
		return result
	}
	statements := safety.Classify(engine, operation.SQL)
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

func (owner *owner) assess(command protocol.Command, engine string, policy protocol.ExecutionPolicy) protocol.Response {
	owner.authMu.Lock()
	defer owner.authMu.Unlock()
	owner.grant = nil
	assessment := &protocol.OperationAssessment{Decision: "allow", Policy: policy, Operations: []protocol.AssessedOperation{}}
	for _, operation := range command.Operations {
		if !operation.Valid() {
			return protocol.ErrorResponse(command, "protocol", "Invalid operation assessment.")
		}
		item := assessOperation(engine, operation)
		assessment.Operations = append(assessment.Operations, item)
		decision := policyDecision(policy, item)
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
		owner.grant = &operationGrant{token: assessment.Authorization, operations: command.Operations}
	}
	return protocol.Response{Type: "operation.assessment", RequestID: command.RequestID, SessionID: owner.id, QueryID: command.QueryID, Assessment: assessment}
}

func (owner *owner) authorize(command protocol.Command, engine string, policy protocol.ExecutionPolicy) bool {
	if command.Type != "execute" && command.Type != "changes.apply" {
		return true
	}
	operation := protocol.OperationRequest{Type: command.Type, SQL: command.SQL, Export: command.Export, Changes: command.Changes}
	if !operation.Valid() {
		owner.invalidateGrant()
		return false
	}
	owner.authMu.Lock()
	defer owner.authMu.Unlock()
	if policyDecision(policy, assessOperation(engine, operation)) == "deny" {
		owner.grant = nil
		return false
	}
	if command.Authorization == "" {
		owner.grant = nil
		return policyDecision(policy, assessOperation(engine, operation)) == "allow"
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
	grant.next++
	if grant.next == len(grant.operations) {
		owner.grant = nil
	}
	return true
}
