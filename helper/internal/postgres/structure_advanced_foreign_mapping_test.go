package postgres

import (
	"encoding/json"
	"testing"
)

func TestAdvancedSelfForeignCloneMapsExactlyOneEndpoint(t *testing.T) {
	parent := pgPhysicalRelation{OID: 10, Class: map[string]any{"oid": "10", "relnamespace": "1"}}
	child := pgPhysicalRelation{OID: 20, Class: map[string]any{"oid": "20", "relnamespace": "1", "relispartition": true}, Inherits: []json.RawMessage{json.RawMessage(`{"inhparent":"10","inhrelid":"20","inhdetachpending":false}`)}}
	root := map[string]any{"oid": "100", "conname": "parent_fk", "conrelid": "10", "confrelid": "10", "connamespace": "1", "conparentid": "0", "conislocal": true, "coninhcount": float64(0), "connoinherit": false, "conkey": []any{float64(2)}, "confkey": []any{float64(1)}, "confdelsetcols": nil, "conbin": nil, "conindid": "200", "contype": "f", "convalidated": true, "condeferrable": false, "confupdtype": "a"}
	mapping := map[int]int{1: 2, 2: 3}
	for _, incoming := range []bool{false, true} {
		row := pgPhysicalCopy(root)
		row["oid"], row["conname"], row["conparentid"] = "101", "child_fk", "100"
		row["conislocal"], row["coninhcount"] = false, float64(1)
		indexes := map[string]any{}
		if incoming {
			row["confrelid"], row["confkey"], row["conindid"] = "20", []any{float64(2)}, "201"
			indexes["200"] = "201"
		} else {
			row["conrelid"], row["conkey"] = "20", []any{float64(3)}
		}
		if !pgAdvancedForeignConstraintClone(root, row, parent, child, mapping, indexes) {
			t.Fatal("native one-endpoint clone rejected")
		}
		for key, value := range map[string]any{"conparentid": "999", "condeferrable": true, "convalidated": false, "confupdtype": "c", "coninhcount": float64(2), "unmodeled": true, "conkey": []any{float64(99)}, "confkey": []any{float64(99)}} {
			changed := pgPhysicalCopy(row)
			changed[key] = value
			if pgAdvancedForeignConstraintClone(root, changed, parent, child, mapping, indexes) {
				t.Fatalf("unreviewed native clone field admitted: %s", key)
			}
		}
		changed := pgPhysicalCopy(row)
		changed["conrelid"], changed["confrelid"] = "20", "20"
		if pgAdvancedForeignConstraintClone(root, changed, parent, child, mapping, indexes) {
			t.Fatal("both endpoints remapped implicitly")
		}
		withoutOrigin := child
		withoutOrigin.Inherits = nil
		if pgAdvancedForeignConstraintClone(root, row, parent, withoutOrigin, mapping, indexes) {
			t.Fatal("missing table parent origin admitted")
		}
	}
}
