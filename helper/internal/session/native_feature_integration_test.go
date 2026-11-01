package session

import (
	"context"
	"strings"
	"testing"

	"dbeer/helper/internal/adapter"
	"dbeer/helper/internal/protocol"
	"dbeer/helper/internal/tableedit"
)

// A physical connection can support both features; its purpose still restricts use.
type nativeFeatureSession struct {
	*explainTestSession
	structureFake
}

func TestNativeFeaturePurposeBlocksExplainBeforeAssessmentAndDispatch(t *testing.T) {
	physical := &nativeFeatureSession{explainTestSession: &explainTestSession{testSession: blockingSession()}}
	manager := New(func(context.Context, protocol.Connection) (adapter.Session, error) { return physical, nil })
	defer manager.Close()
	submit(t, manager, protocol.Command{Type: "connect", RequestID: "open", Connection: &protocol.Connection{SessionPurpose: "structure"}})
	id := receive(t, manager).SessionID
	request := &protocol.ExplainRequest{SQL: "SELECT 1", Mode: "plan"}
	for _, operation := range []protocol.OperationRequest{
		{Type: "explain.run", Explain: request},
		{Type: "execute", SQL: "SELECT 1"},
	} {
		submit(t, manager, protocol.Command{Type: "operation.assess", RequestID: "review", SessionID: id, QueryID: "review", Operations: []protocol.OperationRequest{operation}})
		if response := receive(t, manager); response.Type != "error" || response.Category != "policy" || response.Assessment != nil {
			t.Fatal("dedicated DDL session assessed another operation family")
		}
	}
	command := protocol.Command{Type: "explain.run", RequestID: "run", SessionID: id, QueryID: "run", Explain: request}
	submit(t, manager, command)
	if response := receive(t, manager); response.Type != "error" || response.Category != "policy" || !response.SQLNotExecuted || physical.calls.Load() != 0 {
		t.Fatal("dedicated DDL session dispatched Explain")
	}
	manager.controlMu.Lock()
	_, pending := manager.pendingQueries[command.QueryID]
	manager.controlMu.Unlock()
	if pending {
		t.Fatal("rejected feature command retained a pending query")
	}
}

func TestNativeFeaturePurposeCannotReuseAnotherFamilyGrant(t *testing.T) {
	policy := protocol.ExecutionPolicy{Environment: "development"}
	physical := &explainTestSession{testSession: blockingSession()}
	ddlOwner := &owner{id: "ddl"}
	apply := structurePlan(t, ddlOwner)
	operation := protocol.OperationRequest{Type: "structure.apply", Structure: &apply}
	assessment := ddlOwner.assess(protocol.Command{Operations: []protocol.OperationRequest{operation}}, "postgresql", policy)
	if assessment.Assessment == nil {
		t.Fatal("DDL review missing")
	}
	request := &protocol.ExplainRequest{SQL: "SELECT 1", Mode: "plan"}
	if ddlOwner.authorize(protocol.Command{Type: "explain.run", Explain: request, Authorization: assessment.Assessment.Authorization}, "postgresql", policy) {
		t.Fatal("DDL grant authorized Explain")
	}
	if ddlOwner.authorize(protocol.Command{Type: "structure.apply", Structure: &tableedit.Request{Apply: &apply}, Authorization: assessment.Assessment.Authorization}, "postgresql", policy) {
		t.Fatal("invalid cross-family request did not invalidate the grant")
	}
	ordinary := &owner{id: "sql"}
	if response := ordinary.assess(protocol.Command{Operations: []protocol.OperationRequest{operation}}, "postgresql", policy, physical); response.Type != "error" || response.Category != "policy" {
		t.Fatal("ordinary SQL session assessed DDL")
	}
	if ordinary.authorize(protocol.Command{Type: "structure.apply", Structure: &tableedit.Request{Apply: &apply}}, "postgresql", policy) {
		t.Fatal("ordinary SQL session authorized DDL")
	}
	// A purpose-violating assessment also clears an earlier valid DDL grant.
	assessment = ddlOwner.assess(protocol.Command{Operations: []protocol.OperationRequest{operation}}, "postgresql", policy)
	response := ddlOwner.assess(protocol.Command{Operations: []protocol.OperationRequest{{Type: "explain.run", Explain: request}}}, "postgresql", policy, physical)
	if response.Type != "error" || ddlOwner.authorize(protocol.Command{Type: "structure.apply", Structure: &tableedit.Request{Apply: &apply}, Authorization: assessment.Assessment.Authorization}, "postgresql", policy) {
		t.Fatal("failed assessment retained an older grant")
	}
}

func TestNativeFeatureStrictMixedPayloadBoundaries(t *testing.T) {
	request := &protocol.ExplainRequest{SQL: "SELECT 1", Mode: "plan"}
	apply := &tableedit.Apply{PlanID: "plan", Digest: strings.Repeat("a", 64), ExecutionID: "execution"}
	for _, kind := range []string{"execute", "explain.run", "structure.apply", "changes.apply"} {
		if (protocol.OperationRequest{Type: kind, SQL: "SELECT 1", Explain: request, Structure: apply}).Valid() {
			t.Fatal("mixed native operation accepted")
		}
	}
	explain := `"explain":{"sql":"SELECT 1","mode":"plan"}`
	structure := `"structure":{"planId":"plan","digest":"` + strings.Repeat("a", 64) + `","executionId":"execution"}`
	for _, operation := range []string{
		`{"type":"explain.run",` + explain + `,` + structure + `}`,
		`{"type":"structure.apply",` + structure + `,` + explain + `}`,
		`{"type":"explain.run",` + explain + `,"structure":null}`,
		`{"type":"structure.apply",` + structure + `,"explain":null}`,
		`{"type":"execute","sql":"SELECT 1","structure":null}`,
		`{"type":"structure.apply","structure":{"planId":"plan","planId":"other","digest":"` + strings.Repeat("a", 64) + `","executionId":"execution"}}`,
	} {
		frame := `{"type":"operation.assess","requestId":"review","sessionId":"session","queryId":"query","operations":[` + operation + `]}`
		if _, err := protocol.ParseCommand([]byte(frame)); err == nil {
			t.Fatal("mixed or ambiguous assessment accepted")
		}
	}
	for _, frame := range []string{
		`{"type":"explain.run","requestId":"r","sessionId":"s","queryId":"q",` + explain + `,` + structure + `}`,
		`{"type":"structure.apply","requestId":"r","sessionId":"s","queryId":"q","structure":{"apply":{"planId":"plan","digest":"` + strings.Repeat("a", 64) + `","executionId":"execution"}},` + explain + `}`,
	} {
		if _, err := protocol.ParseCommand([]byte(frame)); err == nil {
			t.Fatal("mixed execution accepted")
		}
	}
}
