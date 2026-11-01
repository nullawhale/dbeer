package adapter

import (
	"context"
	"encoding/json"
	"errors"
	"strings"
	"testing"
	"unicode/utf8"
	"unsafe"

	"dbeer/helper/internal/protocol"
)

func TestExplainVersionBoundariesAndExactWrapper(t *testing.T) {
	for _, item := range []struct {
		engine, version string
		available       bool
	}{{"postgresql", "13.9", false}, {"postgresql", "14.0", true}, {"postgresql", "18.1 (fixture)", true}, {"mysql", "8.0.20", false}, {"mysql", "8.0.21", true}, {"mysql", "8.4.6", true}, {"mysql", "8.0.30-unknownVendor", false}, {"mysql", "8.0.40-31", false}, {"mysql", "8.4", false}, {"mysql", "8.4.6-commercial", true}, {"mysql", "8.4.13-standard", true}, {"mysql", "26.10.0-unknown", false}, {"mysql", "9.7.0", true}, {"mysql", "26.10.0", true}, {"mysql", "10.11.1-MariaDB", false}, {"mysql", "8.0.30-Percona", false}, {"mysql", "8.0.30-TiDB", false}, {"mysql", "8.0.30-aurora", false}, {"mysql", "unknown", false}} {
		s := ExplainSupport(item.engine, item.version)
		if (len(s.Modes) > 0) != item.available || !s.Valid() {
			t.Errorf("version boundary %s %s", item.engine, item.version)
		}
	}
	for _, engine := range []string{"postgresql", "mysql"} {
		for _, mode := range []string{"plan", "analyze"} {
			s := ExplainSupport(engine, map[string]string{"postgresql": "17.6", "mysql": "8.4.6"}[engine])
			r := protocol.ExplainRequest{SQL: "SELECT '🍺'", Mode: mode}
			p, err := PrepareExplain(s, r)
			if err != nil || p.Preview.SQL != p.Prefix+r.SQL || p.Preview.Mode != mode {
				t.Fatal("wrapper")
			}
			if mode == "plan" && strings.Contains(p.Prefix, "ANALYZE TRUE") || mode == "plan" && strings.Contains(p.Prefix, "ANALYZE FORMAT") {
				t.Fatal("plain plan executes")
			}
		}
	}
}
func TestExplainCaptureDrainsAndPreservesConfirmedCompletion(t *testing.T) {
	c := &ExplainCapture{}
	_ = c.Begin(0, []protocol.Column{{}})
	value := strings.Repeat("🍺", protocol.MaxExplainRawBytes/4+1)
	_ = c.Row(0, []*string{&value})
	after := "after"
	_ = c.Row(0, []*string{&after})
	if unsafe.StringData(c.Raw) == unsafe.StringData(value) {
		t.Fatal("bounded prefix retained the oversized driver backing string")
	}
	if !c.Limited || len(c.Raw) > protocol.MaxExplainRawBytes || !utf8.ValidString(c.Raw) {
		t.Fatal("capture bound")
	}
	p, _ := PrepareExplain(ExplainSupport("postgresql", "17.6"), protocol.ExplainRequest{SQL: "SELECT '🍺'", Mode: "analyze"})
	parser := func(context.Context, string, string) ([]protocol.ExplainNode, []string, map[string]protocol.ExplainMetric, error) {
		return nil, nil, nil, errors.New("unknown format")
	}
	response := protocol.Response{Type: "query.result", TransactionStatus: "transaction", DurationMS: 3.5}
	terminal := FinishExplain(context.Background(), protocol.Command{}, response, p, &ExplainCapture{Raw: "unfamiliar raw output"}, parser)
	if terminal.Type != "explain.result" || !terminal.SQLCompleted || terminal.OutcomeUnknown || terminal.TransactionStatus != "transaction" || terminal.Explain.Status != "rawOnly" || !terminal.Explain.Valid() {
		t.Fatal("parser failure changed SQL outcome")
	}
	ctx, cancel := context.WithCancel(context.Background())
	cancel()
	terminal = FinishExplain(ctx, protocol.Command{}, response, p, &ExplainCapture{Raw: "raw"}, parser)
	if !terminal.SQLCompleted || terminal.Type != "explain.result" {
		t.Fatal("late cancel erased completion")
	}
	for _, position := range []int{1, utf8.RuneCountInString(p.Prefix), utf8.RuneCountInString(p.Prefix) + 9, 100000} {
		r := protocol.Response{Type: "error", ErrorPosition: position, Connected: true, TransactionStatus: "failed"}
		mapped := FinishExplain(context.Background(), protocol.Command{}, r, p, c, parser)
		expected := 0
		if position > utf8.RuneCountInString(p.Prefix) && position <= utf8.RuneCountInString(p.Prefix+p.Request.SQL)+1 {
			expected = position - utf8.RuneCountInString(p.Prefix)
		}
		if mapped.ErrorPosition != expected || mapped.TransactionStatus != "failed" {
			t.Fatal("source coordinate mapping")
		}
	}
}

func TestExplainEscapedFrameKeepsBoundedPrefixAfterConfirmedSQL(t *testing.T) {
	prepared, _ := PrepareExplain(ExplainSupport("postgresql", "17.6"), protocol.ExplainRequest{SQL: "SELECT 1", Mode: "plan"})
	parser := func(context.Context, string, string) ([]protocol.ExplainNode, []string, map[string]protocol.ExplainMetric, error) {
		return nil, nil, nil, errors.New("unfamiliar")
	}
	capture := &ExplainCapture{Raw: strings.Repeat("\x00", protocol.MaxExplainRawBytes)}
	response := FinishExplain(context.Background(), protocol.Command{}, protocol.Response{Type: "query.result", TransactionStatus: "idle"}, prepared, capture, parser)
	encoded, err := json.Marshal(response)
	if err != nil || len(encoded) > protocol.MaxExplainResponseBytes || !response.SQLCompleted || response.Explain.Complete || response.Explain.Status != "limited" || len(response.Explain.Raw) == 0 || !response.Explain.Valid() {
		t.Fatal("escaped frame limit erased confirmed outcome or bounded prefix")
	}
}
