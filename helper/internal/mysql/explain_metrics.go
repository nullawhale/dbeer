package mysql

import (
	"strings"

	"dbeer/helper/internal/adapter"
	"dbeer/helper/internal/protocol"
)

func decorateMySQLMetrics(nodes []protocol.ExplainNode, mode string, logical bool) {
	scope := "serial"
	if logical {
		scope = "logical"
	}
	for _, node := range nodes {
		label := strings.ToLower(node.Operation)
		if strings.Contains(label, "parallel") || strings.Contains(label, "exchange") {
			scope = "unknown"
		}
	}
	partial := map[string]bool{}
	for i := range nodes {
		node := &nodes[i]
		node.AdvancedMetrics = &protocol.ExplainNodeMetrics{Version: 1, ExecutionScope: scope,
			RowComparison: adapter.ExplainRowComparison(*node, mode, scope, partial[node.ID]),
			ExclusiveTime: adapter.ExplainExclusiveTime(*node, mode, scope, "mysql"),
			Counters:      map[string]protocol.ExplainMetric{}, Workers: []protocol.ExplainWorkerMetrics{}}
		label := strings.ToLower(node.Operation)
		if partial[node.ID] || strings.HasPrefix(label, "limit") || strings.Contains(label, "semijoin") || strings.Contains(label, "antijoin") || strings.Contains(label, "semi join") || strings.Contains(label, "anti join") {
			for _, child := range node.Children {
				partial[child] = true
			}
		}
	}
}
