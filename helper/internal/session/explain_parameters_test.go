package session

import (
	"dbeer/helper/internal/protocol"
	"testing"
)

func TestExplainGrantBindsExactValuesRangesPlanKindAndContext(t *testing.T) {
	physical := &explainTestSession{testSession: blockingSession()}
	o := &owner{id: "session-b"}
	policy := protocol.ExecutionPolicy{}
	value := "é"
	r := protocol.ExplainRequest{SQL: "SELECT :value", Mode: "plan", PlanKind: "custom", Parameters: []protocol.QueryParameter{{Name: "value", Type: "text", Value: &value}}, Context: &protocol.ExplainContext{DocumentID: "document-a", TargetDocumentID: "document-b", RangeLocation: 17, RangeLength: 13, ProfileID: "profile-b", SessionID: o.id, TransactionStatus: "idle"}}
	assess := func() string {
		a := o.assess(protocol.Command{Operations: []protocol.OperationRequest{{Type: "explain.run", Explain: &r}}}, "postgresql", policy, physical)
		if a.Assessment == nil || a.Assessment.Decision != "allow" {
			t.Fatal("bound SELECT assessment failed")
		}
		return a.Assessment.Authorization
	}
	for _, mutation := range []string{"value", "type", "range", "targetDocument", "profile", "session", "transaction", "plan"} {
		grant := assess()
		changed := r
		parameters := append([]protocol.QueryParameter(nil), r.Parameters...)
		changed.Parameters = parameters
		binding := *r.Context
		changed.Context = &binding
		switch mutation {
		case "value":
			v := "e\u0301"
			changed.Parameters[0].Value = &v
		case "type":
			changed.Parameters[0].Type = "decimal"
		case "range":
			binding.RangeLocation++
		case "targetDocument":
			binding.TargetDocumentID = "document-c"
		case "profile":
			binding.ProfileID = "profile-c"
		case "session":
			binding.SessionID = "session-c"
		case "transaction":
			binding.TransactionStatus = "transaction"
		case "plan":
			changed.PlanKind = "generic"
		}
		if o.authorize(protocol.Command{Type: "explain.run", SessionID: o.id, Explain: &changed, Authorization: grant}, "postgresql", policy, physical) {
			t.Fatalf("changed %s reused grant", mutation)
		}
	}
	grant := assess()
	c := protocol.Command{Type: "explain.run", SessionID: o.id, Explain: &r, Authorization: grant}
	if !o.authorize(c, "postgresql", policy, physical) || o.takeApprovedExplainSQL() == "" {
		t.Fatal("exact request rejected")
	}
	if o.authorize(c, "postgresql", policy, physical) {
		t.Fatal("grant reused")
	}
	stale := r
	binding := *r.Context
	binding.TransactionStatus = "transaction"
	stale.Context = &binding
	if a := o.assess(protocol.Command{Operations: []protocol.OperationRequest{{Type: "explain.run", Explain: &stale}}}, "postgresql", policy, physical); a.Type != "error" {
		t.Fatal("stale transaction context assessed")
	}
}
