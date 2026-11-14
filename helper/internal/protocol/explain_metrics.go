package protocol

import (
	"encoding/json"
	"errors"
	"strings"
)

const ExplainMetricsCapability = "explainMetricsV1"

// PostgreSQL counters include child work and all loops; MariaDB counters are
// native table-access totals with no inferred child inclusion. Neither is
// multiplied by loops. Worker evidence overlaps PostgreSQL node evidence.
type ExplainNodeMetrics struct {
	Version        int                      `json:"version"`
	ExecutionScope string                   `json:"executionScope"`
	RowComparison  string                   `json:"rowComparison"`
	ExclusiveTime  ExplainMetric            `json:"exclusiveTime"`
	Counters       map[string]ExplainMetric `json:"counters"`
	Workers        []ExplainWorkerMetrics   `json:"workers"`
	JIT            *ExplainJITMetrics       `json:"jit,omitempty"`
}
type ExplainWorkerMetrics struct {
	Number  int                      `json:"number"`
	Metrics map[string]ExplainMetric `json:"metrics"`
	JIT     *ExplainJITMetrics       `json:"jit,omitempty"`
}
type ExplainJITMetrics struct {
	Scope   string                   `json:"scope"`
	Metrics map[string]ExplainMetric `json:"metrics"`
}
type ExplainPlanMetrics struct {
	Version int `json:"version"`
}

func (v *ExplainMetric) UnmarshalJSON(raw []byte) error {
	if _, ok := changesObject(raw, "value|unit|basis|unavailableReason", "unit", "basis"); !ok {
		return errExplainMetrics
	}
	type plain ExplainMetric
	return json.Unmarshal(raw, (*plain)(v))
}
func (v *ExplainNode) UnmarshalJSON(raw []byte) error {
	if f, ok := changesObject(raw, "id|children|operation|details|execution|metrics|advancedMetrics", "id", "children", "operation", "details", "execution", "metrics"); !ok || string(f["advancedMetrics"]) == "null" {
		return errExplainMetrics
	}
	type plain ExplainNode
	return json.Unmarshal(raw, (*plain)(v))
}
func (v *ExplainResult) UnmarshalJSON(raw []byte) error {
	if f, ok := changesObject(raw, "support|mode|status|raw|complete|diagnostic|roots|nodes|metrics|engineDiagnostic|options|format|advancedMetrics", "support", "mode", "status", "raw", "complete", "roots", "nodes", "metrics"); !ok || string(f["advancedMetrics"]) == "null" {
		return errExplainMetrics
	}
	type plain ExplainResult
	return json.Unmarshal(raw, (*plain)(v))
}

func (v *ExplainNodeMetrics) UnmarshalJSON(raw []byte) error {
	if f, ok := changesObject(raw, "version|executionScope|rowComparison|exclusiveTime|counters|workers|jit", "version", "executionScope", "rowComparison", "exclusiveTime", "counters", "workers"); !ok || string(f["jit"]) == "null" {
		return errExplainMetrics
	}
	type plain ExplainNodeMetrics
	return json.Unmarshal(raw, (*plain)(v))
}
func (v *ExplainWorkerMetrics) UnmarshalJSON(raw []byte) error {
	if f, ok := changesObject(raw, "number|metrics|jit", "number", "metrics"); !ok || string(f["jit"]) == "null" {
		return errExplainMetrics
	}
	type plain ExplainWorkerMetrics
	return json.Unmarshal(raw, (*plain)(v))
}
func (v *ExplainJITMetrics) UnmarshalJSON(raw []byte) error {
	if _, ok := changesObject(raw, "scope|metrics", "scope", "metrics"); !ok {
		return errExplainMetrics
	}
	type plain ExplainJITMetrics
	return json.Unmarshal(raw, (*plain)(v))
}
func (v *ExplainPlanMetrics) UnmarshalJSON(raw []byte) error {
	if _, ok := changesObject(raw, "version", "version"); !ok {
		return errExplainMetrics
	}
	type plain ExplainPlanMetrics
	return json.Unmarshal(raw, (*plain)(v))
}

