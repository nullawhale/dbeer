package mariadb

import (
	"context"
	"encoding/json"
	"errors"
	"io"
	"sort"
	"strconv"
	"strings"

	"dbeer/helper/internal/adapter"
	"dbeer/helper/internal/jsoncheck"
	"dbeer/helper/internal/protocol"
)

var errMariaDBPlan = errors.New("The native MariaDB JSON plan cannot be normalized completely within the plan limits.")

func mariaDBPlanMetric(value any, unit, basis, reason string) (protocol.ExplainMetric, error) {
	if value == nil {
		return adapter.ExplainMetric(nil, unit, basis, reason), nil
	}
	var text string
	switch value := value.(type) {
	case json.Number:
		text = value.String()
	case string:
		text = value
	default:
		return protocol.ExplainMetric{}, errMariaDBPlan
	}
	if !protocol.ValidExplainDecimal(text) {
		return protocol.ExplainMetric{}, errMariaDBPlan
	}
	return adapter.ExplainMetric(&text, unit, basis, ""), nil
}

func mariaDBPlanZero(text string) bool {
	mantissa := strings.FieldsFunc(text, func(r rune) bool { return r == 'e' || r == 'E' })[0]
	return strings.Trim(mantissa, "0.") == ""
}

func mariaDBPlanInteger(value string) bool {
	for _, digit := range value {
		if digit < '0' || digit > '9' {
			return false
		}
	}
	return value != ""
}

var mariaDBEngineCounters = []struct{ native, key, unit string }{
	{"pages_accessed", "mariaDBPagesAccessed", "count"},
	{"pages_updated", "mariaDBPagesUpdated", "count"},
	{"pages_read_count", "mariaDBPagesRead", "count"},
	{"pages_prefetch_read_count", "mariaDBPagesPrefetched", "count"},
	{"pages_read_time_ms", "mariaDBPagesReadTime", "ms"},
	{"old_rows_read", "mariaDBOldRowsRead", "rows"},
}

func mariaDBAdvancedMetrics(node *protocol.ExplainNode, object map[string]any, mode string) error {
	scope := "logical"
	if strings.HasPrefix(node.Operation, "Table access ") {
		// A native table label alone does not prove a storage engine's execution
		// scope, nor that LIMIT or another consumer read all available input.
		scope = "unknown"
	}
	advanced := &protocol.ExplainNodeMetrics{Version: 1, ExecutionScope: scope,
		RowComparison: adapter.ExplainRowComparison(*node, mode, scope, false),
		ExclusiveTime: adapter.ExplainMetric(nil, "ms", "exclusivePerInvocation", "inclusiveOnly"),
		Counters:      map[string]protocol.ExplainMetric{}, Workers: []protocol.ExplainWorkerMetrics{}}
	if mode == "plan" {
		advanced.ExclusiveTime.UnavailableReason = "notCollected"
	} else if node.Execution == "notExecuted" {
		advanced.ExclusiveTime.UnavailableReason = "notExecuted"
	}
	if scope != "logical" {
		stats, present := object["r_engine_stats"]
		values, ok := stats.(map[string]any)
		if present && !ok {
			return errMariaDBPlan
		}
		for _, field := range mariaDBEngineCounters {
			value, member := values[field.native]
			reason := "notReported"
			if member && value == nil {
				return errMariaDBPlan
			}
			if mode == "plan" {
				reason, value = "notCollected", nil
			} else if present && !member {
				// The verified native version floor includes the documented
				// nonzero-only r_engine_stats contract. No object means no proof.
				value = json.Number("0")
			}
			metric, err := mariaDBPlanMetric(value, field.unit, "total", reason)
			if err != nil {
				return err
			}
			if field.native != "pages_read_time_ms" && metric.Value != nil && !mariaDBPlanInteger(*metric.Value) {
				return errMariaDBPlan
			}
			advanced.Counters[field.key] = metric
		}
	}
	node.AdvancedMetrics = advanced
	return nil
}

func mariaDBPlanNode(id, kind, mode string, object map[string]any) (protocol.ExplainNode, error) {
	node := protocol.ExplainNode{ID: id, Children: []string{}, Operation: strings.ReplaceAll(kind, "_", " "), Details: map[string]string{}, Metrics: map[string]protocol.ExplainMetric{}, Execution: "estimated"}
	if kind == "table" {
		name, nameOK := object["table_name"].(string)
		access, accessOK := object["access_type"].(string)
		if !nameOK || name == "" || !accessOK || access == "" {
			return node, errMariaDBPlan
		}
		node.Operation = "Table access " + access + " on " + name
	}
	if mode == "analyze" {
		node.Execution = "unknown"
	}
	fields := []struct{ native, key, unit, basis string }{
		{"rows", "estimatedRows", "rows", "perInvocation"},
		{"r_rows", "actualRows", "rows", "perInvocation"},
		{"r_loops", "loops", "count", "total"},
		{"r_total_time_ms", "totalTime", "ms", "inclusiveTotal"},
	}
	for _, field := range fields {
		reason, value := "notReported", object[field.native]
		if mode == "plan" && strings.HasPrefix(field.native, "r_") {
			reason, value = "notCollected", nil
		}
		metric, err := mariaDBPlanMetric(value, field.unit, field.basis, reason)
		if err != nil {
			return node, err
		}
		if field.native == "r_loops" && metric.Value != nil && !mariaDBPlanInteger(*metric.Value) {
			return node, errMariaDBPlan
		}
		node.Metrics[field.key] = metric
	}
	if mode == "analyze" {
		if loops := node.Metrics["loops"].Value; loops != nil {
			node.Execution = "executed"
			if mariaDBPlanZero(*loops) {
				node.Execution = "notExecuted"
				for _, key := range []string{"actualRows", "totalTime"} {
					metric := node.Metrics[key]
					node.Metrics[key] = adapter.ExplainMetric(nil, metric.Unit, metric.Basis, "notExecuted")
				}
			}
		}
	}
	return node, nil
}

