package adapter

import (
	"context"
	"dbeer/helper/internal/protocol"
	"encoding/json"
	"errors"
	"strings"
	"testing"
	"unicode/utf16"
)

func dmlExplainRequest(sql, mode, status string) protocol.ExplainRequest {
	r := protocol.ExplainRequest{SQL: sql, Mode: mode}
	if mode == "analyze" {
		r.Context = &protocol.ExplainContext{DocumentID: "doc", TargetDocumentID: "doc", ProfileID: "profile", SessionID: "session", RangeLength: len(utf16.Encode([]rune(sql))), TransactionStatus: status}
		r.WriteIntent = &protocol.ExplainWriteIntent{Disposition: "currentSession", ExpectedTransactionStatus: status}
	}
	return r
}
func TestExplainDMLSupportMatrixAndExactSQL(t *testing.T) {
	for _, item := range []struct {
		engine, version, sql string
		analyze              bool
	}{
		{"postgresql", "14.0", "INSERT INTO sample VALUES(1)", true},
		{"postgresql", "17.6", "WITH a AS (DELETE FROM sample RETURNING *) SELECT * FROM a", true},
		{"mysql", "5.7.44", "UPDATE sample SET id=2", false},
		{"mysql", "8.0.17", "DELETE a FROM sample a JOIN other b ON a.id=b.id", false},
		{"mysql", "8.0.18", "DELETE a FROM sample a JOIN other b ON a.id=b.id", true},
		{"mysql", "8.4.6", "UPDATE sample a JOIN other b ON a.id=b.id SET a.id=2", true},
		{"mysql", "8.4.6", "INSERT INTO sample VALUES(1)", false},
		{"mysql", "8.4.6", "UPDATE sample SET id=2", false},
		{"mysql", "8.4.6", "DELETE FROM sample WHERE id=1", false},
	} {
		support := ExplainSupport(item.engine, item.version)
		for _, mode := range []string{"plan", "analyze"} {
			r := dmlExplainRequest(item.sql, mode, "idle")
			p, err := PrepareExplain(support, r)
			if mode == "analyze" && !item.analyze {
				if err == nil {
					t.Fatal("unsupported actual form accepted")
				}
				continue
			}
			if err != nil || p.Preview.DML == nil || p.Preview.SQL != p.Prefix+r.SQL {
				t.Fatalf("DML preparation %s %s: %v", item.engine, item.version, err)
			}
			if mode == "plan" && (strings.Contains(p.Prefix, "ANALYZE TRUE") || strings.Contains(p.Prefix, "EXPLAIN ANALYZE")) {
				t.Fatal("estimated DML executes")
			}
		}
	}
	request := dmlExplainRequest("UPDATE sample SET id=2", "analyze", "transaction")
	request.WriteIntent = nil
	if _, err := PrepareExplain(ExplainSupport("postgresql", "17.6"), request); err == nil {
		t.Fatal("actual DML accepted without explicit write intent")
	}
	request = dmlExplainRequest("SELECT 1", "analyze", "idle")
	if _, err := PrepareExplain(ExplainSupport("postgresql", "17.6"), request); err == nil {
		t.Fatal("read request accepted DML authority")
	}
}
func TestExplainDMLOutcomeRequiresTerminalTransactionAcknowledgement(t *testing.T) {
	request := dmlExplainRequest("UPDATE sample SET id=2", "analyze", "idle")
	prepared, err := PrepareExplain(ExplainSupport("postgresql", "17.6"), request)
	if err != nil {
		t.Fatal(err)
	}
	for _, item := range []struct {
		response               protocol.Response
		execution, persistence string
	}{
		{protocol.Response{Type: "query.result", Connected: true, TransactionStatus: "idle"}, "completed", "committed"},
		{protocol.Response{Type: "query.result", Connected: false, TransactionStatus: "idle"}, "completed", "committed"},
		{protocol.Response{Type: "query.result", Connected: true, TransactionStatus: "transaction"}, "completed", "transactionPending"},
		{protocol.Response{Type: "error", Connected: false, TransactionStatus: "idle", SQLCompleted: true}, "completed", "unknown"},
		{protocol.Response{Type: "error", Connected: false, TransactionStatus: "unknown", SQLCompleted: true, AcknowledgedTransactionStatus: "idle"}, "completed", "committed"},
		{protocol.Response{Type: "error", Connected: false, TransactionStatus: "unknown", SQLCompleted: true, AcknowledgedTransactionStatus: "transaction"}, "completed", "transactionPending"},
		{protocol.Response{Type: "error", Connected: true, TransactionStatus: "failedTransaction"}, "failed", "unknown"},
		{protocol.Response{Type: "error", OutcomeUnknown: true}, "unknown", "unknown"},
		{protocol.Response{Type: "error", SQLNotExecuted: true, Connected: true, TransactionStatus: "idle"}, "notExecuted", "notExecuted"},
	} {
		r := ExplainDMLOutcome(prepared, item.response)
		if r.Execution != item.execution || r.Persistence != item.persistence || !r.Valid("postgresql", "analyze") {
			t.Fatal("DML completion or persistence misrepresented")
		}
	}
	acknowledged := protocol.Response{Type: "error", SQLCompleted: true, Connected: false, TransactionStatus: "unknown", AcknowledgedTransactionStatus: "idle"}
	acknowledged = FinishExplain(context.Background(), protocol.Command{}, acknowledged, prepared, &ExplainCapture{}, nil)
	encoded, _ := json.Marshal(acknowledged)
	var fields map[string]json.RawMessage
	_ = json.Unmarshal(encoded, &fields)
	if acknowledged.OutcomeUnknown || acknowledged.ExplainDML.Persistence != "committed" || acknowledged.TransactionStatus != "" || fields["transactionStatus"] != nil || fields["AcknowledgedTransactionStatus"] != nil || fields["acknowledgedTransactionStatus"] != nil {
		t.Fatal("private final acknowledgement leaked or known disposition was erased")
	}
	if ExplainWriteContextMatches(&request, "transaction") {
		t.Fatal("stale transaction context accepted")
	}
	response := protocol.Response{Type: "error", SQLCompleted: true, Connected: false, TransactionStatus: "unknown"}
	finished := FinishExplain(context.Background(), protocol.Command{}, response, prepared, &ExplainCapture{}, func(context.Context, string, string) ([]protocol.ExplainNode, []string, map[string]protocol.ExplainMetric, error) {
		return nil, nil, nil, errors.New("unused")
	})
	if !finished.SQLCompleted || !finished.OutcomeUnknown || finished.ExplainDML == nil || finished.ExplainDML.Persistence != "unknown" || finished.ExplainDML.Execution != "completed" {
		t.Fatal("lost acknowledgement became success")
	}
}