var errExplainMetrics = errors.New("invalid advanced Explain metrics")

func explainCounterUnit(key string) string {
	switch key {
	case "sharedHitBlocks", "sharedReadBlocks", "sharedDirtiedBlocks", "sharedWrittenBlocks", "localHitBlocks", "localReadBlocks", "localDirtiedBlocks", "localWrittenBlocks", "tempReadBlocks", "tempWrittenBlocks":
		return "blocks"
	case "ioReadTime", "ioWriteTime", "sharedIOReadTime", "sharedIOWriteTime", "localIOReadTime", "localIOWriteTime", "tempIOReadTime", "tempIOWriteTime":
		return "ms"
	case "walBytes":
		return "bytes"
	case "walRecords", "walFPI", "walBuffersFull":
		return "count"
	case "workersPlanned", "workersLaunched":
		return "count"
	}
	return ""
}
func validExplainCounters(metrics map[string]ExplainMetric, worker bool) bool {
	if metrics == nil || len(metrics) > 26 {
		return false
	}
	for key, metric := range metrics {
		unit, basis := explainCounterUnit(key), "inclusiveTotal"
		if key == "workersPlanned" || key == "workersLaunched" {
			if worker {
				return false
			}
			basis = "total"
		}
		if worker {
			switch key {
			case "actualRows":
				unit, basis = "rows", "perInvocation"
			case "startupTime", "totalTime":
				unit, basis = "ms", "perInvocation"
			case "loops":
				unit, basis = "count", "total"
			}
		}
		if unit == "" || metric.Unit != unit || metric.Basis != basis || !metric.Valid() {
			return false
		}
	}
	return true
}

