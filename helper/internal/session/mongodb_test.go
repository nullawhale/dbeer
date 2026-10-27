package session

import (
	"context"
	"strings"
	"testing"

	"dbeer/helper/internal/adapter"
	"dbeer/helper/internal/protocol"
)

func TestMongoDBReadOnlyAndProductionOutputPolicy(t *testing.T) {
	for _, readOnly := range []bool{true, false} {
		physical := &cassandraPolicySession{testSession: testSession{closed: make(chan struct{})}}
		manager := New(func(context.Context, protocol.Connection) (adapter.Session, error) { return physical, nil })
		policy := protocol.ExecutionPolicy{Environment: "production", ReadOnly: readOnly}
		submit(t, manager, protocol.Command{Type: "connect", RequestID: "connect", Connection: &protocol.Connection{Engine: "mongodb", Policy: &policy}})
		connected := receive(t, manager)
		caps := strings.Join(connected.Capabilities, ",")
		if connected.Type != "connect.result" || !strings.Contains(caps, "documentModelV1") || !strings.Contains(caps, "canonicalExtendedJSONV1") || strings.Contains(caps, "transactions") || strings.Contains(caps, "gridEditing") || strings.Contains(caps, "serverReadOnly") {
			t.Fatal("MongoDB capabilities are incorrect")
		}
		text := `{"collection":"items","aggregate":[{"$out":"archive"}]}`
		operation := protocol.OperationRequest{Type: "execute", SQL: text}
		submit(t, manager, protocol.Command{Type: "operation.assess", RequestID: "assess", QueryID: "assess", SessionID: connected.SessionID, Operations: []protocol.OperationRequest{operation}})
		assessment := receive(t, manager)
		expected := "confirm"
		if readOnly {
			expected = "deny"
		}
		if assessment.Assessment == nil || assessment.Assessment.Decision != expected || assessment.Assessment.Operations[0].Kind != "write" {
			t.Fatal("output pipeline bypassed policy")
		}
		submit(t, manager, protocol.Command{Type: "execute", RequestID: "write", QueryID: "write", SessionID: connected.SessionID, SQL: text})
		if r := receive(t, manager); r.Category != "policy" || physical.executions.Load() != 0 {
			t.Fatal("unconfirmed pipeline reached MongoDB")
		}
		submit(t, manager, protocol.Command{Type: "execute", RequestID: "read", QueryID: "read", SessionID: connected.SessionID, SQL: `{"collection":"items","find":{}}`})
		if receive(t, manager).Type != "query.started" || receive(t, manager).Type != "query.result" || physical.executions.Load() != 1 {
			t.Fatal("safe MongoDB read was blocked")
		}
		manager.Close()
	}
}
