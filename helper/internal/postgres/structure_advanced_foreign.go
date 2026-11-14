package postgres

import (
	"context"
	sc "dbeer/helper/internal/schemacompare"
	"dbeer/helper/internal/tableedit"
	"encoding/json"
	"errors"
	"fmt"
	"reflect"
	"sort"
	"strings"
)

func pgAdvancedForeignCondition(c tableedit.Condition) bool {
	return (c.Operation.Kind == "addKey" || c.Operation.Kind == "dropKey") && c.Operation.Key != nil && c.Operation.Key.Kind == "foreign"
}
func pgAdvancedForeignDraft(b tableedit.Baseline, d tableedit.Draft, refs []tableedit.Baseline) bool {
	advanced := b.Advanced != nil
	for _, r := range refs {
		advanced = advanced || r.Advanced != nil
	}
	if !advanced {
		return false
	}
	for _, k := range d.Keys {
		if k.Kind == "foreign" {
			return true
		}
	}
	return false
}
func (s *Session) pgAdvancedForeignReferences(ctx context.Context, b tableedit.Baseline, d tableedit.Draft, refs []tableedit.Baseline, load func(tableedit.Target) (tableedit.Baseline, error)) ([]tableedit.Baseline, error) {
	for _, edit := range d.Keys {
		if edit.Kind != "foreign" || edit.Action == "add" {
			continue
		}
		for _, old := range b.Keys {
			if old.Name != edit.Name || old.Reference == nil {
				continue
			}
			target := *old.Reference
			if target.Schema == b.Target.Schema && target.Table == b.Target.Table {
				continue
			}
			found := false
			for _, r := range refs {
				found = found || r.Target == target
			}
			if !found {
				if len(refs) >= 16 {
					return nil, tableedit.ErrUnsupported
				}
				r, e := load(target)
				if e != nil {
					return nil, e
				}
				refs = append(refs, r)
			}
		}
	}
	return refs, nil
}
func pgAdvancedRaw(ctx context.Context, q structureReader, t tableedit.Target) (*tableedit.AdvancedEvidence, error) {
	q = pgCatalogReader(q)
	var oid uint32
	var raw string
	if q.QueryRow(ctx, `SELECT c.oid,pg_catalog.row_to_json(c)::pg_catalog.text FROM pg_catalog.pg_class c JOIN pg_catalog.pg_namespace n ON n.oid=c.relnamespace WHERE n.nspname=$1 AND c.relname=$2`, t.Schema, t.Table).Scan(&oid, &raw) != nil {
		return nil, tableedit.ErrUnsupported
	}
	var class map[string]any
	if json.Unmarshal([]byte(raw), &class) != nil {
		return nil, tableedit.ErrUnsupported
	}
	_, proof, e := pgAdvancedCapture(ctx, q, oid, class, true)
	return proof, e
}
func pgAdvancedCombined(ctx context.Context, q structureReader, b tableedit.Baseline, refs []tableedit.Baseline) (*tableedit.AdvancedEvidence, error) {
	q = pgCatalogReader(q)
	out := &tableedit.AdvancedEvidence{Rows: map[string][]map[string]any{}, Facts: map[string]*tableedit.Facts{}, Targets: []tableedit.Target{}}
	all := append([]tableedit.Baseline{b}, refs...)
	targets := map[tableedit.Target]bool{}
	for _, baseline := range all {
		proof := baseline.AdvancedEvidence
		if proof == nil {
			var e error
			proof, e = pgAdvancedRaw(ctx, q, baseline.Target)
			if e != nil {
				return nil, e
			}
		}
		if proof == nil {
			return nil, tableedit.ErrUnsupported
		}
		for key, rows := range proof.Rows {
			if old, exists := out.Rows[key]; exists && !reflect.DeepEqual(old, rows) {
				return nil, tableedit.ErrStale
			}
			out.Rows[key] = rows
		}
		for key, facts := range proof.Facts {
			if old, exists := out.Facts[key]; exists && tableedit.Fingerprint(old) != tableedit.Fingerprint(facts) {
				return nil, tableedit.ErrStale
			}
			out.Facts[key] = facts
		}
		for _, target := range proof.Targets {
			if !targets[target] {
				targets[target] = true
				out.Targets = append(out.Targets, target)
			}
		}
	}
	if len(out.Targets) > 64 {
		return nil, errors.New("Combined source/reference hierarchy proof is bounded to 64 complete tables.")
	}
	sort.Slice(out.Targets, func(i, j int) bool {
		if out.Targets[i].Schema != out.Targets[j].Schema {
			return out.Targets[i].Schema < out.Targets[j].Schema
		}
		return out.Targets[i].Table < out.Targets[j].Table
	})
	functions, proof, e := pgPhysicalReadRI(ctx, q)
	if e != nil {
		return nil, e
	}
	bindings := map[string]any{}
	for name, id := range functions {
		bindings[name] = id
	}
	out.Rows["global/ri"] = []map[string]any{{"functions": bindings, "fingerprint": proof}}
	operators, e := pgAdvancedFKOperators(ctx, q)
	if e != nil {
		return nil, e
	}
	out.Rows["global/fkOperators"] = operators
	raw, _ := json.Marshal(out)
	if len(raw) > 4<<20 {
		return nil, errors.New("Complete combined foreign-key proof exceeds its bounded private envelope.")
	}
	return tableedit.CloneAdvancedEvidence(out), nil
}
func pgAdvancedForeignReview(b tableedit.Baseline, d tableedit.Draft, proof *tableedit.AdvancedEvidence, out *tableedit.Prepared) error {
	for _, target := range proof.Targets {
		out.Consequences = append(out.Consequences, tableedit.Consequence{Kind: "foreignKeyHierarchy", Object: pgPhysicalName(target), Message: "This table is in the complete source/reference hierarchy proof. The reviewed FOREIGN KEY operation creates/removes its server-owned RI constraints/triggers as required by native declarative partition mapping; traditional inheritance keys remain local to the selected table. Exact constraint parent origins, column/type mappings, referenced indexes and internal RI function bindings are checked before COMMIT. Existing unrelated rows, RLS/FORCE/policy/ACL/type/native properties stay unchanged. No implicit CASCADE, disabled checks, role change or policy bypass is generated."})
	}
	return nil
}
func pgAdvancedForeignPreservationError(before, after tableedit.Baseline, c tableedit.Condition, beforeProof, afterProof *tableedit.AdvancedEvidence) error {
	if !pgAdvancedForeignCondition(c) {
		return pgAdvancedPreservationError(before, after, c)
	}
	if beforeProof == nil || afterProof == nil {
		return errors.New("The complete foreign-key source/reference proof is missing.")
	}
	a, b := tableedit.CloneAdvancedEvidence(beforeProof), tableedit.CloneAdvancedEvidence(afterProof)
	if !reflect.DeepEqual(a.Targets, b.Targets) || !reflect.DeepEqual(a.Rows["global/ri"], b.Rows["global/ri"]) || !reflect.DeepEqual(a.Rows["global/fkOperators"], b.Rows["global/fkOperators"]) {
		return errors.New("Foreign-key hierarchy/RI function bindings changed.")
	}
	adding := c.Operation.Kind == "addKey"
	selected := b
	if !adding {
		selected = a
	}
	constraints := map[string]map[string]any{}
	for key, rows := range selected.Rows {
		if strings.HasSuffix(key, "/constraints") {
			for _, row := range rows {
				constraints[pgPhysicalOID(row["oid"])] = row
			}
		}
	}
	rootID := ""
	for id, row := range constraints {
		if row["conname"] == c.Operation.Key.Name && pgPhysicalOID(row["conrelid"]) == before.Identity && row["contype"] == "f" {
			if rootID != "" {
				return errors.New("Foreign-key root identity is ambiguous.")
			}
			rootID = id
		}
	}
	if rootID == "" {
		return errors.New("The reviewed foreign-key root was not found.")
	}
	affected := map[string]bool{rootID: true}
	for changed := true; changed; {
		changed = false
		for id, row := range constraints {
			if !affected[id] && affected[pgPhysicalOID(row["conparentid"])] {
				affected[id] = true
				changed = true
			}
		}
	}
	relation := func(id string) pgPhysicalRelation { return pgAdvancedRelation(id+"/", selected) }
	indexByID := map[string]map[string]any{}
	for key, rows := range selected.Rows {
		if strings.HasSuffix(key, "/indexes") {
			for _, row := range rows {
				indexByID[pgPhysicalOID(row["class"].(map[string]any)["oid"])] = row
			}
		}
	}
	if adding {
		if err := pgAdvancedForeignRoot(before, after, c.Operation.Key, constraints[rootID], selected); err != nil {
			return err
		}
		for id := range affected {
			row := constraints[id]
			if row["convalidated"] != true || row["contype"] != "f" {
				return errors.New("A new foreign-key constraint lacks native validated semantics.")
			}
			if id == rootID {
				continue
			}
			parent := constraints[pgPhysicalOID(row["conparentid"])]
			if parent == nil {
				return errors.New("A cloned foreign key has no captured parent.")
			}
			parentRelation, childRelation := relation(pgPhysicalOID(parent["conrelid"])), relation(pgPhysicalOID(row["conrelid"]))
			incoming := pgPhysicalOID(parent["conrelid"]) == pgPhysicalOID(row["conrelid"])
			if incoming {
				parentRelation, childRelation = relation(pgPhysicalOID(parent["confrelid"])), relation(pgPhysicalOID(row["confrelid"]))
			}
			mapping, ok := pgPhysicalAttributeMap(parentRelation, childRelation)
			if !ok || !pgPhysicalChildRelation(parentRelation, childRelation) {
				return errors.New("A foreign-key descendant column mapping is incomplete.")
			}
			indexMap := map[string]any{}
			if pgPhysicalOID(parent["conindid"]) != pgPhysicalOID(row["conindid"]) {
				pidx, cidx := indexByID[pgPhysicalOID(parent["conindid"])], indexByID[pgPhysicalOID(row["conindid"])]
				if pidx == nil || cidx == nil {
					return errors.New("A referenced descendant index identity is missing.")
				}
				pr, cr := relation(pgPhysicalOID(parent["confrelid"])), relation(pgPhysicalOID(row["confrelid"]))
				if e := pgAdvancedCloneIndexError(pidx, cidx, pr.Columns, cr.Columns, pr.Class, cr.Class); e != nil {
					return e
				}
				indexMap[pgPhysicalOID(parent["conindid"])] = row["conindid"]
			}
			if !pgAdvancedForeignConstraintClone(parent, row, parentRelation, childRelation, mapping, indexMap) {
				return errors.New("A cloned foreign key differs from its exact parent/attribute/reference semantics.")
			}
		}
	}
	triggerIDs := map[string]bool{}
	triggers := map[string]map[string]any{}
	for key, rows := range selected.Rows {
		if strings.HasSuffix(key, "/triggers") {
			for _, row := range rows {
				if affected[pgPhysicalOID(row["tgconstraint"])] {
					id := pgPhysicalOID(row["oid"])
					triggerIDs[id] = true
					triggers[id] = row
				}
			}
		}
	}
	if adding {
		bindings := map[string]string{}
		for name, id := range selected.Rows["global/ri"][0]["functions"].(map[string]any) {
			bindings[name] = fmt.Sprint(id)
		}
		seen := map[string]bool{}
		for _, row := range triggers {
			constraint := constraints[pgPhysicalOID(row["tgconstraint"])]
			rel := relation(pgPhysicalOID(row["tgrelid"]))
			parentID := pgPhysicalOID(row["tgparentid"])
			if parentID == "" {
				key, ok := pgAdvancedRITrigger(row, constraint, rel, bindings)
				if !ok || seen[key] {
					return errors.New("A root/native foreign-key trigger differs from its exact RI binding or is duplicated.")
				}
				seen[key] = true
				continue
			}
			parent := triggers[parentID]
			if parent == nil {
				return errors.New("A cloned RI trigger has no captured parent origin.")
			}
			parentRelation := relation(pgPhysicalOID(parent["tgrelid"]))
			mapping, ok := pgPhysicalAttributeMap(parentRelation, rel)
			if !ok {
				return errors.New("A cloned RI trigger column mapping is incomplete.")
			}
			indexMap := map[string]any{pgPhysicalOID(parent["tgconstrindid"]): row["tgconstrindid"]}
			constraintMap := map[string]any{pgPhysicalOID(parent["tgconstraint"]): row["tgconstraint"]}
			if !pgPhysicalTriggerClone(parent, row, parentRelation, rel, mapping, indexMap, constraintMap) {
				return errors.New("A cloned RI trigger differs from its exact parent semantics.")
			}
			key := pgPhysicalOID(row["tgconstraint"]) + ":" + pgPhysicalOID(row["tgfoid"]) + ":" + pgPhysicalOID(row["tgrelid"])
			if seen[key] {
				return errors.New("A cloned RI trigger was duplicated.")
			}
			seen[key] = true
		}
		// Every concrete nonpartitioned endpoint requires both of its native RI triggers.
		for id := range affected {
			constraint := constraints[id]
			for _, relID := range []string{pgPhysicalOID(constraint["conrelid"]), pgPhysicalOID(constraint["confrelid"])} {
				parent := constraints[pgPhysicalOID(constraint["conparentid"])]
				if parent != nil && ((relID == pgPhysicalOID(constraint["conrelid"]) && relID == pgPhysicalOID(parent["conrelid"])) || (relID == pgPhysicalOID(constraint["confrelid"]) && relID == pgPhysicalOID(parent["confrelid"]))) {
					continue
				}
				rel := relation(relID)
				if rel.Class == nil {
					return errors.New("A foreign-key endpoint is outside the complete reference proof.")
				}
				if rel.Class["relkind"] == "p" {
					continue
				}
				for function := range pgAdvancedRequiredRI(constraint, rel) {
					found := false
					for _, row := range triggers {
						if pgPhysicalOID(row["tgconstraint"]) == id && pgPhysicalOID(row["tgrelid"]) == relID && pgPhysicalOID(row["tgfoid"]) == bindings[function] {
							found = true
						}
					}
					if !found {
						return errors.New("A required native foreign-key enforcement trigger is missing.")
					}
				}
			}
		}
	}
	for _, proof := range []*tableedit.AdvancedEvidence{a, b} {
		for key, rows := range proof.Rows {
			out := []map[string]any{}
			for _, row := range rows {
				remove := false
				switch {
				case strings.HasSuffix(key, "/constraints"):
					remove = affected[pgPhysicalOID(row["oid"])]
				case strings.HasSuffix(key, "/triggers"):
					remove = triggerIDs[pgPhysicalOID(row["oid"])]
				case strings.HasSuffix(key, "/dependencies"):
					remove = fmt.Sprint(row["classid"]) == "2606" && affected[pgPhysicalOID(row["objid"])] || fmt.Sprint(row["refclassid"]) == "2606" && affected[pgPhysicalOID(row["refobjid"])] || fmt.Sprint(row["classid"]) == "2620" && triggerIDs[pgPhysicalOID(row["objid"])] || fmt.Sprint(row["refclassid"]) == "2620" && triggerIDs[pgPhysicalOID(row["refobjid"])]
				case strings.HasSuffix(key, "/class"):
					delete(row, "relhastriggers")
				}
				if !remove {
					out = append(out, row)
				}
			}
			proof.Rows[key] = out
		}
	}
	// No captured object may survive an explicitly reviewed removal.
	if !adding {
		for key, rows := range afterProof.Rows {
			for _, row := range rows {
				if strings.HasSuffix(key, "/constraints") && affected[pgPhysicalOID(row["oid"])] || strings.HasSuffix(key, "/triggers") && triggerIDs[pgPhysicalOID(row["oid"])] {
					return errors.New("A reviewed foreign-key descendant survived removal.")
				}
			}
		}
	}
	allowedFacts := map[string]bool{}
	for id := range affected {
		constraint := constraints[id]
		facts := selected.Facts[pgPhysicalOID(constraint["conrelid"])]
		if facts == nil {
			return errors.New("A foreign-key source type/dependency fact is missing.")
		}
		allowedFacts[facts.Table.Ref.Schema+"\x00"+facts.Table.Ref.Name+"\x00"+fmt.Sprint(constraint["conname"])] = true
	}
	for _, proof := range []*tableedit.AdvancedEvidence{a, b} {
		for _, facts := range proof.Facts {
			keys := []sc.Constraint{}
			for _, key := range facts.Table.Constraints.Items {
				if !allowedFacts[key.Ref.Schema+"\x00"+key.Ref.Table+"\x00"+key.Ref.Name] {
					keys = append(keys, key)
				}
			}
			facts.Table.Constraints.Items = keys
			incoming := []tableedit.Incoming{}
			for _, key := range facts.Incoming {
				if !allowedFacts[key.Schema+"\x00"+key.Table+"\x00"+key.Name] {
					incoming = append(incoming, key)
				}
			}
			facts.Incoming = incoming
			facts.Table.Dependencies = sc.DerivedDependencies(facts.Table)
		}
	}
	if !reflect.DeepEqual(a.Facts, b.Facts) {
		return errors.New("An unaffected foreign-key type, attribute or dependency description changed.")
	}
	for key, rows := range a.Rows {
		if !reflect.DeepEqual(rows, b.Rows[key]) {
			return fmt.Errorf("An unaffected foreign-key native %s property changed.", key[strings.LastIndex(key, "/")+1:])
		}
	}
	return nil
}

