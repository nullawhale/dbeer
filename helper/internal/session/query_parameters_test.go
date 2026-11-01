package session

import (
	"testing"

	"dbeer/helper/internal/protocol"
)

func TestParameterAuthorizationBindsValuesTypesNullAndUnusedDefinitions(t *testing.T) {
	for _, field := range []string{"value", "type", "null", "unused"} {
		t.Run(field, func(t *testing.T) {
			value, unused := "1", "unused"
			parameters := []protocol.QueryParameter{{Name: "x", Type: "integer", Value: &value}, {Name: "extra", Type: "text", Value: &unused}}
			operation := protocol.OperationRequest{Type: "execute", SQL: "DELETE FROM demo WHERE id=:x", Parameters: parameters}
			owner := &owner{id: "parameter-session"}
			policy := protocol.ExecutionPolicy{Environment: "production"}
			assessed := owner.assess(protocol.Command{Operations: []protocol.OperationRequest{operation}}, "postgresql", policy)
			if assessed.Assessment == nil || assessed.Assessment.Authorization == "" {
				t.Fatal("parameter assessment failed")
			}
			// Mutate the caller's retained slice too: the grant must own its copy.
			switch field {
			case "value":
				value = "2"
			case "type":
				parameters[0].Type = "text"
			case "null":
				parameters[0].Value = nil
			case "unused":
				unused = "changed"
			}
			if owner.authorize(protocol.Command{Type: "execute", SQL: operation.SQL, Parameters: parameters, Authorization: assessed.Assessment.Authorization}, "postgresql", policy) {
				t.Fatal("changed parameters reused approval")
			}
		})
	}
}

func TestParameterReadOnlyAssessmentAndExactApproval(t *testing.T) {
	value := "1"
	parameters := []protocol.QueryParameter{{Name: "x", Type: "integer", Value: &value}}
	for _, engine := range []string{"postgresql", "mysql"} {
		owner := &owner{id: "session"}
		policy := protocol.ExecutionPolicy{Environment: "production", ReadOnly: true}
		operation := protocol.OperationRequest{Type: "execute", SQL: "SELECT :x", Parameters: parameters}
		assessment := owner.assess(protocol.Command{Operations: []protocol.OperationRequest{operation}}, engine, policy)
		if assessment.Assessment == nil || assessment.Assessment.Decision != "allow" {
			t.Fatal("bound read classified incorrectly")
		}
		if !owner.authorize(protocol.Command{Type: "execute", SQL: operation.SQL, Parameters: parameters, Authorization: assessment.Assessment.Authorization}, engine, policy) {
			t.Fatal("unchanged bound read rejected")
		}
		operation.SQL = "DELETE FROM demo WHERE id=:x"
		assessment = owner.assess(protocol.Command{Operations: []protocol.OperationRequest{operation}}, engine, policy)
		if assessment.Assessment == nil || assessment.Assessment.Decision != "deny" {
			t.Fatal("bound write bypassed readonly")
		}
	}
}

func TestParameterNamesCannotAlterPolicyKeywordsOrOffsets(t *testing.T) {
	value := "1"
	for _, engine := range []string{"postgresql", "mysql"} {
		for _, test := range []struct{ sql, kind, decision string }{
			{"SELECT :into, :delete, :where", "read", "allow"},
			{"UPDATE demo SET a=:where", "destructive", "confirm"},
			{"DELETE FROM demo WHERE id=:where", "destructive", "confirm"},
			{"SELECT unsafe_mutating_function(:into)", "unknown", "confirm"},
		} {
			parameters := []protocol.QueryParameter{{Name: "into", Type: "integer", Value: &value}, {Name: "delete", Type: "integer", Value: &value}, {Name: "where", Type: "integer", Value: &value}}
			operation := protocol.OperationRequest{Type: "execute", SQL: test.sql, Parameters: parameters}
			assessment := assessOperation(engine, operation)
			if assessment.Kind != test.kind || policyDecision(protocol.ExecutionPolicy{Environment: "development"}, assessment) != test.decision {
				t.Fatalf("parameter name altered %s policy", engine)
			}
			if len(assessment.Statements) != 1 || assessment.Statements[0].Start != 0 || assessment.Statements[0].End != len(test.sql) {
				t.Fatal("masked assessment offsets no longer match source")
			}
		}
	}
}
