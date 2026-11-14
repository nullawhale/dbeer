package postgres

import (
	"encoding/json"
	"errors"
	"strconv"

	"dbeer/helper/internal/adapter"
	"dbeer/helper/internal/protocol"
)

var postgresCounterFields = []struct{ native, key, unit string }{
	{"Shared Hit Blocks", "sharedHitBlocks", "blocks"}, {"Shared Read Blocks", "sharedReadBlocks", "blocks"}, {"Shared Dirtied Blocks", "sharedDirtiedBlocks", "blocks"}, {"Shared Written Blocks", "sharedWrittenBlocks", "blocks"},
	{"Local Hit Blocks", "localHitBlocks", "blocks"}, {"Local Read Blocks", "localReadBlocks", "blocks"}, {"Local Dirtied Blocks", "localDirtiedBlocks", "blocks"}, {"Local Written Blocks", "localWrittenBlocks", "blocks"},
	{"Temp Read Blocks", "tempReadBlocks", "blocks"}, {"Temp Written Blocks", "tempWrittenBlocks", "blocks"},
	{"I/O Read Time", "ioReadTime", "ms"}, {"I/O Write Time", "ioWriteTime", "ms"},
	{"Shared I/O Read Time", "sharedIOReadTime", "ms"}, {"Shared I/O Write Time", "sharedIOWriteTime", "ms"}, {"Local I/O Read Time", "localIOReadTime", "ms"}, {"Local I/O Write Time", "localIOWriteTime", "ms"}, {"Temp I/O Read Time", "tempIOReadTime", "ms"}, {"Temp I/O Write Time", "tempIOWriteTime", "ms"},
	{"WAL Records", "walRecords", "count"}, {"WAL FPI", "walFPI", "count"}, {"WAL Bytes", "walBytes", "bytes"}, {"WAL Buffers Full", "walBuffersFull", "count"},
	{"Workers Planned", "workersPlanned", "count"}, {"Workers Launched", "workersLaunched", "count"},
}