func pgAdvancedRequiredRI(constraint map[string]any, rel pgPhysicalRelation) map[string]int {
	out := pgPhysicalLegacyForeignKeys(constraint, rel)
	if pgPhysicalOID(constraint["conrelid"]) == pgPhysicalOID(constraint["confrelid"]) && pgPhysicalOID(constraint["conrelid"]) == fmt.Sprint(rel.OID) {
		actions := map[string]string{"a": "noaction", "r": "restrict", "c": "cascade", "n": "setnull", "d": "setdefault"}
		out["RI_FKey_"+actions[fmt.Sprint(constraint["confdeltype"])]+"_del"] = 9
		out["RI_FKey_"+actions[fmt.Sprint(constraint["confupdtype"])]+"_upd"] = 17
	}
	return out
}
func pgAdvancedRITrigger(row, constraint map[string]any, rel pgPhysicalRelation, functions map[string]string) (string, bool) {
	if pgPhysicalOID(constraint["conrelid"]) != pgPhysicalOID(constraint["confrelid"]) {
		return pgPhysicalLegacyForeignTrigger(row, constraint, rel, functions)
	}
	for function, event := range pgAdvancedRequiredRI(constraint, rel) {
		if functions[function] == "" || pgPhysicalOID(row["tgfoid"]) != functions[function] {
			continue
		}
		local := strings.HasPrefix(function, "RI_FKey_check_")
		prefix := "RI_ConstraintTrigger_a_"
		if local {
			prefix = "RI_ConstraintTrigger_c_"
		}
		deferrable, deferred := false, false
		if local || strings.Contains(function, "noaction") {
			deferrable = constraint["condeferrable"] == true
			deferred = constraint["condeferred"] == true
		}
		expected := map[string]any{"oid": row["oid"], "tgrelid": rel.Class["oid"], "tgparentid": "0", "tgname": prefix + pgPhysicalOID(row["oid"]), "tgfoid": functions[function], "tgtype": float64(event), "tgenabled": "O", "tgisinternal": true, "tgconstrrelid": constraint["confrelid"], "tgconstrindid": constraint["conindid"], "tgconstraint": constraint["oid"], "tgdeferrable": deferrable, "tginitdeferred": deferred, "tgnargs": float64(0), "tgattr": []any{}, "tgargs": "\\x", "tgqual": nil, "tgoldtable": nil, "tgnewtable": nil}
		return pgPhysicalOID(constraint["oid"]) + ":" + function, reflect.DeepEqual(expected, row)
	}
	return "", false
}

