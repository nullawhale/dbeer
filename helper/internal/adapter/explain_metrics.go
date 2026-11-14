package adapter

import "dbeer/helper/internal/protocol"

func ExplainNumberIsZero(value string) bool {
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
func ExplainRowComparison(node protocol.ExplainNode, mode, scope string, partial bool) string {
	if scope == "logical" {
		return "logical"
	}
	if mode != "analyze" {
		return "notCollected"
	}
	if node.Execution == "notExecuted" {
		return "notExecuted"
	}
	if partial {
		return "partialInput"
	}
	if scope == "parallel" {
		return "parallel"
	}
	if scope != "serial" {
		return "unknownScope"
	}
	for _, key := range []string{"estimatedRows", "actualRows", "loops"} {
		if node.Metrics[key].Value == nil {
			return "notReported"
		}
	}
	if node.Execution != "executed" || ExplainNumberIsZero(*node.Metrics["loops"].Value) {
		return "notReported"
	}
	return "comparable"
}
func ExplainExclusiveTime(node protocol.ExplainNode, mode, scope, engine string) protocol.ExplainMetric {
	reason := "inclusiveOnly"
	if mode != "analyze" {
		reason = "notCollected"
	} else if node.Execution == "notExecuted" {
		reason = "notExecuted"
	} else if scope == "parallel" {
		reason = "parallel"
	} else if scope != "serial" {
		reason = "unknownScope"
	} else if time := node.Metrics["totalTime"]; time.Value == nil {
		reason = time.UnavailableReason
		if reason == "" {
			reason = "notReported"
		}
	} else if len(node.Children) == 0 && protocol.ExplainKnownSerialLeaf(engine, node.Operation) && node.Execution == "executed" && node.Metrics["loops"].Value != nil && !ExplainNumberIsZero(*node.Metrics["loops"].Value) {
		return ExplainMetric(time.Value, "ms", "exclusivePerInvocation", "")
	}
	return ExplainMetric(nil, "ms", "exclusivePerInvocation", reason)
}
