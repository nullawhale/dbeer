package postgres

import (
	"context"
	"dbeer/helper/internal/tableedit"
	"fmt"
	"reflect"
	"strconv"
)

// PostgreSQL 14 creates FK triggers from cloned constraints rather than linking
// a pg_trigger parent. Bind the native RI entry points from this owning server.
func pgPhysicalReadRI(ctx context.Context, q structureReader) (map[string]string, string, error) {
	rows, e := pgPhysicalRows(ctx, q, `SELECT pg_catalog.row_to_json(p)::pg_catalog.text FROM pg_catalog.pg_proc p JOIN pg_catalog.pg_namespace n ON n.oid=p.pronamespace JOIN pg_catalog.pg_language l ON l.oid=p.prolang WHERE n.nspname='pg_catalog' AND l.lanname='internal' AND p.oid<16384 AND p.prosrc=p.proname AND p.prorettype='pg_catalog.trigger'::pg_catalog.regtype AND p.pronargs=0 AND p.pronargdefaults=0 AND p.proconfig IS NULL AND NOT p.prosecdef AND p.proname IN ('RI_FKey_check_ins','RI_FKey_check_upd','RI_FKey_noaction_del','RI_FKey_noaction_upd','RI_FKey_restrict_del','RI_FKey_restrict_upd','RI_FKey_cascade_del','RI_FKey_cascade_upd','RI_FKey_setnull_del','RI_FKey_setnull_upd','RI_FKey_setdefault_del','RI_FKey_setdefault_upd') ORDER BY p.proname COLLATE pg_catalog."C"`)
	if e != nil || len(rows) != 12 {
		return nil, "", tableedit.ErrUnsupported
	}
	ids := map[string]string{}
	for _, raw := range rows {
		p, ok := pgPhysicalMap(raw)
		name, valid := p["proname"].(string)
		id := pgPhysicalOID(p["oid"])
		if !ok || !valid || id == "" || ids[name] != "" {
			return nil, "", tableedit.ErrUnsupported
		}
		ids[name] = id
	}
	return ids, tableedit.Fingerprint(rows), nil
}
func pgPhysicalLegacyForeignKeys(constraint map[string]any, child pgPhysicalRelation) map[string]int {
	out := map[string]int{}
	id := strconv.FormatUint(uint64(child.OID), 10)
	if constraint["contype"] != "f" {
		return out
	}
	if pgPhysicalOID(constraint["conrelid"]) == id {
		out["RI_FKey_check_ins"] = 5
		out["RI_FKey_check_upd"] = 17
	} else if pgPhysicalOID(constraint["confrelid"]) == id {
		actions := map[string]string{"a": "noaction", "r": "restrict", "c": "cascade", "n": "setnull", "d": "setdefault"}
		d, ok := actions[fmt.Sprint(constraint["confdeltype"])]
		if !ok {
			return nil
		}
		u, ok := actions[fmt.Sprint(constraint["confupdtype"])]
		if !ok {
			return nil
		}
		out["RI_FKey_"+d+"_del"] = 9
		out["RI_FKey_"+u+"_upd"] = 17
	}
	return out
}
func pgPhysicalLegacyForeignTrigger(row, constraint map[string]any, child pgPhysicalRelation, functions map[string]string) (string, bool) {
	if pgPhysicalOID(row["oid"]) == "" || pgPhysicalOID(row["tgrelid"]) != strconv.FormatUint(uint64(child.OID), 10) || pgPhysicalOID(row["tgconstraint"]) != pgPhysicalOID(constraint["oid"]) {
		return "", false
	}
	candidates := pgPhysicalLegacyForeignKeys(constraint, child)
	for function, event := range candidates {
		if functions[function] == "" || pgPhysicalOID(row["tgfoid"]) != functions[function] {
			continue
		}
		local := pgPhysicalOID(constraint["conrelid"]) == strconv.FormatUint(uint64(child.OID), 10)
		target := constraint["conrelid"]
		prefix := "RI_ConstraintTrigger_a_"
		deferrable, deferred := false, false
		if local {
			target = constraint["confrelid"]
			prefix = "RI_ConstraintTrigger_c_"
		}
		if local || function == "RI_FKey_noaction_del" || function == "RI_FKey_noaction_upd" {
			deferrable = constraint["condeferrable"] == true
			deferred = constraint["condeferred"] == true
		}
		expected := map[string]any{"oid": row["oid"], "tgrelid": child.Class["oid"], "tgparentid": "0", "tgname": prefix + pgPhysicalOID(row["oid"]), "tgfoid": functions[function], "tgtype": float64(event), "tgenabled": "O", "tgisinternal": true, "tgconstrrelid": target, "tgconstrindid": constraint["conindid"], "tgconstraint": constraint["oid"], "tgdeferrable": deferrable, "tginitdeferred": deferred, "tgnargs": float64(0), "tgattr": []any{}, "tgargs": "\\x", "tgqual": nil, "tgoldtable": nil, "tgnewtable": nil}
		return pgPhysicalOID(constraint["oid"]) + ":" + function, reflect.DeepEqual(expected, row)
	}
	return "", false
}
func pgPhysicalLegacyUserTrigger(parentRow, childRow map[string]any, parent, child pgPhysicalRelation, mapping map[int]int, indexMap, constraintMap map[string]any) bool {
	expectedParent := pgPhysicalCopy(parentRow)
	expectedParent["tgisinternal"] = true
	if fmt.Sprint(parentRow["tgconstraint"]) == "0" && parentRow["tgname"] != childRow["tgname"] {
		return false
	}
	return pgPhysicalTriggerClone(expectedParent, childRow, parent, child, mapping, indexMap, constraintMap)
}
