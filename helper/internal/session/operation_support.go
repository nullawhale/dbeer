package session

import "dbeer/helper/internal/protocol"

func attachOperationSupport(response *protocol.Response, engine string, policy protocol.ExecutionPolicy) {
	if response.Type == "query.result" {
		attachResultOperationSupport(response.Source, engine, policy)
		for i := range response.ResultSets {
			attachResultOperationSupport(response.ResultSets[i].Source, engine, policy)
		}
	}
	if response.Structure == nil {
		return
	}
	preview := protocol.OperationAvailability{Operation: "structure.preview", State: "requiresMetadata", Reason: "Load the target structure before preparing a preview."}
	apply := protocol.OperationAvailability{Operation: "structure.apply", State: "requiresMetadata", Reason: "Prepare a current preview before applying changes."}
	if response.Structure.Baseline != nil || response.Structure.Plan != nil {
		preview.State, preview.Reason = "available", ""
	}
	if response.Structure.Plan != nil {
		apply.State, apply.Reason = "available", ""
	}
	if response.Structure.Outcome != nil {
		preview.State, preview.Reason = "requiresMetadata", "Reconcile the observed structure before preparing another preview."
		apply.State, apply.Reason = "requiresMetadata", "Reconcile and prepare a new preview before applying further changes."
	}
	if policy.ReadOnly {
		apply.State, apply.Reason = "unavailable", "This connection is readonly."
	}
	response.OperationSupport = &protocol.OperationSupport{Version: 1, Engine: engine, Scope: "structure", Operations: []protocol.OperationAvailability{preview, apply}}
}

func attachResultOperationSupport(source *protocol.ResultSource, engine string, policy protocol.ExecutionPolicy) {
	if source == nil {
		return
	}
	open := protocol.OperationAvailability{Operation: "resultSource.open", State: "unavailable", Reason: "This result has no supported source row."}
	edit := protocol.OperationAvailability{Operation: "resultSource.edit", State: "unavailable", Reason: "This result does not support editing."}
	if source.Schema != "" && source.Table != "" && len(source.Columns) > 0 {
		for _, column := range source.Columns {
			if column.PrimaryKey > 0 {
				open.State, open.Reason = "available", ""
				break
			}
		}
		if open.State == "available" && source.ReadOnlyReason == "" {
			for _, column := range source.Columns {
				if column.Editable {
					edit.State, edit.Reason = "available", ""
					break
				}
			}
		}
	}
	if source.ReadOnlyReason != "" {
		edit.State, edit.Reason = "unavailable", source.ReadOnlyReason
	}
	if policy.ReadOnly {
		edit.State, edit.Reason = "unavailable", "This connection is readonly."
	}
	source.OperationSupport = &protocol.OperationSupport{Version: 1, Engine: engine, Scope: "result", Operations: []protocol.OperationAvailability{open, edit}}
}
