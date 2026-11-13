package protocol

import (
	"bytes"
	"dbeer/helper/internal/tableedit"
	"encoding/json"
)

const StructureMigrationsCapability = tableedit.MigrationCapability

func parseMigrationStructure(raw json.RawMessage, command string) (tableedit.Request, bool) {
	var r tableedit.Request
	if !JSONUnicodeValid(raw) || !structureNoNull(raw) {
		return r, false
	}
	outer, ok := changesObject(raw, "migration", "migration")
	if !ok {
		return r, false
	}
	fields, ok := changesObject(outer["migration"], "draft|apply")
	if !ok {
		return r, false
	}
	switch command {
	case "structure.migration.preview":
		if len(fields) != 1 {
			return r, false
		}
		draft, ok := changesObject(fields["draft"], "version|objects|repairs", "version", "objects", "repairs")
		if !ok {
			return r, false
		}
		var objects, repairs []json.RawMessage
		if !migrationArray(draft["objects"], &objects) || !migrationArray(draft["repairs"], &repairs) {
			return r, false
		}
		for _, raw := range objects {
			o, ok := changesObject(raw, "id|target|draft|after", "id", "target", "draft", "after")
			if !ok || !migrationTargetShape(o["target"]) || !structureDraftShape(o["draft"]) {
				return r, false
			}
		}
		for _, raw := range repairs {
			o, ok := changesObject(raw, "id|target|key|action|replacement", "id", "target", "key", "action")
			if !ok || !migrationTargetShape(o["target"]) {
				return r, false
			}
			if v, present := o["replacement"]; present {
				wrapped := append([]byte(`{"columns":[],"keys":[`), v...)
				wrapped = append(wrapped, []byte(`]}`)...)
				if !structureDraftShape(wrapped) {
					return r, false
				}
			}
		}
	case "structure.migration.apply", "structure.migration.export":
		if len(fields) != 1 {
			return r, false
		}
		if _, ok := changesObject(fields["apply"], "planId|digest|executionId", "planId", "digest", "executionId"); !ok {
			return r, false
		}
	case "structure.migration.status", "structure.migration.reconcile", "structure.migration.close":
		if len(fields) != 0 {
			return r, false
		}
	default:
		return r, false
	}
	decoder := json.NewDecoder(bytes.NewReader(raw))
	decoder.DisallowUnknownFields()
	if decoder.Decode(&r) != nil || !r.Valid(command) {
		return r, false
	}
	return r, true
}
func migrationTargetShape(raw json.RawMessage) bool {
	_, ok := changesObject(raw, "schema|table|create", "schema", "table", "create")
	return ok
}
func migrationArray(raw json.RawMessage, out *[]json.RawMessage) bool {
	return len(raw) > 0 && bytes.TrimSpace(raw)[0] == '[' && json.Unmarshal(raw, out) == nil
}