func pgAdvancedFKOperators(ctx context.Context, q structureReader) ([]map[string]any, error) {
	return pgAdvancedRows(ctx, q, `SELECT pg_catalog.json_build_object('operator',pg_catalog.row_to_json(o),'function',pg_catalog.row_to_json(p),'language',pg_catalog.row_to_json(l))::pg_catalog.text FROM pg_catalog.pg_operator o JOIN pg_catalog.pg_proc p ON p.oid=o.oprcode JOIN pg_catalog.pg_language l ON l.oid=p.prolang WHERE o.oprnamespace='pg_catalog'::pg_catalog.regnamespace AND o.oid<16384 AND o.oprname='=' AND o.oprleft=o.oprright AND o.oprleft IN (16,20,23,25,1700) AND p.oid<16384 AND p.pronamespace='pg_catalog'::pg_catalog.regnamespace AND l.lanname IN ('internal','c') AND NOT p.prosecdef AND p.proconfig IS NULL AND p.prosrc=p.proname AND p.proname IN ('booleq','int4eq','int8eq','texteq','numeric_eq') AND p.prorettype='pg_catalog.bool'::pg_catalog.regtype AND p.pronargs=2 AND p.proargtypes[0]=o.oprleft AND p.proargtypes[1]=o.oprright AND p.provolatile='i' AND p.proisstrict ORDER BY o.oprleft`)
}
func pgAdvancedForeignRoot(before, after tableedit.Baseline, key *tableedit.KeyEdit, root map[string]any, proof *tableedit.AdvancedEvidence) error {
	if key == nil || key.Reference == nil || root["contype"] != "f" || root["convalidated"] != true || root["condeferrable"] != false || root["condeferred"] != false || fmt.Sprint(root["conparentid"]) != "0" || root["conislocal"] != true || root["coninhcount"] != float64(0) || root["confmatchtype"] != "s" {
		return errors.New("The new root FOREIGN KEY has unreviewed native constraint semantics.")
	}
	actions := map[string]string{"NO ACTION": "a", "RESTRICT": "r", "CASCADE": "c", "SET NULL": "n"}
	if root["confupdtype"] != actions[key.OnUpdate] || root["confdeltype"] != actions[key.OnDelete] {
		return errors.New("The native FOREIGN KEY actions differ from the reviewed intent.")
	}
	if value, present := root["conenforced"]; present && value != true {
		return errors.New("The new foreign key is not enforced.")
	}
	if value, present := root["conperiod"]; present && value != false {
		return errors.New("Temporal FOREIGN KEY semantics were not reviewed.")
	}
	if values := pgAdvancedAttnums(root["confdelsetcols"]); len(values) > 0 {
		return errors.New("Partial SET NULL/DEFAULT columns were not reviewed.")
	}
	sourceID, referenceID := pgPhysicalOID(root["conrelid"]), pgPhysicalOID(root["confrelid"])
	source, target := proof.Facts[sourceID], proof.Facts[referenceID]
	if sourceID != before.Identity || source == nil || target == nil || target.Table.Ref.Schema != key.Reference.Schema || target.Table.Ref.Name != key.Reference.Table {
		return errors.New("The native FOREIGN KEY endpoints differ from the reviewed targets.")
	}
	sourceNums, referenceNums := pgAdvancedAttnums(root["conkey"]), pgAdvancedAttnums(root["confkey"])
	if len(sourceNums) != len(key.Columns) || len(referenceNums) != len(key.ReferenceColumns) {
		return errors.New("The native FOREIGN KEY column count differs.")
	}
	var backing map[string]any
	for _, row := range proof.Rows[referenceID+"/indexes"] {
		if pgPhysicalOID(row["class"].(map[string]any)["oid"]) == pgPhysicalOID(root["conindid"]) {
			backing = row["index"].(map[string]any)
		}
	}
	if backing == nil || backing["indisunique"] != true || backing["indisvalid"] != true || backing["indimmediate"] != true || backing["indpred"] != nil || backing["indexprs"] != nil {
		return errors.New("The native FOREIGN KEY is not bound to a captured valid immediate unique reference index.")
	}
	keyCount, ok := pgPhysicalNumber(backing["indnkeyatts"])
	keys := pgAdvancedAttnums(backing["indkey"])
	if !ok || keyCount != len(referenceNums) || len(keys) < keyCount || !reflect.DeepEqual(keys[:keyCount], referenceNums) {
		return errors.New("The native FOREIGN KEY reference index columns differ from the reviewed key.")
	}
	operatorIDs := []string{}
	for i, name := range key.Columns {
		var sa, ra map[string]any
		for _, a := range proof.Rows[sourceID+"/attributes"] {
			if a["attname"] == name && fmt.Sprint(a["attnum"]) == sourceNums[i] {
				sa = a
			}
		}
		for _, a := range proof.Rows[referenceID+"/attributes"] {
			if a["attname"] == key.ReferenceColumns[i] && fmt.Sprint(a["attnum"]) == referenceNums[i] {
				ra = a
			}
		}
		sc, ok := tableedit.FindColumn(tableedit.Baseline{Facts: source}, name)
		rc, other := tableedit.FindColumn(tableedit.Baseline{Facts: target}, key.ReferenceColumns[i])
		if !ok || !other || !tableedit.PostgresBuiltinIdentity(sc, sa) || !tableedit.PostgresBuiltinIdentity(rc, ra) {
			return errors.New("Foreign-key scalar/operator identity is not an actual captured PostgreSQL built-in.")
		}
		typ := pgPhysicalOID(sa["atttypid"])
		if typ == "1043" {
			typ = "25"
		}
		opID := ""
		for _, row := range proof.Rows["global/fkOperators"] {
			operator := row["operator"].(map[string]any)
			if pgPhysicalOID(operator["oprleft"]) == typ {
				if opID != "" {
					return errors.New("The active built-in equality binding is ambiguous.")
				}
				opID = pgPhysicalOID(operator["oid"])
			}
		}
		if opID == "" {
			return errors.New("The active built-in equality operator binding is unproven.")
		}
		operatorIDs = append(operatorIDs, opID)
	}
	for _, property := range []string{"conpfeqop", "conppeqop", "conffeqop"} {
		if !reflect.DeepEqual(pgAdvancedAttnums(root[property]), operatorIDs) {
			return errors.New("The native FOREIGN KEY equality operators differ from the captured built-in bindings.")
		}
	}
	return nil
}

