package session

import (
	"context"
	"dbeer/helper/internal/adapter"
	"dbeer/helper/internal/cassandra"
	"dbeer/helper/internal/mongodb"
	"dbeer/helper/internal/protocol"
	"dbeer/helper/internal/sqlite"
	"encoding/json"
	"slices"
	"testing"
)

func TestExplainOptionsGrantBindsExplicitFalseDefaultsAndFormat(t *testing.T) {
	physical := &explainTestSession{testSession: blockingSession()}
	owner := &owner{id: "f3-owner"}
	policy := protocol.ExecutionPolicy{}
	enabled := true
	request := protocol.ExplainRequest{SQL: "SELECT 1", Mode: "analyze", Options: &protocol.ExplainOptions{PostgreSQL: &protocol.PostgresExplainOptions{Buffers: &enabled}}}
	for _, mutation := range []string{"omitted", "false", "wrongEngine", "added"} {
		assessment := owner.assess(protocol.Command{Operations: []protocol.OperationRequest{{Type: "explain.run", Explain: &request}}}, "postgresql", policy, physical)
		if assessment.Assessment == nil || assessment.Assessment.Decision != "confirm" || assessment.Assessment.Operations[0].Explain.Options == nil {
			t.Fatal("options omitted from review")
		}
		data, _ := json.Marshal(request)
		var changed protocol.ExplainRequest
		if json.Unmarshal(data, &changed) != nil {
			t.Fatal("copy")
		}
		switch mutation {
		case "omitted":
			changed.Options = nil
		case "false":
			disabled := false
			changed.Options.PostgreSQL.Buffers = &disabled
		case "wrongEngine":
			changed.Options = &protocol.ExplainOptions{MySQL: &protocol.MySQLExplainOptions{Format: "tree"}}
		case "added":
			changed.Options.PostgreSQL.Timing = &enabled
		}
		if owner.authorize(protocol.Command{Type: "explain.run", Explain: &changed, Authorization: assessment.Assessment.Authorization}, "postgresql", policy, physical) {
			t.Fatal("changed options reused exact grant")
		}
	}
	assessment := owner.assess(protocol.Command{Operations: []protocol.OperationRequest{{Type: "explain.run", Explain: &request}}}, "postgresql", policy, physical)
	command := protocol.Command{Type: "explain.run", Explain: &request, Authorization: assessment.Assessment.Authorization}
	if !owner.authorize(command, "postgresql", policy, physical) || owner.takeApprovedExplainSQL() == "" || owner.authorize(command, "postgresql", policy, physical) {
		t.Fatal("exact options grant lifecycle")
	}
}

func TestExplainOptionsOwnerCapabilityAndEngineIsolation(t *testing.T) {
	physical := &explainTestSession{testSession: blockingSession()}
	manager := New(func(context.Context, protocol.Connection) (adapter.Session, error) { return physical, nil })
	defer manager.Close()
	submit(t, manager, protocol.Command{Type: "connect", RequestID: "f3-connect", Connection: &protocol.Connection{Database: "f3"}})
	connected := receive(t, manager)
	if connected.Type != "connect.result" || connected.ExplainSupport == nil || connected.ExplainSupport.Options == nil || !slices.Contains(connected.Capabilities, protocol.ExplainOptionsCapability) {
		t.Fatal("owning physical session omitted options capability")
	}
	options := &protocol.ExplainOptions{PostgreSQL: &protocol.PostgresExplainOptions{}}
	for _, item := range []struct {
		driver    adapter.ExplainSession
		sql, mode string
	}{{&mongodb.Session{}, `{"database":"fixture","collection":"items","find":{}}`, "plan"}, {&cassandra.Session{}, "SELECT * FROM fixture.items WHERE id=1", "analyze"}, {&sqlite.Session{}, "SELECT 1", "plan"}} {
		if _, err := item.driver.PrepareExplain(protocol.ExplainRequest{SQL: item.sql, Mode: item.mode, Options: options}); err == nil {
			t.Fatal("relational options admitted by a different diagnostic engine")
		}
	}
}
