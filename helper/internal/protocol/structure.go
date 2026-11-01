package protocol

import (
	"bytes"
	"dbeer/helper/internal/tableedit"
	"encoding/json"
)

func parseStructure(raw json.RawMessage, command string) (tableedit.Request, bool) {
	var r tableedit.Request
	if !structureNoNull(raw) {
		return r, false
	}
	fields, ok := changesObject(raw, "target|baselineId|draft|apply")
	if !ok {
		return r, false
	}
	switch command {
	case "structure.load":
		f, ok := changesObject(fields["target"], "schema|table|create|reconcile", "schema", "table", "create")
		if !ok || len(fields) != 1 {
			return r, false
		}
		if raw, present := f["reconcile"]; present {
			var v bool
			if json.Unmarshal(raw, &v) != nil || bytes.Equal(bytes.TrimSpace(raw), []byte("null")) {
				return r, false
			}
		}
		var v bool
		if json.Unmarshal(f["create"], &v) != nil || bytes.Equal(f["create"], []byte("null")) {
			return r, false
		}
	case "structure.preview":
		if len(fields) != 2 {
			return r, false
		}
		f, ok := changesObject(fields["draft"], "columns|changes|indexes|keys|allowDestructive", "columns")
		if !ok {
			return r, false
		}
		if raw, present := f["allowDestructive"]; present {
			var v bool
			if json.Unmarshal(raw, &v) != nil || bytes.Equal(bytes.TrimSpace(raw), []byte("null")) {
				return r, false
			}
		}
		if raw, present := f["changes"]; present {
			var items []json.RawMessage
			if len(raw) == 0 || bytes.TrimSpace(raw)[0] != '[' || json.Unmarshal(raw, &items) != nil {
				return r, false
			}
			for _, raw := range items {
				fields, ok := changesObject(raw, "name|nullable|default|type", "name")
				if !ok {
					return r, false
				}
				if v, exists := fields["nullable"]; exists {
					var b bool
					if json.Unmarshal(v, &b) != nil || bytes.Equal(bytes.TrimSpace(v), []byte("null")) {
						return r, false
					}
				}
				for _, key := range []string{"default", "type"} {
					if v, exists := fields[key]; exists {
						allowed := "kind|value"
						if key == "type" {
							allowed = "kind|length|precision|scale"
						}
						if _, ok := changesObject(v, allowed, "kind"); !ok {
							return r, false
						}
					}
				}
			}
		}
		for _, key := range []string{"indexes", "keys"} {
			if raw, present := f[key]; present {
				var items []json.RawMessage
				if len(raw) == 0 || bytes.TrimSpace(raw)[0] != '[' || json.Unmarshal(raw, &items) != nil {
					return r, false
				}
				for _, raw := range items {
					allowed := "action|name|columns|unique"
					required := []string{"action", "name"}
					if key == "keys" {
						allowed = "action|name|kind|columns|reference|referenceColumns|onUpdate|onDelete"
						required = append(required, "kind")
					}
					fields, ok := changesObject(raw, allowed, required...)
					if !ok {
						return r, false
					}
					if v, present := fields["reference"]; present {
						if _, ok := changesObject(v, "schema|table|create", "schema", "table", "create"); !ok {
							return r, false
						}
					}
				}
			}
		}
		var columns []json.RawMessage
		if len(f["columns"]) == 0 || bytes.TrimSpace(f["columns"])[0] != '[' || json.Unmarshal(f["columns"], &columns) != nil {
			return r, false
		}
		for _, c := range columns {
			f, ok := changesObject(c, "name|type|nullable|default", "name", "type", "nullable", "default")
			if !ok {
				return r, false
			}
			var nullable bool
			if json.Unmarshal(f["nullable"], &nullable) != nil || bytes.Equal(f["nullable"], []byte("null")) {
				return r, false
			}
			if _, ok = changesObject(f["type"], "kind|length|precision|scale", "kind"); !ok {
				return r, false
			}
			if _, ok = changesObject(f["default"], "kind|value", "kind"); !ok {
				return r, false
			}
		}
	case "structure.apply":
		if _, ok := changesObject(fields["apply"], "planId|digest|executionId", "planId", "digest", "executionId"); !ok || len(fields) != 1 {
			return r, false
		}
	case "structure.status", "structure.close":
		if len(fields) != 0 {
			return r, false
		}
	default:
		return r, false
	}
	d := json.NewDecoder(bytes.NewReader(raw))
	d.DisallowUnknownFields()
	if d.Decode(&r) != nil || !r.Valid(command) {
		return r, false
	}
	return r, true
}

func structureNoNull(raw json.RawMessage) bool {
	var value any
	if json.Unmarshal(raw, &value) != nil {
		return false
	}
	var valid func(any) bool
	valid = func(v any) bool {
		switch x := v.(type) {
		case nil:
			return false
		case map[string]any:
			for _, v := range x {
				if !valid(v) {
					return false
				}
			}
		case []any:
			for _, v := range x {
				if !valid(v) {
					return false
				}
			}
		}
		return true
	}
	return valid(value)
}