// A self-referencing partition parent has two distinct native clone directions.
// Each clone maps one endpoint; the other stays bound to the captured parent.
func pgAdvancedForeignConstraintClone(parentRow, childRow map[string]any, parent, child pgPhysicalRelation, mapping map[int]int, indexes map[string]any) bool {
	if pgPhysicalOID(parentRow["conrelid"]) != pgPhysicalOID(parentRow["confrelid"]) {
		return pgPhysicalConstraintClone(parentRow, childRow, parent, child, mapping, indexes, false)
	}
	pID, cID := fmt.Sprint(parent.OID), fmt.Sprint(child.OID)
	if pgPhysicalOID(parentRow["conrelid"]) != pID || !pgPhysicalChildRelation(parent, child) || pgPhysicalOID(childRow["oid"]) == "" || pgPhysicalOID(childRow["conparentid"]) != pgPhysicalOID(parentRow["oid"]) {
		return false
	}
	name, ok := childRow["conname"].(string)
	if !ok || !tableedit.Identifier(name) {
		return false
	}
	expected := pgPhysicalCopy(parentRow)
	for _, key := range []string{"oid", "conname"} {
		expected[key] = childRow[key]
	}
	expected["conparentid"] = parentRow["oid"]
	expected["conislocal"], expected["coninhcount"], expected["connoinherit"] = false, float64(1), false
	switch {
	case pgPhysicalOID(childRow["conrelid"]) == cID && pgPhysicalOID(childRow["confrelid"]) == pID:
		expected["conrelid"], expected["connamespace"] = child.Class["oid"], child.Class["relnamespace"]
		for _, key := range []string{"conkey", "confdelsetcols"} {
			if value, present := parentRow[key]; present {
				mapped, ok := pgPhysicalMapAttnums(value, mapping)
				if !ok {
					return false
				}
				expected[key] = mapped
			}
		}
		mapped, ok := pgPhysicalMapNode(parentRow["conbin"], mapping)
		if !ok {
			return false
		}
		expected["conbin"] = mapped
	case pgPhysicalOID(childRow["confrelid"]) == cID && pgPhysicalOID(childRow["conrelid"]) == pID:
		expected["confrelid"] = child.Class["oid"]
		mapped, ok := pgPhysicalMapAttnums(parentRow["confkey"], mapping)
		if !ok {
			return false
		}
		expected["confkey"] = mapped
		index, ok := indexes[pgPhysicalOID(parentRow["conindid"])]
		if !ok {
			return false
		}
		expected["conindid"] = index
	default:
		return false
	}
	if index, ok := indexes[pgPhysicalOID(parentRow["conindid"])]; ok {
		expected["conindid"] = index
	}
	return reflect.DeepEqual(expected, childRow)
}
