package mariadb

import (
	"context"
	"encoding/json"
	"strings"
	"testing"

	"dbeer/helper/internal/protocol"
)

func TestMariaDBExplainNativeMetricBasesAndExactNumbers(t *testing.T) {
	raw := `{"query_block":{"select_id":1,"r_total_time_ms":100.2500,"nested_loop":[{"table":{"table_name":"a","access_type":"ALL","rows":9007199254740993,"r_rows":2.5,"r_loops":4,"r_total_time_ms":91.125,"r_engine_stats":{"pages_accessed":9007199254740993,"pages_read_time_ms":1.2300,"future_counter":7}}},{"table":{"table_name":"b","access_type":"ref","rows":1,"r_rows":0,"r_loops":0,"r_total_time_ms":0}}]}}`
	nodes, roots, metrics, err := parseMariaDBExplainJSON(context.Background(), raw, "analyze")
	if err != nil || len(roots) != 1 || len(nodes) != 5 {
		t.Fatalf("native plan rejected: nodes=%d error=%v", len(nodes), err)
	}
	a, b := nodes[2], nodes[4]
	for key, expected := range map[string]string{"estimatedRows": "9007199254740993", "actualRows": "2.5", "loops": "4", "totalTime": "91.125"} {
		if a.Metrics[key].Value == nil || *a.Metrics[key].Value != expected {
			t.Fatalf("%s lost its native number", key)
		}
	}
	if a.Metrics["totalTime"].Basis != "inclusiveTotal" || a.Metrics["actualRows"].Basis != "perInvocation" || *metrics["executionTime"].Value != "100.2500" {
		t.Fatal("native row averages or inclusive total time were reinterpreted")
	}
	counters := a.AdvancedMetrics.Counters
	if *counters["mariaDBPagesAccessed"].Value != "9007199254740993" || *counters["mariaDBPagesReadTime"].Value != "1.2300" || *counters["mariaDBPagesRead"].Value != "0" || counters["mariaDBPagesAccessed"].Basis != "total" || !strings.Contains(a.Details["r_engine_stats"], "future_counter") {
		t.Fatal("engine counters lost exactness, omission proof, basis or unknown native evidence")
	}
	if b.Execution != "notExecuted" || b.Metrics["actualRows"].Value != nil || b.AdvancedMetrics.Counters["mariaDBPagesRead"].Value != nil || b.AdvancedMetrics.Counters["mariaDBPagesRead"].UnavailableReason != "notReported" {
		t.Fatal("unexecuted node or absent engine object invented evidence")
	}
	if a.AdvancedMetrics.ExclusiveTime.Value != nil || a.AdvancedMetrics.ExclusiveTime.UnavailableReason != "inclusiveOnly" || a.AdvancedMetrics.RowComparison != "unknownScope" {
		t.Fatal("unproven exclusive time or row comparability was inferred")
	}
}

func TestMariaDBExplainNativeNestedOrderAndRawDetails(t *testing.T) {
	raw := `{"query_block":{"select_id":1,"union_result":{"table_name":"<union1,2>","access_type":"ALL","query_specifications":[{"query_block":{"select_id":2,"table":{"table_name":"z","access_type":"ALL","rows":7}}},{"query_block":{"select_id":3,"table":{"table_name":"a","access_type":"ALL","rows":2,"attached_condition":"a.x = 'é'"}}}]}}}`
	nodes, _, _, err := parseMariaDBExplainJSON(context.Background(), raw, "plan")
	if err != nil {
		t.Fatal(err)
	}
	labels := []string{}
	for _, node := range nodes {
		if strings.HasPrefix(node.Operation, "Table access ") {
			labels = append(labels, node.Operation)
			if node.Metrics["actualRows"].Value != nil || node.Metrics["actualRows"].UnavailableReason != "notCollected" {
				t.Fatal("estimated plan invented execution observations")
			}
		}
	}
	if strings.Join(labels, "|") != "Table access ALL on z|Table access ALL on a" {
		t.Fatal("native array execution order changed")
	}
	if nodes[len(nodes)-1].Details["attached_condition"] != "a.x = 'é'" {
		t.Fatal("native condition detail changed")
	}
}

func TestMariaDBExplainNativeMalformedAndBounded(t *testing.T) {
	for _, raw := range []string{
		`null`, `{}`, `{"query_block":{}} {}`, `{"query_block":{"table":{"table_name":"a","access_type":"ALL","rows":-1}}}`,
		`{"query_block":{"select_id":1,"select_id":2}}`, `{"query_block":{"table":{"table_name":"a"}}}`,
		`{"query_block":{"nested_loop":[1]}}`, `{"query_block":{"table":{"table_name":"a","access_type":"ALL","r_engine_stats":null}}}`,
		`{"query_block":{"table":{"table_name":"a","access_type":"ALL","r_engine_stats":{"pages_read_count":null}}}}`,
		`{"query_block":{"table":{"table_name":"a","access_type":"ALL","r_rows":true}}}`,
		`{"query_block":{"table":{"table_name":"a","access_type":"ALL","r_loops":1.5}}}`,
		`{"query_block":{"table":{"table_name":"a","access_type":"ALL","r_engine_stats":{"pages_read_count":1.5}}}}`,
		`{"query_block":{"future_wrapper":{"table":{"table_name":"a","access_type":"ALL"}}}}`,
	} {
		if _, _, _, err := parseMariaDBExplainJSON(context.Background(), raw, "analyze"); err == nil {
			t.Fatalf("accepted malformed native plan: %s", raw)
		}
	}
	object := map[string]any{}
	for i := 0; i <= protocol.MaxExplainDepth; i++ {
		object = map[string]any{"query_block": object}
	}
	raw, _ := json.Marshal(object)
	if _, _, _, err := parseMariaDBExplainJSON(context.Background(), string(raw), "plan"); err == nil {
		t.Fatal("accepted excessive native depth")
	}
	ctx, cancel := context.WithCancel(context.Background())
	cancel()
	if _, _, _, err := parseMariaDBExplainJSON(ctx, `{"query_block":{}}`, "plan"); err == nil {
		t.Fatal("cancelled normalization succeeded")
	}
}

func TestMariaDBExplainRequiresNativePhysicalObservation(t *testing.T) {
	for _, observation := range []struct {
		version, comment, identity string
		supported                  bool
	}{
		{"10.11.9-MariaDB", "mariadb.org binary distribution", "native", true},
		{"11.4.3-MariaDB", "mariadb.org binary distribution", "native", true},
		{"10.11.8-MariaDB", "mariadb.org binary distribution", "native", false},
		{"11.4.2-MariaDB", "mariadb.org binary distribution", "native", false},
		{"11.8.1-MariaDB", "mariadb.org binary distribution", "native", false},
		{"8.4.1", "MySQL Community Server", "native", false},
		{"11.4.3-MariaDB", "mariadb.org binary distribution", "", false},
	} {
		s := &Session{serverVersion: observation.version, explainVendor: observation.comment, serverIdentity: observation.identity}
		support := s.ExplainSupport()
		if (len(support.Modes) > 0) != observation.supported || support.Engine != "mariadb" || support.Format != "json" || !support.Valid() {
			t.Fatalf("unexpected native server gate for %s", observation.version)
		}
		if support.DML != nil && support.DML.AnalyzeTargetExecution != "executes" {
			t.Fatal("MariaDB Analyze suppression was inherited from another engine")
		}
	}
}
