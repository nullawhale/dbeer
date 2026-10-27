package protocol

import (
	"bytes"
	"encoding/json"
)

func parseOperations(raw json.RawMessage) ([]OperationRequest, bool) {
	var raws []json.RawMessage
	if json.Unmarshal(raw, &raws) != nil || len(raws) == 0 || len(raws) > 1024 {
		return nil, false
	}
	operations := make([]OperationRequest, 0, len(raws))
	for _, item := range raws {
		fields, ok := changesObject(item, "type|sql|export|changes", "type")
		if !ok {
			return nil, false
		}
		var operation OperationRequest
		if !stringField(fields, "type", &operation.Type) {
			return nil, false
		}
		switch operation.Type {
		case "execute":
			if _, exists := fields["changes"]; exists || !stringField(fields, "sql", &operation.SQL) {
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
		case "changes.apply":
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
	Type    string          `json:"type"`
	SQL     string          `json:"sql,omitempty"`
	Export  *ExportRequest  `json:"export,omitempty"`
	Changes *ChangesRequest `json:"changes,omitempty"`
}

func (operation OperationRequest) Valid() bool {
	switch operation.Type {
	case "execute":
		return operation.SQL != "" && operation.Changes == nil && (operation.Export == nil || operation.Export.Valid())
	case "changes.apply":
		return operation.SQL == "" && operation.Export == nil && operation.Changes != nil && operation.Changes.Valid()
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
	Kind       string                `json:"kind"`
	Statements []StatementAssessment `json:"statements"`
}

type OperationAssessment struct {
	Decision      string              `json:"decision"`
	Policy        ExecutionPolicy     `json:"policy"`
	Operations    []AssessedOperation `json:"operations"`
	Authorization string              `json:"authorization,omitempty"`
}
