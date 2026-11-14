package adapter

import (
	"slices"

	"dbeer/helper/internal/protocol"
	"dbeer/helper/internal/tableedit"
)

// SessionOperationSupport uses the actual session and adapter-owned version
// checks. Table permissions and shape require the operation's normal metadata.
func SessionOperationSupport(engine string, physical Session, policy protocol.ExecutionPolicy) protocol.OperationSupport {
	support := protocol.OperationSupport{Version: 1, Engine: engine, Scope: "session"}
	capabilities := Capabilities(engine)
	for _, operation := range []string{"execute", "cancel", "catalog", "gridEditing", protocol.QueryParametersCapability, protocol.TableImportCapability} {
		state, reason := "unavailable", "This adapter does not support this operation."
		if slices.Contains(capabilities, operation) {
			state, reason = "available", ""
			if operation == "gridEditing" || operation == protocol.TableImportCapability {
				state, reason = "requiresMetadata", "Load the target metadata to check its supported operations and permissions."
				if policy.ReadOnly {
					state, reason = "unavailable", "This connection is readonly."
				}
			}
		}
		support.Operations = append(support.Operations, protocol.OperationAvailability{Operation: operation, State: state, Reason: reason})
	}
	_, structure := physical.(tableedit.Adapter)
	for _, operation := range []string{"structure.preview", "structure.apply"} {
		state, reason := "unavailable", "This adapter does not support structure editing."
		if structure {
			state, reason = "requiresMetadata", "Load the table structure and prepare a current preview."
			if operation == "structure.apply" && policy.ReadOnly {
				state, reason = "unavailable", "This connection is readonly."
			}
		}
		support.Operations = append(support.Operations, protocol.OperationAvailability{Operation: operation, State: state, Reason: reason})
	}
	_, hasPhysical := physical.(tableedit.PhysicalAdapter)
	for _, operation := range []string{"structure.physical.preview", "structure.physical.apply"} {
		state, reason := "unavailable", "This physical session does not support guarded physical operations."
		if hasPhysical {
			state, reason = "requiresMetadata", "Prepare a version- and object-specific physical preview."
			if policy.ReadOnly && operation == "structure.physical.apply" {
				state, reason = "unavailable", "This connection is readonly."
			}
		}
		support.Operations = append(support.Operations, protocol.OperationAvailability{Operation: operation, State: state, Reason: reason})
	}
	_, monitor := physical.(SessionMonitor)
	state, reason := "unavailable", "This adapter does not support session monitoring."
	if monitor {
		state, reason = "requiresMetadata", "Monitoring visibility depends on the server permissions and instrumentation."
	}
	support.Operations = append(support.Operations, protocol.OperationAvailability{Operation: "session.monitor", State: state, Reason: reason})
	explain, hasExplain := physical.(ExplainSession)
	for _, mode := range []string{"plan", "analyze"} {
		state, reason := "unavailable", "This adapter does not support Visual Explain."
		if hasExplain {
			availability := explain.ExplainSupport()
			reason = availability.UnavailableReason
			if availability.Valid() && slices.Contains(availability.Modes, mode) {
				state, reason = "available", ""
			} else if reason == "" {
				reason = "This server does not support the selected Explain mode."
				if mode == "analyze" && availability.AnalyzeUnavailableReason != "" {
					reason = availability.AnalyzeUnavailableReason
				}
				if engine == "cassandra" && mode == "plan" {
					reason = "Cassandra exposes request tracing only; estimated relational plans are unavailable."
				}
				if engine == "sqlite" && mode == "analyze" {
					reason = "SQLite EQP exposes query strategy only; this adapter does not expose actual scan measurements."
				}
			}
		}
		support.Operations = append(support.Operations, protocol.OperationAvailability{Operation: "explain." + mode, State: state, Reason: reason})
	}
	return support
}
