package protocol

import (
	"bytes"
	"dbeer/helper/internal/tableedit"
	"encoding/json"
)

const StructureAuthoringCapability = tableedit.AuthoringCapability
const StructureIndexAuthoringCapability = tableedit.IndexAuthoringCapability
const StructureDestructiveCapability = tableedit.DestructiveCapability

func parseStructure(raw json.RawMessage, command string) (tableedit.Request, bool) {
	var r tableedit.Request
	if !JSONUnicodeValid(raw) || !structureNoNull(raw) {
		return r, false
	}
	fields, ok := changesObject(raw, "target|baselineId|draft|apply|validation")
	if !ok {
		return r, false
	}
	switch command {
	case "structure.load":
		if _, ok := changesObject(fields["target"], "schema|table|create|reconcile", "schema", "table", "create"); !ok || len(fields) != 1 {
			return r, false
		}
	case "structure.preview":
		if len(fields) != 2 || !structureDraftShape(fields["draft"]) {
			return r, false
		}
	case "structure.apply", "structure.validate":
		field := "apply"
		if command == "structure.validate" {
			field = "validation"
		}
		if _, ok := changesObject(fields[field], "planId|digest|executionId", "planId", "digest", "executionId"); !ok || len(fields) != 1 {
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

func structureTypeShape(raw json.RawMessage) bool {
	f, ok := changesObject(raw, "kind|length|precision|scale|reference", "kind")
	if !ok {
		return false
	}
	if v, present := f["reference"]; present {
		_, ok = changesObject(v, "schema|name", "schema", "name")
	}
	return ok
}
func structureAuthoredShape(fields map[string]json.RawMessage) bool {
	for _, key := range []string{"default", "type", "generated", "identity"} {
		v, present := fields[key]
		if !present {
			continue
		}
		if key == "type" {
			if !structureTypeShape(v) {
				return false
			}
			continue
		}
		allowed, required := "kind|value", "kind"
		if key == "generated" {
			allowed, required = "storage|expression", "storage"
		}
		if key == "identity" {
			allowed = "kind|start|increment|minimum|maximum|cache|cycle"
		}
		if _, ok := changesObject(v, allowed, required); !ok {
			return false
		}
	}
	return true
}
func structureDraftShape(raw json.RawMessage) bool {
	f, ok := changesObject(raw, "columns|changes|indexes|keys|allowDestructive|renameTable|authoringVersion|dropTable", "columns")
	if !ok {
		return false
	}
	value := 0
	if version, present := f["authoringVersion"]; present {
		if json.Unmarshal(version, &value) != nil || value != 2 && value != 3 && value != 4 {
			return false
		}
	}
	if _, present := f["dropTable"]; present && value != 4 {
		return false
	}
	for _, key := range []string{"columns", "changes", "indexes", "keys"} {
		raw, present := f[key]
		if !present {
			continue
		}
		var items []json.RawMessage
		if len(raw) == 0 || bytes.TrimSpace(raw)[0] != '[' || json.Unmarshal(raw, &items) != nil {
			return false
		}
		for _, item := range items {
			allowed := "name|type|nullable|default|generated|identity"
			required := []string{"name", "type", "nullable", "default"}
			switch key {
			case "changes":
				allowed = "name|renameTo|nullable|default|type|generated|identity|drop|usingExpression|unsigned|charset|collation"
				required = []string{"name"}
			case "indexes":
				allowed = "action|name|columns|unique|definition"
				required = []string{"action", "name"}
			case "keys":
				allowed = "action|name|kind|columns|reference|referenceColumns|onUpdate|onDelete"
				required = []string{"action", "name", "kind"}
			}
			fields, ok := changesObject(item, allowed, required...)
			if !ok {
				return false
			}
			if key == "changes" && value != 4 {
				for _, field := range []string{"drop", "usingExpression", "unsigned", "charset", "collation"} {
					if _, present := fields[field]; present {
						return false
					}
				}
			}
			if key == "columns" || key == "changes" {
				if v, present := fields["collation"]; present {
					if _, ok := changesObject(v, "schema|name", "schema", "name"); !ok {
						return false
					}
				}
				if !structureAuthoredShape(fields) {
					return false
				}
			}
			if key == "indexes" {
				if v, present := fields["definition"]; present && !structureIndexDefinitionShape(v) {
					return false
				}
			}
			if key == "keys" {
				if v, present := fields["reference"]; present {
					if _, ok := changesObject(v, "schema|table|create", "schema", "table", "create"); !ok {
						return false
					}
				}
			}
		}
	}
	return true
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

func structureIndexDefinitionShape(raw json.RawMessage) bool {
	f, ok := changesObject(raw, "method|terms|includes|predicate|nullsDistinct|visible|options", "method", "terms")
	if !ok || !structureIndexOptionsShape(f["options"]) {
		return false
	}
	var terms []json.RawMessage
	if len(f["terms"]) == 0 || bytes.TrimSpace(f["terms"])[0] != '[' || json.Unmarshal(f["terms"], &terms) != nil {
		return false
	}
	for _, term := range terms {
		t, ok := changesObject(term, "column|expression|descending|nullsFirst|prefixLength|collation|opclass|options")
		if !ok || !structureIndexOptionsShape(t["options"]) {
			return false
		}
		for _, key := range []string{"collation", "opclass"} {
			if v, present := t[key]; present {
				if _, ok := changesObject(v, "schema|name", "schema", "name"); !ok {
					return false
				}
			}
		}
	}
	return true
}
func structureIndexOptionsShape(raw json.RawMessage) bool {
	if len(raw) == 0 {
		return true
	}
	var options []json.RawMessage
	if bytes.TrimSpace(raw)[0] != '[' || json.Unmarshal(raw, &options) != nil {
		return false
	}
	for _, option := range options {
		if _, ok := changesObject(option, "name|value", "name", "value"); !ok {
			return false
		}
	}
	return true
}
