package sqlite

import (
	"context"
	"encoding/json"
	"errors"
	"strconv"

	"dbeer/helper/internal/adapter"
	"dbeer/helper/internal/protocol"
	"dbeer/helper/internal/queryparams"
	"dbeer/helper/internal/safety"
)

func (s *Session) ExplainSupport() protocol.ExplainSupport {
	version := "SQLite"
	rows, _, err := s.query(context.Background(), "SELECT sqlite_version()")
	if err == nil && len(rows) == 1 {
		version = cellText(rows[0][0])
	}
	return protocol.ExplainSupport{Engine: "sqlite", ServerVersion: version, Format: "queryPlan", Modes: []string{"plan"}}
}
func (s *Session) PrepareExplain(r protocol.ExplainRequest) (adapter.PreparedExplain, error) {
	p := adapter.PreparedExplain{Request: r, Prefix: "EXPLAIN QUERY PLAN\n"}
	bound, err := queryparams.Bind("sqlite", r.SQL, r.Parameters)
	if r.Mode != "plan" || r.PlanKind != "" || !r.Valid() || err != nil || !safety.VisualExplainTarget("sqlite", bound.AssessmentSQL) {
		return p, errors.New("SQLite Explain requires one SELECT or read CTE; Analyze is unavailable.")
	}
	p.Bound = bound
	p.Preview = protocol.ExplainPreview{SQL: p.Prefix + bound.SQL, Mode: r.Mode, Support: s.ExplainSupport()}
	return p, nil
}
func (s *Session) ExecuteExplain(ctx context.Context, c protocol.Command) protocol.Response {
	if c.Explain == nil {
		return s.fail(c, ctx, errors.New("Missing Explain request."))
	}
	p, err := s.PrepareExplain(*c.Explain)
	if err != nil {
		return s.fail(c, ctx, err)
	}
	if p.Preview.SQL != c.PreparedExplainSQL {
		return s.fail(c, ctx, errors.New("Explain requires the exact prepared SQL."))
	}
	args := make([]any, len(p.Bound.Parameters))
	for i, parameter := range p.Bound.Parameters {
		if parameter.Value == nil {
			continue
		}
		switch parameter.Type {
		case "integer":
			args[i], _ = strconv.ParseInt(*parameter.Value, 10, 64)
		case "boolean":
			args[i] = *parameter.Value == "true"
		default:
			args[i] = *parameter.Value
		}
	}
	rows, _, err := s.query(ctx, p.Preview.SQL, args...)
	if err != nil {
		return s.fail(c, ctx, err)
	}
	nodes := []protocol.ExplainNode{}
	roots := []string{}
	parents := map[string]string{}
	ids := map[string]int{}
	rawRows := [][]any{}
	for _, row := range rows {
		if len(row) != 4 {
			return s.fail(c, ctx, errors.New("Unexpected SQLite query plan format."))
		}
		id, parent := row[0].Value, row[1].Value
		detail := cellText(row[3])
		ids[id] = len(nodes)
		parents[id] = parent
		nodes = append(nodes, protocol.ExplainNode{ID: id, Children: []string{}, Operation: detail, Execution: "estimated", Details: map[string]string{}, Metrics: map[string]protocol.ExplainMetric{}})
		rawRows = append(rawRows, []any{cellInt(row[0]), cellInt(row[1]), cellInt(row[2]), detail})
	}
	for i := range nodes {
		if p, ok := ids[parents[nodes[i].ID]]; ok && p != i {
			nodes[p].Children = append(nodes[p].Children, nodes[i].ID)
		} else {
			roots = append(roots, nodes[i].ID)
		}
	}
	raw, _ := json.MarshalIndent(rawRows, "", "  ")
	result := protocol.ExplainResult{Support: p.Preview.Support, Mode: "plan", Status: "tree", Raw: string(raw), Complete: true, Roots: roots, Nodes: nodes, Metrics: map[string]protocol.ExplainMetric{}}
	if len(nodes) == 0 {
		result.Status = "rawOnly"
		result.Diagnostic = "SQLite returned no plan operations."
	}
	if len(raw) > protocol.MaxExplainRawBytes || len(nodes) > protocol.MaxExplainNodes {
		result.Status = "limited"
		result.Complete = false
		result.Nodes = []protocol.ExplainNode{}
		result.Roots = []string{}
		result.Raw = ""
		result.Diagnostic = "The query plan exceeded its capture limit."
	}
	if !result.Valid() {
		return s.fail(c, ctx, errors.New("The SQLite query plan could not be represented safely ("+strconv.Itoa(len(nodes))+" operations)."))
	}
	return protocol.Response{Type: "explain.result", RequestID: c.RequestID, SessionID: c.SessionID, QueryID: c.QueryID, Explain: &result, Connected: true, TransactionStatus: s.TransactionStatus(), SQLCompleted: true}
}
