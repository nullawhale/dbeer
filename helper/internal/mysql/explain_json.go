package mysql

import (
	"context"
	"encoding/json"
	"errors"
	"io"
	"sort"
	"strconv"
	"strings"

	"dbeer/helper/internal/adapter"
	"dbeer/helper/internal/protocol"
)

func mysqlPlanFormat(raw string) string {
	if strings.HasPrefix(strings.TrimSpace(raw), "{") {
		var document map[string]json.RawMessage
		if json.Unmarshal([]byte(raw), &document) == nil {
			if _, ok := document["query_block"]; ok {
				return "jsonV1"
			}
			if _, ok := document["operation"]; ok {
				return "jsonV2"
			}
		}
		return "json"
	}
	return "tree"
}
func parseExplainPlan(ctx context.Context, raw, mode string) ([]protocol.ExplainNode, []string, map[string]protocol.ExplainMetric, error) {
	if strings.HasPrefix(strings.TrimSpace(raw), "{") {
		return parseExplainJSON(ctx, raw, mode)
	}
	return parseExplainTree(ctx, raw, mode)
}
func mysqlJSONMetric(value any, unit, basis, reason string) (protocol.ExplainMetric, error) {
	var text *string
	if value != nil {
		var s string
		switch v := value.(type) {
		case json.Number:
			s = string(v)
		case string:
			s = v
		default:
			return protocol.ExplainMetric{}, errors.New("invalid JSON plan metric")
		}
		if !protocol.ValidExplainDecimal(s) {
			return protocol.ExplainMetric{}, errors.New("invalid JSON plan metric")
		}
		text = &s
	}
	return adapter.ExplainMetric(text, unit, basis, reason), nil
}
func mysqlJSONNode(id, operation, mode string) protocol.ExplainNode {
	node := protocol.ExplainNode{ID: id, Operation: operation, Children: []string{}, Details: map[string]string{}, Metrics: map[string]protocol.ExplainMetric{}, Execution: "estimated"}
	if mode == "analyze" {
		node.Execution = "unknown"
	}
	for _, field := range []struct {
		key, unit, basis string
		actual           bool
	}{{"startupCost", "cost", "inclusive", false}, {"totalCost", "cost", "inclusive", false}, {"estimatedRows", "rows", "perInvocation", false}, {"actualRows", "rows", "perInvocation", true}, {"loops", "count", "total", true}, {"startupTime", "ms", "perInvocation", true}, {"totalTime", "ms", "perInvocation", true}} {
		reason := "notReported"
		if field.actual && mode == "plan" {
			reason = "notCollected"
		}
		node.Metrics[field.key] = adapter.ExplainMetric(nil, field.unit, field.basis, reason)
	}
	return node
}
func containsJSONIterator(value any) bool {
	switch v := value.(type) {
	case map[string]any:
		if _, ok := v["operation"]; ok {
			return true
		}
		for _, child := range v {
			if containsJSONIterator(child) {
				return true
			}
		}
	case []any:
		for _, child := range v {
			if containsJSONIterator(child) {
				return true
			}
		}
	}
	return false
}
func mysqlJSONDetails(node *protocol.ExplainNode, object map[string]any, excluded map[string]bool) error {
	for key, value := range object {
		if excluded[key] {
			continue
		}
		var text string
		if s, ok := value.(string); ok {
			text = s
		} else {
			data, err := json.Marshal(value)
			if err != nil {
				return err
			}
			text = string(data)
		}
		if len(node.Details) >= 128 || len(key) > 1024 || len(text) > 65536 {
			return errors.New("JSON plan detail limit")
		}
		node.Details[key] = text
	}
	return nil
}
func parseExplainJSON(ctx context.Context, raw, mode string) ([]protocol.ExplainNode, []string, map[string]protocol.ExplainMetric, error) {
	fail := func() ([]protocol.ExplainNode, []string, map[string]protocol.ExplainMetric, error) {
		return nil, nil, nil, errors.New("unsupported JSON plan")
	}
	decoder := json.NewDecoder(strings.NewReader(raw))
	decoder.UseNumber()
	var document map[string]any
	if decoder.Decode(&document) != nil || document == nil {
		return fail()
	}
	var trailing any
	if decoder.Decode(&trailing) != io.EOF {
		return fail()
	}
	nodes := []protocol.ExplainNode{}
	set := func(node *protocol.ExplainNode, key string, value any) error {
		m := node.Metrics[key]
		metric, err := mysqlJSONMetric(value, m.Unit, m.Basis, m.UnavailableReason)
		node.Metrics[key] = metric
		return err
	}
	var visitV2 func(map[string]any, int) (string, error)
	visitV2 = func(object map[string]any, depth int) (string, error) {
		if ctx.Err() != nil || depth > protocol.MaxExplainDepth || len(nodes) >= protocol.MaxExplainNodes {
			return "", errors.New("JSON plan limit")
		}
		operation, ok := object["operation"].(string)
		if !ok || operation == "" {
			return "", errors.New("JSON iterator missing operation")
		}
		id := strconv.Itoa(len(nodes))
		node := mysqlJSONNode(id, operation, mode)
		for _, f := range []struct{ native, key string }{{"estimated_total_cost", "totalCost"}, {"estimated_rows", "estimatedRows"}} {
			if err := set(&node, f.key, object[f.native]); err != nil {
				return "", err
			}
		}
		if mode == "analyze" {
			if err := set(&node, "loops", object["actual_loops"]); err != nil {
				return "", err
			}
			if m := node.Metrics["loops"]; m.Value != nil {
				if zeroExplainNumber(*m.Value) {
					node.Execution = "notExecuted"
				} else {
					node.Execution = "executed"
				}
			}
			for _, f := range []struct{ native, key string }{{"actual_rows", "actualRows"}, {"actual_first_row_ms", "startupTime"}, {"actual_last_row_ms", "totalTime"}} {
				if node.Execution == "notExecuted" {
					m := node.Metrics[f.key]
					m.UnavailableReason = "notExecuted"
					node.Metrics[f.key] = m
					continue
				}
				if err := set(&node, f.key, object[f.native]); err != nil {
					return "", err
				}
			}
		}
		for key, value := range object {
			if key != "inputs" && containsJSONIterator(value) {
				return "", errors.New("unrecognized JSON iterator child")
			}
		}
		if err := mysqlJSONDetails(&node, object, map[string]bool{"inputs": true}); err != nil {
			return "", err
		}
		index := len(nodes)
		nodes = append(nodes, node)
		if raw, exists := object["inputs"]; exists {
			inputs, ok := raw.([]any)
			if !ok {
				return "", errors.New("JSON iterator inputs")
			}
			for _, raw := range inputs {
				input, ok := raw.(map[string]any)
				if !ok {
					return "", errors.New("JSON iterator child")
				}
				child, err := visitV2(input, depth+1)
				if err != nil {
					return "", err
				}
				nodes[index].Children = append(nodes[index].Children, child)
			}
		}
		return id, nil
	}
	var visitV1 func(string, map[string]any, int) (string, error)
	// V1 is a logical query-block/access representation, not the iterator tree.
	// In particular prefix_cost and rows_produced_per_join are not per-access metrics.
	structural := map[string]bool{"query_block": true, "table": true, "nested_loop": true, "grouping_operation": true, "ordering_operation": true, "duplicates_removal": true, "union_result": true, "query_specifications": true, "materialized_from_subquery": true, "attached_subqueries": true, "optimized_away_subqueries": true, "select_list_subqueries": true, "buffer_result": true, "windowing": true, "windows": true, "having_subqueries": true, "insert_from": true}
	visitV1 = func(kind string, object map[string]any, depth int) (string, error) {
		if ctx.Err() != nil || depth > protocol.MaxExplainDepth || len(nodes) >= protocol.MaxExplainNodes {
			return "", errors.New("JSON plan limit")
		}
		label := strings.ReplaceAll(kind, "_", " ")
		if kind == "query_block" {
			label = "Query block"
			if v, ok := object["select_id"].(json.Number); ok {
				label += " " + string(v)
			}
		}
		if kind == "table" {
			label = "Table access"
			if v, ok := object["access_type"].(string); ok {
				label += " " + v
			}
			if v, ok := object["table_name"].(string); ok {
				label += " on " + v
			}
		}
		id := strconv.Itoa(len(nodes))
		node := mysqlJSONNode(id, label, mode)
		node.Details["Format meaning"] = "MySQL JSON v1 logical query blocks and accesses; not an iterator execution tree."
		if kind == "query_block" {
			if cost, ok := object["cost_info"].(map[string]any); ok {
				if err := set(&node, "totalCost", cost["query_cost"]); err != nil {
					return "", err
				}
			}
		}
		if kind == "table" {
			node.Metrics["totalCost"] = adapter.ExplainMetric(nil, "cost", "inclusive", "unsupported")
			if err := set(&node, "estimatedRows", object["rows_examined_per_scan"]); err != nil {
				return "", err
			}
			node.Details["Row estimate basis"] = "rows_examined_per_scan is examined input per scan; rows_produced_per_join remains native evidence, not output per invocation."
		}
		if err := mysqlJSONDetails(&node, object, structural); err != nil {
			return "", err
		}
		index := len(nodes)
		nodes = append(nodes, node)
		keys := []string{}
		for key := range object {
			if structural[key] {
				keys = append(keys, key)
			}
		}
		sort.Strings(keys)
		for _, key := range keys {
			var objects []map[string]any
			switch v := object[key].(type) {
			case map[string]any:
				objects = append(objects, v)
			case []any:
				for _, child := range v {
					m, ok := child.(map[string]any)
					if !ok {
						return "", errors.New("JSON v1 child")
					}
					objects = append(objects, m)
				}
			default:
				return "", errors.New("JSON v1 structure")
			}
			for _, object := range objects {
				child, err := visitV1(key, object, depth+1)
				if err != nil {
					return "", err
				}
				nodes[index].Children = append(nodes[index].Children, child)
			}
		}
		return id, nil
	}
	var root string
	var err error
	if block, exists := document["query_block"]; exists {
		object, ok := block.(map[string]any)
		if !ok || mode != "plan" || len(document) != 1 {
			return fail()
		}
		root, err = visitV1("query_block", object, 1)
	} else {
		root, err = visitV2(document, 1)
	}
	if err != nil {
		return fail()
	}
	return nodes, []string{root}, map[string]protocol.ExplainMetric{}, nil
}
func zeroExplainNumber(value string) bool {
	for _, c := range strings.SplitN(strings.ToLower(value), "e", 2)[0] {
		if c != '0' && c != '.' {
			return false
		}
	}
	return true
}
