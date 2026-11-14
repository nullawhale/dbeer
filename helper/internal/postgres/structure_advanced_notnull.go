package postgres

import (
	"dbeer/helper/internal/tableedit"
	"errors"
	"fmt"
	"reflect"
	"strings"
)

// PostgreSQL18 owns one automatic column edge for each native NOT NULL
// constraint. Only an exactly proved new/removed constraint and that edge move.
func pgAdvancedNotNullDelta(a, b, fullA, fullB *tableedit.AdvancedEvidence, prefix string, names []string, adding, removing bool) error {
	selected := func(e *tableedit.AdvancedEvidence) map[string]map[string]any {
		out := map[string]map[string]any{}
		for _, row := range e.Rows[prefix+"constraints"] {
			if row["contype"] == "n" && pgAdvancedConstraintColumns(row, e.Rows[prefix+"attributes"], names) {
				out[pgPhysicalOID(row["oid"])] = row
			}
		}
		return out
	}
	left, right := selected(a), selected(b)
	remove := func(e, full *tableedit.AdvancedEvidence, row map[string]any) error {
		if !pgAdvancedNativeNotNull(row, prefix, full) {
			return errors.New("A changed native NOT NULL constraint has unreviewed properties or inheritance provenance.")
		}
		id := pgPhysicalOID(row["oid"])
		number := row["conkey"].([]any)[0]
		expected := map[string]any{"classid": "2606", "objid": id, "objsubid": float64(0), "refclassid": "1259", "refobjid": strings.TrimSuffix(prefix, "/"), "refobjsubid": number, "deptype": "a"}
		count := 0
		for _, edge := range e.Rows[prefix+"dependencies"] {
			if fmt.Sprint(edge["classid"]) == "2606" && pgPhysicalOID(edge["objid"]) == id || fmt.Sprint(edge["refclassid"]) == "2606" && pgPhysicalOID(edge["refobjid"]) == id {
				if !reflect.DeepEqual(edge, expected) {
					return errors.New("A changed NOT NULL constraint has an unreviewed dependency edge.")
				}
				count++
			}
		}
		if count != 1 {
			return errors.New("The exact owned NOT NULL column dependency is absent or duplicated.")
		}
		for _, category := range []string{"constraints", "dependencies"} {
			rows := []map[string]any{}
			for _, value := range e.Rows[prefix+category] {
				if category == "constraints" && pgPhysicalOID(value["oid"]) == id || category == "dependencies" && reflect.DeepEqual(value, expected) {
					continue
				}
				rows = append(rows, value)
			}
			e.Rows[prefix+category] = rows
		}
		return nil
	}
	for id, row := range left {
		if next, ok := right[id]; ok {
			if !reflect.DeepEqual(row, next) {
				return errors.New("An existing NOT NULL constraint changed beyond its reviewed nullability effect.")
			}
			continue
		}
		if !removing {
			return errors.New("An existing NOT NULL constraint was unexpectedly removed.")
		}
		for _, next := range right {
			if reflect.DeepEqual(row["conkey"], next["conkey"]) {
				return errors.New("A NOT NULL constraint identity was unexpectedly replaced.")
			}
		}
		if err := remove(a, fullA, row); err != nil {
			return err
		}
	}
	for id, row := range right {
		if left[id] != nil {
			continue
		}
		if !adding {
			return errors.New("An unexpected NOT NULL constraint was added.")
		}
		for _, old := range left {
			if reflect.DeepEqual(row["conkey"], old["conkey"]) {
				return errors.New("A NOT NULL constraint identity was unexpectedly replaced.")
			}
		}
		if err := remove(b, fullB, row); err != nil {
			return err
		}
	}
	return nil
}
func pgAdvancedNativeNotNull(row map[string]any, prefix string, family *tableedit.AdvancedEvidence) bool {
	keys := strings.Fields("oid conname connamespace contype condeferrable condeferred conenforced convalidated conrelid contypid conindid conparentid confrelid confupdtype confdeltype confmatchtype conislocal coninhcount connoinherit conperiod conkey confkey conpfeqop conppeqop conffeqop confdelsetcols conexclop conbin")
	if family == nil || len(row) != len(keys) || len(family.Rows[prefix+"class"]) != 1 {
		return false
	}
	for _, key := range keys {
		if _, ok := row[key]; !ok {
			return false
		}
	}
	id := strings.TrimSuffix(prefix, "/")
	class := family.Rows[prefix+"class"][0]
	name, ok := row["conname"].(string)
	if !ok || !tableedit.Identifier(name) || pgPhysicalOID(row["oid"]) == "" || row["contype"] != "n" || pgPhysicalOID(row["conrelid"]) != id || !reflect.DeepEqual(row["connamespace"], class["relnamespace"]) {
		return false
	}
	for _, key := range []string{"contypid", "conindid", "conparentid", "confrelid"} {
		if fmt.Sprint(row[key]) != "0" {
			return false
		}
	}
	for _, key := range []string{"condeferrable", "condeferred", "connoinherit", "conperiod"} {
		if row[key] != false {
			return false
		}
	}
	if row["convalidated"] != true || row["conenforced"] != true {
		return false
	}
	for _, key := range []string{"confkey", "conpfeqop", "conppeqop", "conffeqop", "confdelsetcols", "conexclop", "conbin"} {
		if row[key] != nil {
			return false
		}
	}
	for _, key := range []string{"confupdtype", "confdeltype", "confmatchtype"} {
		if row[key] != " " && row[key] != "\x00" {
			return false
		}
	}
	columns, ok := row["conkey"].([]any)
	if !ok || len(columns) != 1 {
		return false
	}
	var column string
	for _, attribute := range family.Rows[prefix+"attributes"] {
		if attribute["attnum"] == columns[0] && attribute["attisdropped"] == false && attribute["attnotnull"] == true {
			column, _ = attribute["attname"].(string)
		}
	}
	if column == "" {
		return false
	}
	parents := map[string]bool{}
	for _, edge := range family.Rows[prefix+"inherits"] {
		if pgPhysicalOID(edge["inhrelid"]) != id {
			continue
		}
		parent := pgPhysicalOID(edge["inhparent"])
		if len(family.Rows[parent+"/class"]) != 1 {
			return false
		}
		for _, constraint := range family.Rows[parent+"/constraints"] {
			if constraint["contype"] == "n" && constraint["connoinherit"] == false && pgAdvancedConstraintColumns(constraint, family.Rows[parent+"/attributes"], []string{column}) {
				parents[parent] = true
			}
		}
	}
	count, ok := pgPhysicalNumber(row["coninhcount"])
	return ok && count == len(parents) && row["conislocal"] == (len(parents) == 0)
}