func postgresAdvancedMetric(value any, unit, basis string) (protocol.ExplainMetric, error) {
	n, ok := value.(json.Number)
	if !ok || !protocol.ValidExplainDecimal(string(n)) {
		return protocol.ExplainMetric{}, errors.New("invalid advanced plan metric")
	}
	s := string(n)
	return adapter.ExplainMetric(&s, unit, basis, ""), nil
}
func postgresCounters(object map[string]any, worker bool) (map[string]protocol.ExplainMetric, error) {
	metrics := map[string]protocol.ExplainMetric{}
	for _, field := range postgresCounterFields {
		if value, exists := object[field.native]; exists {
			basis := "inclusiveTotal"
			if field.key == "workersPlanned" || field.key == "workersLaunched" {
				if worker {
					continue
				}
				basis = "total"
			}
			metric, err := postgresAdvancedMetric(value, field.unit, basis)
			if err != nil {
				return nil, err
			}
			metrics[field.key] = metric
		}
	}
	return metrics, nil
}
func postgresJIT(raw any, scope string, timingDisabled bool) (*protocol.ExplainJITMetrics, error) {
	if raw == nil {
		return nil, nil
	}
	object, ok := raw.(map[string]any)
	if !ok {
		return nil, errors.New("invalid JIT metrics")
	}
	jit := &protocol.ExplainJITMetrics{Scope: scope, Metrics: map[string]protocol.ExplainMetric{}}
	if value, exists := object["Functions"]; exists {
		metric, err := postgresAdvancedMetric(value, "count", "total")
		if err != nil {
			return nil, err
		}
		jit.Metrics["functions"] = metric
	}
	timing, exists := object["Timing"]
	if timingDisabled {
		for _, key := range []string{"generationTime", "deformTime", "inliningTime", "optimizationTime", "emissionTime", "totalTime"} {
			jit.Metrics[key] = adapter.ExplainMetric(nil, "ms", "total", "disabled")
		}
	} else if exists {
		object, ok := timing.(map[string]any)
		if !ok {
			return nil, errors.New("invalid JIT timing")
		}
		for _, field := range []struct{ native, key string }{{"Generation", "generationTime"}, {"Inlining", "inliningTime"}, {"Optimization", "optimizationTime"}, {"Emission", "emissionTime"}, {"Total", "totalTime"}} {
			value, exists := object[field.native]
			if !exists {
				continue
			}
			// PostgreSQL 17 split Generation into Total and Deform. Deform is
			// already included in Generation; neither is added to server Total.
			if field.native == "Generation" {
				if generation, ok := value.(map[string]any); ok {
					if deform, exists := generation["Deform"]; exists {
						metric, err := postgresAdvancedMetric(deform, "ms", "total")
						if err != nil {
							return nil, err
						}
						jit.Metrics["deformTime"] = metric
					}
					value, exists = generation["Total"]
					if !exists {
						continue
					}
				}
			}
			metric, err := postgresAdvancedMetric(value, "ms", "total")
			if err != nil {
				return nil, err
			}
			jit.Metrics[field.key] = metric
		}
	}
	return jit, nil
}
func decoratePostgresMetrics(nodes []protocol.ExplainNode, objects []map[string]any, mode string, timingDisabled bool, top map[string]any) error {
	scope := "serial"
	for _, object := range objects {
		operation, _ := object["Node Type"].(string)
		parallel, known := object["Parallel Aware"].(bool)
		async, _ := object["Async Capable"].(bool)
		_, planned := object["Workers Planned"]
		_, launched := object["Workers Launched"]
		workers, _ := object["Workers"].([]any)
		if parallel || operation == "Gather" || operation == "Gather Merge" || planned || launched || len(workers) > 0 {
			scope = "parallel"
			break
		}
		if !known || async {
			scope = "unknown"
		}
	}
	partial := map[string]bool{}
	for i := range nodes {
		node, object := &nodes[i], objects[i]
		counters, err := postgresCounters(object, false)
		if err != nil {
			return err
		}
		advanced := &protocol.ExplainNodeMetrics{Version: 1, ExecutionScope: scope, Counters: counters, Workers: []protocol.ExplainWorkerMetrics{}}
		advanced.RowComparison = adapter.ExplainRowComparison(*node, mode, scope, partial[node.ID])
		advanced.ExclusiveTime = adapter.ExplainExclusiveTime(*node, mode, scope, "postgresql")
		if raw, exists := object["Workers"]; exists {
			workers, ok := raw.([]any)
			if !ok || len(workers) > 256 {
				return errors.New("invalid worker metrics")
			}
			seen := map[int]bool{}
			for _, raw := range workers {
				worker, ok := raw.(map[string]any)
				if !ok {
					return errors.New("invalid worker metrics")
				}
				number, ok := worker["Worker Number"].(json.Number)
				if !ok {
					return errors.New("invalid worker number")
				}
				id, err := strconv.Atoi(string(number))
				if err != nil || id < 0 || id > 65535 || seen[id] {
					return errors.New("invalid worker number")
				}
				seen[id] = true
				metrics, err := postgresCounters(worker, true)
				if err != nil {
					return err
				}
				notExecuted := false
				if value, ok := worker["Actual Loops"].(json.Number); ok {
					notExecuted = adapter.ExplainNumberIsZero(string(value))
				}
				for _, field := range []struct{ native, key, unit, basis string }{{"Actual Rows", "actualRows", "rows", "perInvocation"}, {"Actual Startup Time", "startupTime", "ms", "perInvocation"}, {"Actual Total Time", "totalTime", "ms", "perInvocation"}, {"Actual Loops", "loops", "count", "total"}} {
					value, exists := worker[field.native]
					if !exists {
						continue
					}
					metric, err := postgresAdvancedMetric(value, field.unit, field.basis)
					if err != nil {
						return err
					}
					if notExecuted && field.key != "loops" {
						metric = adapter.ExplainMetric(nil, field.unit, field.basis, "notExecuted")
					} else if timingDisabled && (field.key == "startupTime" || field.key == "totalTime") {
						metric = adapter.ExplainMetric(nil, field.unit, field.basis, "disabled")
					}
					metrics[field.key] = metric
				}
				if timingDisabled && !notExecuted {
					for _, key := range []string{"startupTime", "totalTime"} {
						metrics[key] = adapter.ExplainMetric(nil, "ms", "perInvocation", "disabled")
					}
				}
				jit, err := postgresJIT(worker["JIT"], "worker", timingDisabled)
				if err != nil {
					return err
				}
				advanced.Workers = append(advanced.Workers, protocol.ExplainWorkerMetrics{Number: id, Metrics: metrics, JIT: jit})
			}
		}
		if i == 0 {
			advanced.JIT, err = postgresJIT(top["JIT"], "queryAggregate", timingDisabled)
			if err != nil {
				return err
			}
		}
		node.AdvancedMetrics = advanced
		join, _ := object["Join Type"].(string)
		unique, _ := object["Inner Unique"].(bool)
		if partial[node.ID] || node.Operation == "Limit" || node.Operation == "Merge Join" || join == "Semi" || join == "Anti" || unique {
			for _, child := range node.Children {
				partial[child] = true
			}
		}
	}
	return nil
}
