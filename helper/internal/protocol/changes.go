package protocol

import (
	"bytes"
	"encoding/base64"
	"encoding/json"
	"io"
	"strings"
	"unicode/utf8"
)

type ChangesRequest struct {
	Schema  string           `json:"schema"`
	Table   string           `json:"table"`
	Columns []SnapshotColumn `json:"columns"`
	Changes []RowChange      `json:"changes"`
}

type SnapshotColumn struct {
	Name       string `json:"name"`
	Engine     string `json:"engine"`
	NativeType string `json:"nativeType"`
}

type RowChange struct {
	Kind     string             `json:"kind"`
	Original []CellValue        `json:"original,omitempty"`
	Values   []ColumnAssignment `json:"values,omitempty"`
}

type ColumnAssignment struct {
	Column string    `json:"column"`
	Value  CellValue `json:"value"`
}

type CellValue struct {
	Kind  string  `json:"kind"`
	Value *string `json:"value,omitempty"`
}

func changeNameValid(value string) bool {
	return value != "" && len(value) <= 1024 && utf8.ValidString(value) && !strings.ContainsRune(value, 0)
}

func (value CellValue) Valid(allowDefault bool) bool {
	switch value.Kind {
	case "null":
		return value.Value == nil
	case "default":
		return allowDefault && value.Value == nil
	case "text":
		return value.Value != nil && len(*value.Value) <= 8*1024*1024 && utf8.ValidString(*value.Value)
	case "binary":
		if value.Value == nil || len(*value.Value) > 12*1024*1024 {
			return false
		}
		_, err := base64.StdEncoding.DecodeString(*value.Value)
		return err == nil
	default:
		return false
	}
}

func (request ChangesRequest) Valid() bool {
	if !changeNameValid(request.Schema) || !changeNameValid(request.Table) || len(request.Columns) == 0 || len(request.Columns) > 4096 || len(request.Changes) == 0 || len(request.Changes) > 1000 {
		return false
	}
	columns := map[string]bool{}
	for _, column := range request.Columns {
		if !changeNameValid(column.Name) || columns[column.Name] || (column.Engine != "postgresql" && column.Engine != "mysql") || !changeNameValid(column.NativeType) {
			return false
		}
		columns[column.Name] = true
	}
	for _, change := range request.Changes {
		switch change.Kind {
		case "insert":
			if len(change.Original) != 0 {
				return false
			}
		case "update", "delete":
			if len(change.Original) != len(request.Columns) {
				return false
			}
		default:
			return false
		}
		if change.Kind == "update" && len(change.Values) == 0 || change.Kind == "delete" && len(change.Values) != 0 || len(change.Values) > len(columns) {
			return false
		}
		for _, value := range change.Original {
			if !value.Valid(false) {
				return false
			}
		}
		assigned := map[string]bool{}
		for _, assignment := range change.Values {
			if !columns[assignment.Column] || assigned[assignment.Column] || !assignment.Value.Valid(true) {
				return false
			}
			assigned[assignment.Column] = true
		}
	}
	return true
}

func parseChanges(raw json.RawMessage) (ChangesRequest, bool) {
	var request ChangesRequest
	if !uniqueObjectKeys(raw) || !exactChangesKeys(raw) {
		return request, false
	}
	decoder := json.NewDecoder(bytes.NewReader(raw))
	decoder.DisallowUnknownFields()
	if decoder.Decode(&request) != nil {
		return request, false
	}
	var extra any
	if decoder.Decode(&extra) != io.EOF {
		return request, false
	}
	return request, request.Valid()
}

// encoding/json otherwise accepts case-insensitive aliases of struct fields.
// Check exact wire names recursively before decoding the typed representation.
func changesObject(raw json.RawMessage, allowed string, requiredNames ...string) (map[string]json.RawMessage, bool) {
	var fields map[string]json.RawMessage
	if json.Unmarshal(raw, &fields) != nil || fields == nil {
		return nil, false
	}
	for name := range fields {
		if !strings.Contains("|"+allowed+"|", "|"+name+"|") {
			return nil, false
		}
	}
	for _, name := range requiredNames {
		if !required(fields, name) {
			return nil, false
		}
	}
	return fields, true
}

func exactChangesKeys(raw json.RawMessage) bool {
	root, ok := changesObject(raw, "schema|table|columns|changes", "schema", "table", "columns", "changes")
	if !ok {
		return false
	}
	var columns, changes []json.RawMessage
	if json.Unmarshal(root["columns"], &columns) != nil || json.Unmarshal(root["changes"], &changes) != nil {
		return false
	}
	for _, column := range columns {
		if _, ok := changesObject(column, "name|engine|nativeType", "name", "engine", "nativeType"); !ok {
			return false
		}
	}
	for _, change := range changes {
		fields, ok := changesObject(change, "kind|original|values", "kind")
		if !ok {
			return false
		}
		var original, values []json.RawMessage
		if raw, exists := fields["original"]; exists && json.Unmarshal(raw, &original) != nil {
			return false
		}
		if raw, exists := fields["values"]; exists && json.Unmarshal(raw, &values) != nil {
			return false
		}
		for _, value := range original {
			if _, ok := changesObject(value, "kind|value", "kind"); !ok {
				return false
			}
		}
		for _, assignment := range values {
			fields, ok := changesObject(assignment, "column|value", "column", "value")
			if !ok {
				return false
			}
			if _, ok := changesObject(fields["value"], "kind|value", "kind"); !ok {
				return false
			}
		}
	}
	return true
}