func TestExplainDMLSuppressionSeparatesTargetRowsFromSessionAcknowledgement(t *testing.T) {
	r := dmlExplainRequest("UPDATE sample a JOIN other b ON a.id=b.id SET a.note='value'", "analyze", "idle")
	p, err := PrepareExplain(ExplainSupport("mysql", "8.4.13"), r)
	if err != nil {
		t.Fatal(err)
	}
	for _, ack := range []string{"", "idle", "transaction"} {
		response := protocol.Response{Type: "error", SQLCompleted: true, Connected: false, TransactionStatus: "unknown", AcknowledgedTransactionStatus: ack}
		out := FinishExplain(context.Background(), protocol.Command{}, response, p, &ExplainCapture{}, nil)
		after := ack
		if after == "" {
			after = "unknown"
		}
		if out.ExplainDML == nil || !out.ExplainDML.Valid("mysql", "analyze") || out.ExplainDML.Execution != "completed" || out.ExplainDML.TargetExecution != "suppressed" || out.ExplainDML.Persistence != "notExecuted" || out.ExplainDML.TransactionAfter != after || out.OutcomeUnknown != (ack == "") || out.TransactionStatus != "" {
			t.Fatal("target suppression confused session/side-effect uncertainty with target-row persistence")
		}
	}
}

func TestEstimatedExplainDMLServerFailureUsesOrdinaryErrorEnvelope(t *testing.T) {
	request := dmlExplainRequest("UPDATE missing_sample SET id=2", "plan", "")
	prepared, err := PrepareExplain(ExplainSupport("postgresql", "17.6"), request)
	if err != nil {
		t.Fatal(err)
	}
	failure := protocol.Response{Type: "error", SQLState: "42P01", Connected: true, TransactionStatus: "idle"}
	out := FinishExplain(context.Background(), protocol.Command{}, failure, prepared, &ExplainCapture{}, nil)
	if out.Type != "error" || out.ExplainDML != nil || out.SQLCompleted || out.OutcomeUnknown || out.SQLState != "42P01" {
		t.Fatal("estimated server rejection acquired Analyze-only outcome metadata")
	}
}