func validMariaDBExplainCounters(metrics map[string]ExplainMetric) bool {
	if metrics == nil || len(metrics) > 6 {
		return false
	}
	for key, metric := range metrics {
		unit := "count"
		switch key {
		case "mariaDBPagesAccessed", "mariaDBPagesUpdated", "mariaDBPagesRead", "mariaDBPagesPrefetched":
		case "mariaDBPagesReadTime":
			unit = "ms"
		case "mariaDBOldRowsRead":
			unit = "rows"
		default:
			return false
		}
		if metric.Unit != unit || metric.Basis != "total" || !metric.Valid() {
			return false
		}
	}
	return true
}
func (v ExplainJITMetrics) Valid(scope string) bool {
	if v.Scope != scope || v.Metrics == nil || len(v.Metrics) > 7 {
		return false
	}
	for key, metric := range v.Metrics {
		unit := "ms"
		switch key {
		case "functions":
			unit = "count"
		case "generationTime", "deformTime", "inliningTime", "optimizationTime", "emissionTime", "totalTime":
		default:
			return false
		}
		if metric.Unit != unit || metric.Basis != "total" || !metric.Valid() {
			return false
		}
	}
	return true
}
func (v ExplainNodeMetrics) Valid(engine string, node ExplainNode, mode string) bool {
	if v.JIT != nil && (engine != "postgresql" || !v.JIT.Valid("queryAggregate")) {
		return false
	}
	countersValid := validExplainCounters(v.Counters, false)
	if engine == "mariadb" {
		countersValid = validMariaDBExplainCounters(v.Counters)
	}
	if v.Version != 1 || (engine != "postgresql" && engine != "mysql" && engine != "mariadb") || !countersValid || v.Workers == nil || len(v.Workers) > 256 {
		return false
	}
	if v.ExecutionScope != "serial" && v.ExecutionScope != "parallel" && v.ExecutionScope != "unknown" && v.ExecutionScope != "logical" {
		return false
	}
	switch v.RowComparison {
	case "comparable", "partialInput", "parallel", "logical", "notExecuted", "notCollected", "notReported", "unknownScope":
	default:
		return false
	}
	if v.ExecutionScope == "logical" && (engine != "mysql" && engine != "mariadb" || v.RowComparison != "logical" || len(v.Counters) != 0 || len(v.Workers) != 0) || v.RowComparison == "logical" && v.ExecutionScope != "logical" || v.RowComparison == "parallel" && v.ExecutionScope != "parallel" || v.RowComparison == "unknownScope" && v.ExecutionScope != "unknown" {
		return false
	}
	if engine == "mysql" && len(v.Counters) != 0 {
		return false
	}
	if (len(v.Workers) > 0 || v.Counters["workersPlanned"].Unit != "" || v.Counters["workersLaunched"].Unit != "") && v.ExecutionScope != "parallel" {
		return false
	}
	if v.RowComparison == "comparable" && (!explainNodeMeasurement(node, "estimatedRows", "rows", "perInvocation") || !explainNodeMeasurement(node, "actualRows", "rows", "perInvocation") || !explainNodeMeasurement(node, "loops", "count", "total")) {
		return false
	}
	if v.RowComparison == "comparable" && (mode != "analyze" || node.Execution != "executed" || v.ExecutionScope != "serial" || node.Metrics["estimatedRows"].Value == nil || node.Metrics["actualRows"].Value == nil || node.Metrics["loops"].Value == nil || explainZero(*node.Metrics["loops"].Value)) {
		return false
	}
	if v.ExclusiveTime.Unit != "ms" || v.ExclusiveTime.Basis != "exclusivePerInvocation" || !v.ExclusiveTime.Valid() {
		return false
	}
	if v.ExclusiveTime.Value != nil && (!explainNodeMeasurement(node, "totalTime", "ms", "perInvocation") || !explainNodeMeasurement(node, "loops", "count", "total")) {
		return false
	}
	if v.ExclusiveTime.Value != nil && (mode != "analyze" || node.Execution != "executed" || v.ExecutionScope != "serial" || len(node.Children) != 0 || !ExplainKnownSerialLeaf(engine, node.Operation) || node.Metrics["loops"].Value == nil || explainZero(*node.Metrics["loops"].Value) || node.Metrics["totalTime"].Value == nil || *node.Metrics["totalTime"].Value != *v.ExclusiveTime.Value) {
		return false
	}
	seen := map[int]bool{}
	for _, worker := range v.Workers {
		if engine != "postgresql" || worker.Number < 0 || worker.Number > 65535 || seen[worker.Number] || !validExplainCounters(worker.Metrics, true) || worker.JIT != nil && !worker.JIT.Valid("worker") {
			return false
		}
		seen[worker.Number] = true
	}
	return true
}
func (v ExplainPlanMetrics) Valid(engine string) bool {
	return v.Version == 1 && (engine == "postgresql" || engine == "mysql" || engine == "mariadb")
}
func explainZero(value string) bool {
	for _, c := range value {
		if c == 'e' || c == 'E' {
			break
		}
		if c != '0' && c != '.' {
			return false
		}
	}
	return true
}

func ExplainKnownSerialLeaf(engine, operation string) bool {
	if engine == "postgresql" {
		switch operation {
		case "Seq Scan", "Index Scan", "Index Only Scan", "Bitmap Index Scan", "Values Scan", "Result":
			return true
		}
		return false
	}
	if engine == "mysql" {
		for _, prefix := range []string{"Table scan on ", "Index scan on ", "Covering index scan on ", "Index lookup on ", "Covering index lookup on ", "Single-row index lookup on "} {
			if strings.HasPrefix(operation, prefix) {
				return true
			}
		}
	}
	return false
}

func explainNodeMeasurement(node ExplainNode, key, unit, basis string) bool {
	metric := node.Metrics[key]
	return metric.Value != nil && metric.Unit == unit && metric.Basis == basis && metric.Valid()
}
