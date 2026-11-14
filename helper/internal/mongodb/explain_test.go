package mongodb

import (
	"context"
	"encoding/json"
	"strings"
	"testing"

	"dbeer/helper/internal/protocol"
	"go.mongodb.org/mongo-driver/v2/bson"
)

func TestMongoDBDiagnosticPreparationExactBSONAndReadBoundary(t *testing.T) {
	s := &Session{database: "fixture"}
	input := `{"collection":"items","find":{"x":{"$numberLong":"9007199254740993"},"empty":"","literal":"NULL"},"sort":{"z":-1,"a":1},"limit":1}`
	for _, mode := range []string{"plan", "analyze"} {
		p, err := s.PrepareExplain(protocol.ExplainRequest{SQL: input, Mode: mode})
		if err != nil || !p.Preview.Support.Valid() {
			t.Fatal("read diagnostic rejected")
		}
		if !strings.Contains(p.Preview.SQL, `"$numberLong":"9007199254740993"`) || strings.Index(p.Preview.SQL, `"z"`) > strings.Index(p.Preview.SQL, `"a"`) {
			t.Fatal("BSON width or sort order lost")
		}
		r := s.ExecuteExplain(context.Background(), protocol.Command{Explain: &p.Request, PreparedExplainSQL: p.Preview.SQL + " "})
		if !r.SQLNotExecuted || r.Type != "error" {
			t.Fatal("changed review reached execution")
		}
	}
	for _, input := range []string{`{"collection":"items","aggregate":[{"$out":"archive"}]}`, `{"collection":"items","aggregate":[{"$merge":"archive"}]}`, `{"collection":"items","aggregate":[{"$facet":{"x":[{"$out":"archive"}]}}]}`, `{"collection":"items","find":{},"command":"drop"}`, `{"collection":"items","find":{"x":1,"x":2}}`, `{"collection":"items","aggregate":[{"$function":{}}]}`} {
		if _, err := s.PrepareExplain(protocol.ExplainRequest{SQL: input, Mode: "analyze"}); err == nil {
			t.Fatal("write, unknown command or invalid duplicate accepted")
		}
	}
}
func mongoPlanFixture(t *testing.T, mode string, doc bson.D) protocol.ExplainResult {
	t.Helper()
	s := &Session{database: "fixture"}
	p, err := s.PrepareExplain(protocol.ExplainRequest{SQL: `{"collection":"items","find":{}}`, Mode: mode})
	if err != nil {
		t.Fatal(err)
	}
	raw, err := bson.Marshal(doc)
	if err != nil {
		t.Fatal(err)
	}
	return mongoDiagnosticResult(p, raw)
}
func TestMongoDBDiagnosticNativeShapesMetricsAndPrivateEvidence(t *testing.T) {
	doc := bson.D{{Key: "queryPlanner", Value: bson.D{{Key: "parsedQuery", Value: bson.D{{Key: "stage", Value: "literal-not-a-plan"}}}, {Key: "winningPlan", Value: bson.D{{Key: "queryPlan", Value: bson.D{{Key: "stage", Value: "FETCH"}, {Key: "inputStage", Value: bson.D{{Key: "stage", Value: "IXSCAN"}}}}}}}}}, {Key: "executionStats", Value: bson.D{{Key: "nReturned", Value: int64(9007199254740993)}, {Key: "totalKeysExamined", Value: int64(0)}, {Key: "executionTimeMillis", Value: int32(0)}, {Key: "executionStages", Value: bson.D{{Key: "stage", Value: "fetch"}, {Key: "executionTimeMillisEstimate", Value: int32(0)}}}}}, {Key: "serverInfo", Value: bson.D{{Key: "host", Value: "private-host"}, {Key: "version", Value: "8.0.0"}}}, {Key: "serverParameters", Value: bson.D{{Key: "privateSetting", Value: true}}}}
	doc = append(doc, bson.E{Key: "command", Value: bson.D{{Key: "find", Value: "items"}, {Key: "filter", Value: bson.D{{Key: "lsid", Value: "user-data"}}}, {Key: "lsid", Value: "private-session"}, {Key: "readConcern", Value: bson.D{{Key: "level", Value: "private-setting"}}}}})
	r := mongoPlanFixture(t, "analyze", doc)
	if !r.Valid() || !r.Complete || r.Support.ServerVersion != "8.0.0" {
		t.Fatal("diagnostic invalid")
	}
	m := r.EngineDiagnostic.MongoDB
	if len(r.Nodes) != 0 || len(m.Stages) != 3 || *m.Metrics["nReturned"].Value != "9007199254740993" || *m.Metrics["totalKeysExamined"].Value != "0" || m.Metrics["totalDocsExamined"].UnavailableReason != "notReported" {
		t.Fatal("native stage/metric semantics lost")
	}
	if m.Stages[2].Metrics["executionTimeMillisEstimate"].Basis != "stageEstimate" || strings.Contains(r.Raw, "private-host") || strings.Contains(r.Raw, "privateSetting") || strings.Contains(r.Raw, "private-session") || strings.Contains(r.Raw, "private-setting") || !strings.Contains(r.Raw, "user-data") {
		t.Fatal("estimated time or portable privacy lost")
	}
	planned := mongoPlanFixture(t, "plan", bson.D{{Key: "queryPlanner", Value: bson.D{}}})
	if !planned.Valid() || planned.EngineDiagnostic.MongoDB.Metrics["nReturned"].UnavailableReason != "notCollected" {
		t.Fatal("planner fabricated actual measurements")
	}
	duplicate := bson.D{{Key: "queryPlanner", Value: bson.D{{Key: "winningPlan", Value: bson.D{{Key: "stage", Value: "SCAN"}, {Key: "stage", Value: "SECOND"}}}}}}
	captured := mongoPlanFixture(t, "plan", duplicate)
	if strings.Count(captured.Raw, `"stage"`) != 2 {
		t.Fatal("raw BSON duplicate evidence was flattened")
	}
	encoded, _ := json.Marshal(r)
	if len(encoded) > protocol.MaxExplainResponseBytes {
		t.Fatal("response exceeded budget")
	}
}
func TestMongoDBDiagnosticShardAndAggregateEvidence(t *testing.T) {
	shard := bson.D{{Key: "connectionString", Value: "private-address"}, {Key: "queryPlanner", Value: bson.D{{Key: "winningPlan", Value: bson.D{{Key: "stage", Value: "COLLSCAN"}}}}}}
	r := mongoPlanFixture(t, "plan", bson.D{{Key: "shards", Value: bson.D{{Key: "shardA", Value: shard}}}, {Key: "stages", Value: bson.A{bson.D{{Key: "$cursor", Value: bson.D{{Key: "queryPlanner", Value: bson.D{{Key: "winningPlan", Value: bson.D{{Key: "stage", Value: "IXSCAN"}}}}}}}}}}})
	if !r.Valid() || len(r.EngineDiagnostic.MongoDB.Stages) != 3 || strings.Contains(r.Raw, "private-address") {
		t.Fatal("shard/aggregation envelopes were lost or settings retained")
	}
}
func TestMongoDBDiagnosticBoundedAfterConfirmedCommand(t *testing.T) {
	r := mongoPlanFixture(t, "plan", bson.D{{Key: "unknownOutput", Value: strings.Repeat("🍺", protocol.MaxExplainRawBytes/4+10)}})
	if !r.Valid() || r.Complete || len(r.Raw) > protocol.MaxExplainRawBytes {
		t.Fatal("oversize output not bounded")
	}
}
