package protocol

import (
	"bytes"
	"dbeer/helper/internal/tableedit"
	"encoding/json"
)

func parseOperations(raw json.RawMessage) ([]OperationRequest, bool) {
	var raws []json.RawMessage
	if json.Unmarshal(raw, &raws) != nil || len(raws) == 0 || len(raws) > 1024 {
		return nil, false
	}
	operations := make([]OperationRequest, 0, len(raws))
	for _, item := range raws {
		fields, ok := changesObject(item, "type|sql|parameters|export|changes|explain|structure", "type")
		if !ok {
			return nil, false
		}
		var operation OperationRequest
		if !stringField(fields, "type", &operation.Type) {
			return nil, false
		}
		if _, present := fields["structure"]; present && operation.Type != "structure.apply" {
			return nil, false
		}
		if _, present := fields["explain"]; present && operation.Type != "explain.run" {
			return nil, false
		}
		if raw, present := fields["parameters"]; present {
			if operation.Type != "execute" {
				return nil, false
			}
			var ok bool
			operation.Parameters, ok = parseQueryParameters(raw)
			if !ok {
				return nil, false
			}
		}
		switch operation.Type {
		case "structure.apply":
			if len(fields) != 2 {
				return nil, false
			}
			if _, ok := changesObject(fields["structure"], "planId|digest|executionId", "planId", "digest", "executionId"); !ok {
				return nil, false
			}
			var request tableedit.Apply
			decoder := json.NewDecoder(bytes.NewReader(fields["structure"]))
			decoder.DisallowUnknownFields()
			if decoder.Decode(&request) != nil || !request.Valid() {
				return nil, false
			}
			operation.Structure = &request
		case "execute":
			if _, exists := fields["changes"]; exists || fields["explain"] != nil || !stringField(fields, "sql", &operation.SQL) {
				return nil, false
			}
			if raw, exists := fields["export"]; exists {
				if _, ok := changesObject(raw, "path|format|nullMarker", "path", "format"); !ok {
					return nil, false
				}
				var request ExportRequest
				decoder := json.NewDecoder(bytes.NewReader(raw))
				decoder.DisallowUnknownFields()
				if decoder.Decode(&request) != nil || !request.Valid() {
					return nil, false
				}
				operation.Export = &request
			}
		case "explain.run":
			if len(fields) != 2 {
				return nil, false
			}
			request, ok := parseExplain(fields["explain"])
			if !ok {
				return nil, false
			}
			operation.Explain = request
		case "changes.apply":
			if fields["explain"] != nil {
				return nil, false
			}
			if _, exists := fields["sql"]; exists {
				return nil, false
			}
			if _, exists := fields["export"]; exists {
				return nil, false
			}
			request, ok := parseChanges(fields["changes"])
			if !ok {
				return nil, false
			}
			operation.Changes = &request
		default:
			return nil, false
		}
		if !operation.Valid() {
			return nil, false
		}
		operations = append(operations, operation)
	}
	return operations, true
}

// Session policy is immutable: changes require closing and reopening the session.
type ExecutionPolicy struct {
	Environment string `json:"environment"`
	ReadOnly    bool   `json:"readOnly"`
}

func (policy ExecutionPolicy) Valid() bool {
	switch policy.Environment {
	case "unspecified", "development", "staging", "production":
		return true
	}
	return false
}

type OperationRequest struct {
	Type       string           `json:"type"`
	Parameters []QueryParameter `json:"parameters,omitempty"`
	SQL        string           `json:"sql,omitempty"`
	Export     *ExportRequest   `json:"export,omitempty"`
	Changes    *ChangesRequest  `json:"changes,omitempty"`
	Explain    *ExplainRequest  `json:"explain,omitempty"`
	Structure  *tableedit.Apply `json:"structure,omitempty"`
}

func (operation OperationRequest) Valid() bool {
	if operation.Type != "execute" && operation.Parameters != nil || !QueryParametersValid(operation.Parameters) {
		return false
	}
	switch operation.Type {
	case "explain.run":
		return operation.Explain != nil && operation.Explain.Valid() && operation.Structure == nil && operation.SQL == "" && operation.Export == nil && operation.Changes == nil
	case "structure.apply":
		return operation.Structure != nil && operation.Structure.Valid() && operation.Explain == nil && operation.SQL == "" && operation.Export == nil && operation.Changes == nil
	case "execute":
		return operation.Explain == nil && operation.Structure == nil && operation.SQL != "" && operation.Changes == nil && (operation.Export == nil || operation.Export.Valid())
	case "changes.apply":
		return operation.Explain == nil && operation.Structure == nil && operation.SQL == "" && operation.Export == nil && operation.Changes != nil && operation.Changes.Valid()
	}
	return false
}

type StatementAssessment struct {
	Start  int    `json:"start"`
	End    int    `json:"end"`
	Kind   string `json:"kind"`
	Reason string `json:"reason"`
}

type AssessedOperation struct {
	Explain    *ExplainPreview       `json:"explain,omitempty"`
	Kind       string                `json:"kind"`
	Statements []StatementAssessment `json:"statements"`
}

type OperationAssessment struct {
	Decision      string              `json:"decision"`
	Policy        ExecutionPolicy     `json:"policy"`
	Operations    []AssessedOperation `json:"operations"`
	Authorization string              `json:"authorization,omitempty"`
}
