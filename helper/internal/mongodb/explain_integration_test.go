package mongodb

import (
	"context"
	"dbeer/helper/internal/protocol"
	"go.mongodb.org/mongo-driver/v2/bson"
	"testing"
)

func TestMongoDBDiagnosticIntegrationPlannerAndExecutionStats(t *testing.T) {
	s := integrationSession(t)
	ctx := context.Background()
	if _, err := s.client.Database(s.database).Collection("items").InsertMany(ctx, []any{bson.D{{Key: "_id", Value: int32(1)}, {Key: "exact", Value: int64(9007199254740993)}}, bson.D{{Key: "_id", Value: int32(2)}, {Key: "exact", Value: int64(7)}}}); err != nil {
		t.Fatal("fixture insert failed")
	}
	for _, input := range []string{`{"collection":"items","find":{"exact":{"$numberLong":"9007199254740993"}},"sort":{"_id":-1},"limit":1}`, `{"collection":"items","aggregate":[{"$match":{"_id":1}},{"$project":{"exact":1}}]}`} {
		for _, mode := range []string{"plan", "analyze"} {
			request := protocol.ExplainRequest{SQL: input, Mode: mode}
			p, err := s.PrepareExplain(request)
			if err != nil {
				t.Fatal("preparation failed")
			}
			r := s.ExecuteExplain(ctx, protocol.Command{Type: "explain.run", RequestID: "diagnostic", SessionID: "fixture", QueryID: "diagnostic", Explain: &request, PreparedExplainSQL: p.Preview.SQL})
			if r.Type != "explain.result" || !r.SQLCompleted || r.Explain == nil || !r.Explain.Valid() || r.Explain.EngineDiagnostic.MongoDB.Verbosity != map[string]string{"plan": "queryPlanner", "analyze": "executionStats"}[mode] {
				t.Fatalf("real diagnostic failed: %s %s", r.Type, r.Category)
			}
			if mode == "plan" && r.Explain.EngineDiagnostic.MongoDB.Metrics["nReturned"].Value != nil {
				t.Fatal("planner invented measured rows")
			}
			if mode == "analyze" && len(r.Explain.EngineDiagnostic.MongoDB.Stages) == 0 {
				t.Fatal("actual server stages missing")
			}
		}
	}
	cancelled, cancel := context.WithCancel(ctx)
	cancel()
	request := protocol.ExplainRequest{SQL: `{"collection":"items","find":{}}`, Mode: "analyze"}
	p, _ := s.PrepareExplain(request)
	r := s.ExecuteExplain(cancelled, protocol.Command{Explain: &request, PreparedExplainSQL: p.Preview.SQL})
	if r.Type != "error" || r.Category != "cancelled" || r.SQLCompleted {
		t.Fatal("cancelled diagnostic reported completion")
	}
}
