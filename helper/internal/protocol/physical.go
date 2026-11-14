package protocol

import (
	"bytes"
	"dbeer/helper/internal/tableedit"
	"encoding/json"
)

const StructurePhysicalCapability = tableedit.PhysicalCapability

func parsePhysicalStructure(raw json.RawMessage, c string) (tableedit.Request, bool) {
	var r tableedit.Request
	if !JSONUnicodeValid(raw) || !structureNoNull(raw) {
		return r, false
	}
	o, ok := changesObject(raw, "physical", "physical")
	if !ok {
		return r, false
	}
	f, ok := changesObject(o["physical"], "target|draft|apply")
	if !ok {
		return r, false
	}
	switch c {
	case "structure.physical.inspect":
		if len(f) != 1 || !migrationTargetShape(f["target"]) {
			return r, false
		}
	case "structure.physical.preview":
		if len(f) != 1 {
			return r, false
		}
		d, ok := changesObject(f["draft"], "version|target|intent", "version", "target", "intent")
		if !ok || !migrationTargetShape(d["target"]) {
			return r, false
		}
		if !physicalIntentShape(d["intent"]) {
			return r, false
		}
	case "structure.physical.apply":
		if len(f) != 1 {
			return r, false
		}
		if _, ok := changesObject(f["apply"], "planId|digest|executionId", "planId", "digest", "executionId"); !ok {
			return r, false
		}
	case "structure.physical.status", "structure.physical.reconcile", "structure.physical.close":
		if len(f) != 0 {
			return r, false
		}
	default:
		return r, false
	}
	dec := json.NewDecoder(bytes.NewReader(raw))
	dec.DisallowUnknownFields()
	if dec.Decode(&r) != nil || !r.Valid(c) {
		return r, false
	}
	return r, true
}
func physicalIntentShape(raw json.RawMessage) bool {
	var kind struct {
		Kind string `json:"kind"`
	}
	if json.Unmarshal(raw, &kind) != nil {
		return false
	}
	allowed, required := "kind", []string{"kind"}
	switch kind.Kind {
	case "partitionTable":
		allowed += "|method|columns|definitions|count|algorithm|lock"
		required = append(required, "method", "columns", "algorithm", "lock")
	case "removePartitioning":
		allowed += "|algorithm|lock"
		required = append(required, "algorithm", "lock")
	case "exchangePartition":
		allowed += "|child|partitions|algorithm|lock"
		required = append(required, "child", "partitions", "algorithm", "lock")
	case "concurrentIndex":
		allowed += "|index"
		required = append(required, "index")
	case "onlineIndex":
		allowed += "|index|algorithm|lock"
		required = append(required, "index", "algorithm", "lock")
	case "storageEngine":
		allowed += "|engine|algorithm|lock"
		required = append(required, "engine", "algorithm", "lock")
	case "reorderColumns":
		allowed += "|columnOrder|algorithm|lock"
		required = append(required, "columnOrder", "algorithm", "lock")
	case "createPartition", "attachPartition":
		allowed += "|child|bound"
		required = append(required, "child", "bound")
	case "detachPartition":
		allowed += "|child|concurrent"
		required = append(required, "child")
	case "finalizePartition":
		allowed += "|child"
		required = append(required, "child")
	case "dropPartition", "truncatePartition":
		allowed += "|child|partitions|algorithm|lock"
	case "addPartition":
		allowed += "|definitions|algorithm|lock"
		required = append(required, "definitions", "algorithm", "lock")
	case "reorganizePartition":
		allowed += "|partitions|definitions|algorithm|lock"
		required = append(required, "partitions", "definitions", "algorithm", "lock")
	case "addHashPartitions", "coalescePartitions":
		allowed += "|count|algorithm|lock"
		required = append(required, "count", "algorithm", "lock")
	default:
		return false
	}
	f, ok := changesObject(raw, allowed, required...)
	if !ok {
		return false
	}
	for _, key := range []string{"partitions", "definitions", "columnOrder", "columns"} {
		if raw, present := f[key]; present {
			var items []json.RawMessage
			if !migrationArray(raw, &items) || len(items) == 0 {
				return false
			}
		}
	}
	if v, p := f["child"]; p && !migrationTargetShape(v) {
		return false
	}
	if v, p := f["bound"]; p && !physicalBoundShape(v) {
		return false
	}
	if v, p := f["definitions"]; p {
		var a []json.RawMessage
		if !migrationArray(v, &a) || len(a) == 0 {
			return false
		}
		for _, item := range a {
			d, ok := changesObject(item, "name|bound", "name", "bound")
			if !ok || !physicalBoundShape(d["bound"]) {
				return false
			}
		}
	}
	if v, p := f["index"]; p {
		wrapped := append([]byte(`{"columns":[],"authoringVersion":3,"indexes":[`), v...)
		wrapped = append(wrapped, []byte(`]}`)...)
		if !structureDraftShape(wrapped) {
			return false
		}
	}
	return true
}
func physicalBoundShape(raw json.RawMessage) bool {
	var kind struct {
		Kind string `json:"kind"`
	}
	if json.Unmarshal(raw, &kind) != nil {
		return false
	}
	allowed, required := "kind", []string{"kind"}
	switch kind.Kind {
	case "default":
	case "range":
		allowed += "|from|to"
		required = append(required, "to")
	case "list":
		allowed += "|values"
		required = append(required, "values")
	case "hash":
		allowed += "|modulus|remainder"
		required = append(required, "modulus", "remainder")
	default:
		return false
	}
	f, ok := changesObject(raw, allowed, required...)
	if !ok {
		return false
	}
	value := func(v json.RawMessage) bool { _, ok := changesObject(v, "kind|value", "kind"); return ok }
	for _, k := range []string{"from", "to", "values"} {
		v, p := f[k]
		if !p {
			continue
		}
		var a []json.RawMessage
		if !migrationArray(v, &a) {
			return false
		}
		for _, r := range a {
			if k == "values" {
				var row []json.RawMessage
				if !migrationArray(r, &row) {
					return false
				}
				for _, x := range row {
					if !value(x) {
						return false
					}
				}
			} else if !value(r) {
				return false
			}
		}
	}
	return true
}
