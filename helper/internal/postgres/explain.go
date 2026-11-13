package postgres

import (
	"context"
	"encoding/json"
	"errors"
	"io"
	"strconv"
	"strings"

	"dbeer/helper/internal/adapter"
	"dbeer/helper/internal/protocol"
)

func (s *Session) ExplainSupport() protocol.ExplainSupport {
	support := adapter.ExplainSupport("postgresql", s.conn.PgConn().ParameterStatus("server_version"))
	lower := strings.ToLower(s.explainIdentity)
	if !strings.HasPrefix(s.explainIdentity, "PostgreSQL ") || strings.Contains(lower, "yugabyte") || strings.Contains(lower, "cockroach") || strings.Contains(lower, "aurora") || strings.Contains(lower, "redshift") || strings.Contains(lower, "greenplum") {
		support.Modes = []string{}
		support.Options = nil
		support.AnalyzeUnavailableReason = ""
		support.PlanKinds = nil
		support.UnavailableReason = "Visual Explain requires a recognized PostgreSQL server; this server vendor could not be verified."
	}
	return support
}
func (s *Session) PrepareExplain(r protocol.ExplainRequest) (adapter.PreparedExplain, error) {
	return adapter.PrepareExplain(s.ExplainSupport(), r)
}
func (s *Session) ExecuteExplain(ctx context.Context, c protocol.Command) protocol.Response {
	p, err := s.PrepareExplain(*c.Explain)
	if err == nil && p.Preview.SQL != c.PreparedExplainSQL {
		err = errors.New("Explain requires fresh authorization of the exact prepared SQL.")
	}
	if err != nil {
		r := protocol.ErrorResponse(c, "validation", err.Error())
		r.SQLNotExecuted = true
		r.Connected = !s.conn.IsClosed()
		r.TransactionStatus = s.TransactionStatus()
		return r
	}
	capture := &adapter.ExplainCapture{}
	var values [][]byte
	var oids []uint32
	if p.Request.PlanKind != "generic" {
		for _, parameter := range p.Bound.Parameters {
			var value []byte
			if parameter.Value != nil {
				value = []byte(*parameter.Value)
			}
			values = append(values, value)
			oids = append(oids, map[string]uint32{"text": 25, "integer": 20, "decimal": 1700, "boolean": 16, "date": 1082, "timestamp": 1114}[parameter.Type])
		}
	}
	response := executeParamsSinkWithStorageOIDs(ctx, s.conn, c, p.Preview.SQL, values, capture, false, oids)
	return adapter.FinishExplain(ctx, c, response, p, capture, func(ctx context.Context, raw, mode string) ([]protocol.ExplainNode, []string, map[string]protocol.ExplainMetric, error) {
		return parseExplainJSONWithOptions(ctx, raw, mode, p.Request.Options)
	})
}
func parseExplainJSON(ctx context.Context, raw, mode string) ([]protocol.ExplainNode, []string, map[string]protocol.ExplainMetric, error) {
	return parseExplainJSONWithOptions(ctx, raw, mode, nil)
}
func parseExplainJSONWithOptions(ctx context.Context, raw, mode string, options *protocol.ExplainOptions) ([]protocol.ExplainNode, []string, map[string]protocol.ExplainMetric, error) {
	timingDisabled := options != nil && options.PostgreSQL != nil && options.PostgreSQL.Timing != nil && !*options.PostgreSQL.Timing
	fail := func() ([]protocol.ExplainNode, []string, map[string]protocol.ExplainMetric, error) {
		return nil, nil, nil, errors.New("unsupported plan")
	}
	decoder := json.NewDecoder(strings.NewReader(raw))
	decoder.UseNumber()
	var roots []map[string]any
	if decoder.Decode(&roots) != nil || len(roots) != 1 {
		return fail()
	}
	var trailing any
	if decoder.Decode(&trailing) != io.EOF {
		return fail()
	}
	nodes := []protocol.ExplainNode{}
	metrics := map[string]protocol.ExplainMetric{}
	metric := func(v any, unit, basis, reason string) (protocol.ExplainMetric, error) {
		var text *string
		if v != nil {
			n, ok := v.(json.Number)
			if !ok || !protocol.ValidExplainDecimal(string(n)) {
				return protocol.ExplainMetric{}, errors.New("metric")
			}
			t := string(n)
			text = &t
		}
		return adapter.ExplainMetric(text, unit, basis, reason), nil
	}
	var visit func(map[string]any, int) (string, error)
	visit = func(plan map[string]any, depth int) (string, error) {
		if ctx.Err() != nil || depth > protocol.MaxExplainDepth || len(nodes) >= protocol.MaxExplainNodes {
			return "", errors.New("limit")
		}
		label, ok := plan["Node Type"].(string)
		if !ok || label == "" {
			return "", errors.New("node")
		}
		id := strconv.Itoa(len(nodes))
		node := protocol.ExplainNode{ID: id, Operation: label, Children: []string{}, Details: map[string]string{}, Metrics: map[string]protocol.ExplainMetric{}, Execution: "estimated"}
		if mode == "analyze" {
			node.Execution = "executed"
			if loops, ok := plan["Actual Loops"].(json.Number); ok && string(loops) == "0" {
				node.Execution = "notExecuted"
			}
		}
		fields := []struct {
			native, key, unit, basis string
			actual                   bool
		}{{"Startup Cost", "startupCost", "cost", "inclusive", false}, {"Total Cost", "totalCost", "cost", "inclusive", false}, {"Plan Rows", "estimatedRows", "rows", "perInvocation", false}, {"Actual Rows", "actualRows", "rows", "perInvocation", true}, {"Actual Loops", "loops", "count", "total", true}, {"Actual Startup Time", "startupTime", "ms", "perInvocation", true}, {"Actual Total Time", "totalTime", "ms", "perInvocation", true}}
		for _, f := range fields {
			reason := "notReported"
			if f.actual && mode == "plan" {
				reason = "notCollected"
			}
			if f.actual && f.key != "loops" && node.Execution == "notExecuted" {
				reason = "notExecuted"
			}
			value := plan[f.native]
			if f.actual && (mode == "plan" || f.key != "loops" && node.Execution == "notExecuted") {
				value = nil
			}
			if timingDisabled && (f.key == "startupTime" || f.key == "totalTime") && node.Execution != "notExecuted" {
				value = nil
				reason = "disabled"
			}
			m, err := metric(value, f.unit, f.basis, reason)
			if err != nil {
				return "", err
			}
			node.Metrics[f.key] = m
		}
		for key, value := range plan {
			if key == "Plans" {
				continue
			}
			switch v := value.(type) {
			case string:
				node.Details[key] = v
			case bool:
				node.Details[key] = strconv.FormatBool(v)
			case json.Number:
				node.Details[key] = string(v)
			case []any:
				if key == "Workers" || key == "Output" || key == "Sort Key" || key == "Group Key" {
					data, err := json.Marshal(v)
					if err == nil && len(data) <= 65536 {
						node.Details[key] = string(data)
					}
				}
			}
		}
		index := len(nodes)
		nodes = append(nodes, node)
		if children, exists := plan["Plans"]; exists {
			array, ok := children.([]any)
			if !ok {
				return "", errors.New("children")
			}
			for _, child := range array {
				p, ok := child.(map[string]any)
				if !ok {
					return "", errors.New("child")
				}
				childID, err := visit(p, depth+1)
				if err != nil {
					return "", err
				}
				nodes[index].Children = append(nodes[index].Children, childID)
			}
		}
		return id, nil
	}
	plan, ok := roots[0]["Plan"].(map[string]any)
	if !ok {
		return fail()
	}
	id, err := visit(plan, 1)
	if err != nil {
		return fail()
	}
	for _, key := range []string{"Settings", "Planning", "Planning Memory", "Serialization", "JIT", "Triggers"} {
		if value, exists := roots[0][key]; exists {
			data, err := json.Marshal(value)
			if err == nil && len(data) <= 65536 {
				nodes[0].Details[key] = string(data)
			}
		}
	}
	for _, pair := range []struct{ native, key string }{{"Planning Time", "planningTime"}, {"Execution Time", "executionTime"}} {
		reason := "notReported"
		if mode == "plan" && pair.key == "executionTime" {
			reason = "notCollected"
		}
		m, err := metric(roots[0][pair.native], "ms", "total", reason)
		if err != nil {
			return fail()
		}
		metrics[pair.key] = m
	}
	return nodes, []string{id}, metrics, nil
}
