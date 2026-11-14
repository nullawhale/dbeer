package postgres

import (
	"dbeer/helper/internal/tableedit"
	"fmt"
	"reflect"
)

// A widening rewrite can replace internal TOAST storage. Compare every retained
// property while mapping only its explicitly disclosed server-owned identities.
func pgAdvancedToastPreserved(a, b *tableedit.AdvancedEvidence, prefix string) bool {
	left, right := a.Rows[prefix+"toast"], b.Rows[prefix+"toast"]
	if len(left) != len(right) || len(left) > 1 {
		return false
	}
	if len(left) == 0 {
		return true
	}
	x, y := left[0], right[0]
	old, ok := x["class"].(map[string]any)
	next, valid := y["class"].(map[string]any)
	if !ok || !valid {
		return false
	}
	oldID, newID := pgPhysicalOID(old["oid"]), pgPhysicalOID(next["oid"])
	if oldID == "" || newID == "" {
		return false
	}
	address := map[string]any{oldID: next["oid"]}
	normalizeClass := func(before, after map[string]any) {
		for _, key := range []string{"oid", "relname", "relfilenode"} {
			before[key] = after[key]
		}
	}
	xi, xok := x["indexes"].([]any)
	yi, yok := y["indexes"].([]any)
	if !xok || !yok || len(xi) != 1 || len(yi) != 1 {
		return false
	}
	ix, iok := xi[0].(map[string]any)
	iy, jok := yi[0].(map[string]any)
	if !iok || !jok {
		return false
	}
	ic, iok := ix["class"].(map[string]any)
	jc, jok := iy["class"].(map[string]any)
	if !iok || !jok || pgPhysicalOID(ic["oid"]) == "" || pgPhysicalOID(jc["oid"]) == "" {
		return false
	}
	oldIndex := pgPhysicalOID(ic["oid"])
	address[oldIndex] = jc["oid"]
	// Raw dependency OIDs are canonical strings; catalog tuples retain numbers.
	mappedValue := func(value, target any) any {
		if _, ok := value.(string); ok {
			return fmt.Sprint(target)
		}
		return target
	}
	mapField := func(row map[string]any, key string) {
		if target, ok := address[pgPhysicalOID(row[key])]; ok {
			row[key] = mappedValue(row[key], target)
		}
	}
	normalizeClass(old, next)
	normalizeClass(ic, jc)
	for _, value := range []any{x["attributes"], ix["index"]} {
		switch rows := value.(type) {
		case []any:
			for _, entry := range rows {
				row, ok := entry.(map[string]any)
				if !ok {
					return false
				}
				mapField(row, "attrelid")
				row["attoptions"] = tableedit.SemanticPostgresAttributeOptions(row["attoptions"])
			}
		case map[string]any:
			mapField(rows, "indexrelid")
			mapField(rows, "indrelid")
		default:
			return false
		}
	}
	afterAttributes, validAttributes := y["attributes"].([]any)
	if !validAttributes {
		return false
	}
	for _, entry := range afterAttributes {
		row, ok := entry.(map[string]any)
		if !ok {
			return false
		}
		row["attoptions"] = tableedit.SemanticPostgresAttributeOptions(row["attoptions"])
	}
	// Map only pg_class addresses; equal numeric OIDs in another catalog stay exact.
	for _, row := range a.Rows[prefix+"dependencies"] {
		if fmt.Sprint(row["classid"]) == "1259" {
			mapField(row, "objid")
		}
		if fmt.Sprint(row["refclassid"]) == "1259" {
			mapField(row, "refobjid")
		}
	}
	for _, category := range []string{"comments", "labels"} {
		for _, row := range a.Rows[prefix+category] {
			if fmt.Sprint(row["classoid"]) == "1259" {
				mapField(row, "objoid")
			}
		}
	}
	for _, row := range a.Rows[prefix+"indexAttributes"] {
		if pgPhysicalOID(row["attrelid"]) == oldIndex {
			mapField(row, "attrelid")
			row["attoptions"] = tableedit.SemanticPostgresAttributeOptions(row["attoptions"])
		}
	}
	for _, row := range b.Rows[prefix+"indexAttributes"] {
		if pgPhysicalOID(row["attrelid"]) == pgPhysicalOID(jc["oid"]) {
			row["attoptions"] = tableedit.SemanticPostgresAttributeOptions(row["attoptions"])
		}
	}
	if len(a.Rows[prefix+"class"]) != 1 || len(b.Rows[prefix+"class"]) != 1 || pgPhysicalOID(a.Rows[prefix+"class"][0]["reltoastrelid"]) != oldID || pgPhysicalOID(b.Rows[prefix+"class"][0]["reltoastrelid"]) != newID {
		return false
	}
	a.Rows[prefix+"class"][0]["reltoastrelid"] = next["oid"]
	return reflect.DeepEqual(x, y)
}