// Widening may rebuild a native NOT NULL catalog tuple. Its complete semantics,
// provenance and owned edge must remain exact; only the proved OID can change.
func pgAdvancedNotNullTypeDelta(a, b, fullA, fullB *tableedit.AdvancedEvidence, prefix, name string) error {
	selected := func(e *tableedit.AdvancedEvidence) map[string]map[string]any {
		out := map[string]map[string]any{}
		for _, row := range e.Rows[prefix+"constraints"] {
			if row["contype"] == "n" && pgAdvancedConstraintColumns(row, e.Rows[prefix+"attributes"], []string{name}) {
				n, ok := row["conname"].(string)
				if !ok || out[n] != nil {
					return nil
				}
				out[n] = row
			}
		}
		return out
	}
	left, right := selected(a), selected(b)
	if left == nil || right == nil || len(left) != len(right) {
		return errors.New("Widening did not retain the complete NOT NULL constraint set.")
	}
	for name, old := range left {
		next := right[name]
		if next == nil {
			return errors.New("Widening changed a NOT NULL constraint name.")
		}
		expected := pgPhysicalCopy(old)
		expected["oid"] = next["oid"]
		if !reflect.DeepEqual(expected, next) {
			for key, value := range expected {
				if !reflect.DeepEqual(value, next[key]) {
					return fmt.Errorf("Widening changed native NOT NULL property %s.", key)
				}
			}
			return errors.New("Widening changed an unknown NOT NULL property.")
		}
		oldID, newID := pgPhysicalOID(old["oid"]), pgPhysicalOID(next["oid"])
		if oldID == newID {
			continue
		}
		if !pgAdvancedNativeNotNull(old, prefix, fullA) || !pgAdvancedNativeNotNull(next, prefix, fullB) {
			return errors.New("Widening changed native NOT NULL provenance.")
		}
		for _, e := range []*tableedit.AdvancedEvidence{a, b} {
			id := oldID
			if e == b {
				id = newID
			}
			count := 0
			expectedEdge := map[string]any{"classid": "2606", "objid": id, "objsubid": float64(0), "refclassid": "1259", "refobjid": strings.TrimSuffix(prefix, "/"), "refobjsubid": old["conkey"].([]any)[0], "deptype": "a"}
			for _, edge := range e.Rows[prefix+"dependencies"] {
				if edge["classid"] == "2606" && pgPhysicalOID(edge["objid"]) == id || edge["refclassid"] == "2606" && pgPhysicalOID(edge["refobjid"]) == id {
					if !reflect.DeepEqual(edge, expectedEdge) {
						return errors.New("Widening changed an external NOT NULL dependency.")
					}
					count++
				}
			}
			if count != 1 {
				return errors.New("Widening lost or duplicated the owned NOT NULL dependency.")
			}
		}
		old["oid"] = next["oid"]
		for _, edge := range a.Rows[prefix+"dependencies"] {
			if edge["classid"] == "2606" && pgPhysicalOID(edge["objid"]) == oldID {
				edge["objid"] = newID
			}
		}
		for _, category := range []string{"comments", "labels"} {
			for _, row := range a.Rows[prefix+category] {
				if fmt.Sprint(row["classoid"]) == "2606" && pgPhysicalOID(row["objoid"]) == oldID {
					row["objoid"] = next["oid"]
				}
			}
		}
	}
	return nil
}