// Native object keys describe the tree. Array order (notably nested_loop) is
// authoritative; object-key order is canonicalized only for stable node IDs.
func parseMariaDBExplainJSON(ctx context.Context, raw, mode string) ([]protocol.ExplainNode, []string, map[string]protocol.ExplainMetric, error) {
	if len(raw) > protocol.MaxExplainRawBytes || mode != "plan" && mode != "analyze" || !jsoncheck.UnicodeValid([]byte(raw)) || !jsoncheck.UniqueObjectKeys([]byte(raw)) {
		return nil, nil, nil, errMariaDBPlan
	}
	decoder := json.NewDecoder(strings.NewReader(raw))
	decoder.UseNumber()
	var document map[string]any
	if decoder.Decode(&document) != nil || document == nil {
		return nil, nil, nil, errMariaDBPlan
	}
	var trailing any
	if decoder.Decode(&trailing) != io.EOF {
		return nil, nil, nil, errMariaDBPlan
	}
	query, ok := document["query_block"].(map[string]any)
	if !ok {
		return nil, nil, nil, errMariaDBPlan
	}
	nodes := []protocol.ExplainNode{}
	containers := map[string]bool{"query_block": true, "table": true, "nested_loop": true, "read_sorted_file": true, "filesort": true, "block-nl-join": true, "range-checked-for-each-record": true, "union_result": true, "query_specifications": true, "duplicates_removal": true, "materialized": true, "subqueries": true, "expression_cache": true, "expression-cache": true, "window_functions_computation": true, "temporary_table": true, "grouping_operation": true, "ordering_operation": true}
	var visit func(string, map[string]any, int) (string, error)
	var children func(string, any, int) ([]string, error)
	children = func(kind string, value any, depth int) ([]string, error) {
		if depth > protocol.MaxExplainDepth || ctx.Err() != nil {
			return nil, errMariaDBPlan
		}
		if object, ok := value.(map[string]any); ok {
			id, err := visit(kind, object, depth)
			return []string{id}, err
		}
		array, ok := value.([]any)
		if !ok {
			return nil, errMariaDBPlan
		}
		ids := []string{}
		for _, item := range array {
			object, ok := item.(map[string]any)
			if !ok {
				return nil, errMariaDBPlan
			}
			id, err := visit(kind, object, depth)
			if err != nil {
				return nil, err
			}
			ids = append(ids, id)
		}
		return ids, nil
	}
	visit = func(kind string, object map[string]any, depth int) (string, error) {
		if depth > protocol.MaxExplainDepth || len(nodes) >= protocol.MaxExplainNodes || ctx.Err() != nil {
			return "", errMariaDBPlan
		}
		id := strconv.Itoa(len(nodes))
		node, err := mariaDBPlanNode(id, kind, mode, object)
		if err != nil {
			return "", err
		}
		index := len(nodes)
		nodes = append(nodes, node)
		keys := make([]string, 0, len(object))
		for key := range object {
			keys = append(keys, key)
		}
		sort.Strings(keys)
		for _, key := range keys {
			if containers[key] {
				ids, err := children(key, object[key], depth+1)
				if err != nil {
					return "", err
				}
				nodes[index].Children = append(nodes[index].Children, ids...)
				continue
			}
			if mariaDBNestedPlan(object[key], depth+1) {
				return "", errMariaDBPlan
			}
			text, ok := object[key].(string)
			if !ok {
				encoded, err := json.Marshal(object[key])
				if err != nil {
					return "", err
				}
				text = string(encoded)
			}
			if len(nodes[index].Details) >= 128 || len(key) > 1024 || len(text) > 65536 {
				return "", errMariaDBPlan
			}
			nodes[index].Details[key] = text
		}
		if err := mariaDBAdvancedMetrics(&nodes[index], object, mode); err != nil {
			return "", err
		}
		return id, nil
	}
	root, err := visit("query_block", query, 1)
	if err != nil {
		return nil, nil, nil, err
	}
	metrics := map[string]protocol.ExplainMetric{}
	if mode == "analyze" {
		value, err := mariaDBPlanMetric(query["r_total_time_ms"], "ms", "inclusiveTotal", "notReported")
		if err != nil {
			return nil, nil, nil, err
		}
		metrics["executionTime"] = value
	}
	return nodes, []string{root}, metrics, nil
}

// Unknown wrappers containing execution nodes require Raw Plan rather than a
// tree which silently leaves out their native children.
func mariaDBNestedPlan(value any, depth int) bool {
	if depth > protocol.MaxExplainDepth {
		return true
	}
	switch value := value.(type) {
	case map[string]any:
		for key, child := range value {
			if key == "table_name" || key == "query_block" || key == "nested_loop" || mariaDBNestedPlan(child, depth+1) {
				return true
			}
		}
	case []any:
		for _, child := range value {
			if mariaDBNestedPlan(child, depth+1) {
				return true
			}
		}
	}
	return false
}
