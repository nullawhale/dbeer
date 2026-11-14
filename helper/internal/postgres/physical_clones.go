package postgres

import (
	"dbeer/helper/internal/tableedit"
	"encoding/json"
	"fmt"
	"reflect"
	"regexp"
	"strconv"
	"strings"
)

func pgPhysicalMap(raw json.RawMessage) (map[string]any, bool) {
	var value map[string]any
	e := json.Unmarshal(raw, &value)
	return value, e == nil && value != nil
}
func pgPhysicalCopy(value map[string]any) map[string]any {
	raw, _ := json.Marshal(value)
	out, _ := pgPhysicalMap(raw)
	return out
}
func pgPhysicalNumber(value any) (int, bool) {
	n, e := strconv.Atoi(fmt.Sprint(value))
	return n, e == nil
}
func pgPhysicalOID(value any) string {
	n, e := strconv.ParseUint(fmt.Sprint(value), 10, 32)
	if e != nil || n == 0 {
		return ""
	}
	return strconv.FormatUint(n, 10)
}
func pgPhysicalIDLike(value any, n int) any {
	if _, ok := value.(string); ok {
		return strconv.Itoa(n)
	}
	return float64(n)
}

// Mapping is by byte-exact catalog column name and retained native type facts,
// never by ordinal coincidence. PostgreSQL can attach differently ordered rows.
func pgPhysicalAttributeMap(parent, child pgPhysicalRelation) (map[int]int, bool) {
	columns := map[string]map[string]any{}
	for _, c := range child.Columns {
		if c["attisdropped"] == true {
			continue
		}
		name, ok := c["attname"].(string)
		if !ok || columns[name] != nil {
			return nil, false
		}
		columns[name] = c
	}
	mapping := map[int]int{}
	count := 0
	for _, p := range parent.Columns {
		if p["attisdropped"] == true {
			continue
		}
		name, ok := p["attname"].(string)
		c := columns[name]
		if !ok || c == nil {
			return nil, false
		}
		for _, key := range []string{"atttypid", "atttypmod", "attcollation"} {
			if !reflect.DeepEqual(p[key], c[key]) {
				return nil, false
			}
		}
		a, ok := pgPhysicalNumber(p["attnum"])
		b, valid := pgPhysicalNumber(c["attnum"])
		if !ok || !valid || a <= 0 || b <= 0 {
			return nil, false
		}
		mapping[a] = b
		count++
	}
	return mapping, count == len(columns)
}
func pgPhysicalMapAttnums(value any, mapping map[int]int) (any, bool) {
	if value == nil {
		return nil, true
	}
	if values, ok := value.([]any); ok {
		out := make([]any, len(values))
		for i, v := range values {
			n, ok := pgPhysicalNumber(v)
			if !ok {
				return nil, false
			}
			if n == 0 {
				out[i] = v
				continue
			}
			mapped, ok := mapping[n]
			if !ok {
				return nil, false
			}
			out[i] = pgPhysicalIDLike(v, mapped)
		}
		return out, true
	}
	if text, ok := value.(string); ok {
		out := []string{}
		for _, s := range strings.Fields(text) {
			n, e := strconv.Atoi(s)
			if e != nil {
				return nil, false
			}
			if n != 0 {
				var ok bool
				n, ok = mapping[n]
				if !ok {
					return nil, false
				}
			}
			out = append(out, strconv.Itoa(n))
		}
		return strings.Join(out, " "), true
	}
	return nil, false
}

var physicalNodeLocation = regexp.MustCompile(`:location -?[0-9]+`)

func pgPhysicalNodePositions(v any) any {
	if s, ok := v.(string); ok {
		return physicalNodeLocation.ReplaceAllString(s, ":location -1")
	}
	return v
}

var physicalNodeAttribute = regexp.MustCompile(`:(varattno|varattnosyn|varoattno) (-?[0-9]+)`)

func pgPhysicalMapNode(value any, mapping map[int]int) (any, bool) {
	if value == nil {
		return nil, true
	}
	node, ok := value.(string)
	if !ok {
		return nil, false
	}
	identity := true
	for a, b := range mapping {
		identity = identity && a == b
	}
	valid := true
	out := physicalNodeAttribute.ReplaceAllStringFunc(node, func(s string) string {
		parts := physicalNodeAttribute.FindStringSubmatch(s)
		n, e := strconv.Atoi(parts[2])
		if e != nil {
			valid = false
			return s
		}
		if n <= 0 {
			if n == 0 && parts[1] == "varattno" && !identity {
				valid = false
			}
			return s
		}
		mapped, ok := mapping[n]
		if !ok {
			valid = false
			return s
		}
		return ":" + parts[1] + " " + strconv.Itoa(mapped)
	})
	return pgPhysicalNodePositions(out), valid
}
func pgPhysicalChildRelation(parent, child pgPhysicalRelation) bool {
	if child.Class["relispartition"] != true {
		return false
	}
	for _, raw := range child.Inherits {
		r, ok := pgPhysicalMap(raw)
		if ok && pgPhysicalOID(r["inhparent"]) == strconv.FormatUint(uint64(parent.OID), 10) && pgPhysicalOID(r["inhrelid"]) == strconv.FormatUint(uint64(child.OID), 10) && r["inhdetachpending"] != true {
			return true
		}
	}
	return false
}
func pgPhysicalIndexParts(raw json.RawMessage) (map[string]any, map[string]any, []any, bool) {
	r, ok := pgPhysicalMap(raw)
	if !ok {
		return nil, nil, nil, false
	}
	c, cok := r["class"].(map[string]any)
	i, iok := r["index"].(map[string]any)
	parents, pok := r["parents"].([]any)
	return c, i, parents, cok && iok && pok
}

// New identities and generated names are allowed only after catalog origin,
// exact target and every remaining pg_index/pg_class property have been proved.
func pgPhysicalIndexClone(parentRaw, childRaw json.RawMessage, parent, child pgPhysicalRelation, mapping map[int]int) bool {
	pc, pi, _, ok := pgPhysicalIndexParts(parentRaw)
	if !ok {
		return false
	}
	cc, ci, origins, ok := pgPhysicalIndexParts(childRaw)
	if !ok || len(origins) != 1 || pgPhysicalOID(origins[0]) != pgPhysicalOID(pc["oid"]) || pgPhysicalOID(cc["oid"]) == "" || pgPhysicalOID(ci["indexrelid"]) != pgPhysicalOID(cc["oid"]) || pgPhysicalOID(ci["indrelid"]) != strconv.FormatUint(uint64(child.OID), 10) {
		return false
	}
	if child.Class["relkind"] != "r" || cc["relkind"] != "i" || cc["relispartition"] != true || cc["relhassubclass"] != false || pgPhysicalOID(cc["relfilenode"]) == "" {
		return false
	}
	name, ok := cc["relname"].(string)
	if !ok || !tableedit.Identifier(name) {
		return false
	}
	expectedClass := pgPhysicalCopy(pc)
	for _, k := range []string{"oid", "relname", "relfilenode"} {
		expectedClass[k] = cc[k]
	}
	expectedClass["relnamespace"] = child.Class["relnamespace"]
	expectedClass["relowner"] = child.Class["relowner"]
	expectedClass["relkind"] = "i"
	expectedClass["relispartition"] = true
	expectedClass["relhassubclass"] = false
	expectedIndex := pgPhysicalCopy(pi)
	expectedIndex["indexrelid"] = cc["oid"]
	expectedIndex["indrelid"] = child.Class["oid"]
	for _, k := range []string{"indisvalid", "indisready", "indislive"} {
		expectedIndex[k] = true
	}
	v, ok := pgPhysicalMapAttnums(pi["indkey"], mapping)
	if !ok {
		return false
	}
	expectedIndex["indkey"] = v
	for _, k := range []string{"indexprs", "indpred"} {
		v, ok := pgPhysicalMapNode(pi[k], mapping)
		if !ok {
			return false
		}
		expectedIndex[k] = v
		ci = pgPhysicalCopy(ci)
		ci[k] = pgPhysicalNodePositions(ci[k])
	}
	return reflect.DeepEqual(expectedClass, cc) && reflect.DeepEqual(expectedIndex, ci)
}
func pgPhysicalConstraintClone(parentRow, childRow map[string]any, parent, child pgPhysicalRelation, mapping map[int]int, indexMap map[string]any, inheritedCheck bool) bool {
	if pgPhysicalOID(childRow["oid"]) == "" {
		return false
	}
	name, ok := childRow["conname"].(string)
	if !ok || !tableedit.Identifier(name) {
		return false
	}
	pOID, cOID := strconv.FormatUint(uint64(parent.OID), 10), strconv.FormatUint(uint64(child.OID), 10)
	local := pgPhysicalOID(parentRow["conrelid"]) == pOID
	incoming := !local && pgPhysicalOID(parentRow["confrelid"]) == pOID
	if !local && !incoming {
		return false
	}
	if local && pgPhysicalOID(parentRow["confrelid"]) == pOID {
		return false
	}
	expected := pgPhysicalCopy(parentRow)
	expected["oid"] = childRow["oid"]
	expected["conname"] = childRow["conname"]
	expected["conislocal"] = false
	expected["coninhcount"] = float64(1)
	expected["connoinherit"] = false
	if inheritedCheck {
		if childRow["contype"] == "c" && childRow["conname"] != parentRow["conname"] {
			return false
		}
		if childRow["contype"] != "c" && childRow["contype"] != "n" || fmt.Sprint(childRow["conparentid"]) != "0" {
			return false
		}
		expected["conparentid"] = childRow["conparentid"]
	} else {
		if pgPhysicalOID(childRow["conparentid"]) != pgPhysicalOID(parentRow["oid"]) {
			return false
		}
		expected["conparentid"] = parentRow["oid"]
	}
	if local {
		expected["conrelid"] = child.Class["oid"]
		expected["connamespace"] = child.Class["relnamespace"]
		for _, k := range []string{"conkey", "confdelsetcols"} {
			if value, present := parentRow[k]; present {
				mapped, ok := pgPhysicalMapAttnums(value, mapping)
				if !ok {
					return false
				}
				expected[k] = mapped
			}
		}
		value, ok := pgPhysicalMapNode(parentRow["conbin"], mapping)
		if !ok {
			return false
		}
		expected["conbin"] = value
		childRow = pgPhysicalCopy(childRow)
		childRow["conbin"] = pgPhysicalNodePositions(childRow["conbin"])
	} else {
		expected["confrelid"] = child.Class["oid"]
		value, ok := pgPhysicalMapAttnums(parentRow["confkey"], mapping)
		if !ok {
			return false
		}
		expected["confkey"] = value
	}
	if mapped, ok := indexMap[pgPhysicalOID(parentRow["conindid"])]; ok {
		expected["conindid"] = mapped
	} else if childRow["contype"] == "p" || childRow["contype"] == "u" || incoming {
		return false
	}
	if local && pgPhysicalOID(expected["conrelid"]) != cOID || incoming && pgPhysicalOID(expected["confrelid"]) != cOID {
		return false
	}
	return reflect.DeepEqual(expected, childRow)
}
func pgPhysicalTriggerClone(parentRow, childRow map[string]any, parent, child pgPhysicalRelation, mapping map[int]int, indexMap, constraintMap map[string]any) bool {
	if pgPhysicalOID(childRow["oid"]) == "" || pgPhysicalOID(childRow["tgparentid"]) != pgPhysicalOID(parentRow["oid"]) || pgPhysicalOID(childRow["tgrelid"]) != strconv.FormatUint(uint64(child.OID), 10) {
		return false
	}
	expected := pgPhysicalCopy(parentRow)
	expected["oid"] = childRow["oid"]
	expected["tgparentid"] = parentRow["oid"]
	expected["tgrelid"] = child.Class["oid"]
	if parentRow["tgisinternal"] == true {
		name, ok := childRow["tgname"].(string)
		if !ok || !tableedit.Identifier(name) {
			return false
		}
		expected["tgname"] = name
	}
	for key, ids := range map[string]map[string]any{"tgconstraint": constraintMap, "tgconstrindid": indexMap} {
		if id := pgPhysicalOID(parentRow[key]); id != "" {
			if mapped, ok := ids[id]; ok {
				expected[key] = mapped
			} else if key == "tgconstraint" {
				return false
			}
		}
	}
	value, ok := pgPhysicalMapAttnums(parentRow["tgattr"], mapping)
	if !ok {
		return false
	}
	expected["tgattr"] = value
	value, ok = pgPhysicalMapNode(parentRow["tgqual"], mapping)
	if !ok {
		return false
	}
	expected["tgqual"] = value
	childRow = pgPhysicalCopy(childRow)
	childRow["tgqual"] = pgPhysicalNodePositions(childRow["tgqual"])
	return reflect.DeepEqual(expected, childRow)
}
func pgPhysicalCloneChanges(before, after pgPhysicalEvidence, kind string) bool {
	if len(before.Relations) == 0 || len(after.Relations) == 0 {
		return false
	}
	parent := before.Relations[0]
	if kind != "createPartition" && kind != "attachPartition" {
		return true
	}
	for _, child := range after.Relations[1:] {
		var old *pgPhysicalRelation
		for i := range before.Relations {
			if before.Relations[i].Target == child.Target {
				old = &before.Relations[i]
			}
		}
		if old == nil {
			return false
		}
		wasChild := false
		for _, p := range parent.Children {
			wasChild = wasChild || p.Target != nil && *p.Target == child.Target
		}
		if wasChild {
			continue
		}
		if !pgPhysicalChildRelation(parent, child) {
			if old.OID != child.OID {
				return false
			}
			continue
		}
		mapping, ok := pgPhysicalAttributeMap(parent, child)
		if !ok {
			return false
		}
		parentIndexes := map[string]json.RawMessage{}
		for _, raw := range parent.Indexes {
			c, _, _, ok := pgPhysicalIndexParts(raw)
			if !ok {
				return false
			}
			parentIndexes[pgPhysicalOID(c["oid"])] = raw
		}
		oldIndexes := map[string]json.RawMessage{}
		for _, raw := range old.Indexes {
			c, _, _, ok := pgPhysicalIndexParts(raw)
			if !ok {
				return false
			}
			oldIndexes[pgPhysicalOID(c["oid"])] = raw
		}
		indexMap := map[string]any{}
		for _, raw := range child.Indexes {
			c, _, origins, ok := pgPhysicalIndexParts(raw)
			if !ok {
				return false
			}
			id := pgPhysicalOID(c["oid"])
			previous, existed := oldIndexes[id]
			changed := !existed
			if existed {
				_, _, oldOrigins, ok := pgPhysicalIndexParts(previous)
				if !ok {
					return false
				}
				changed = !reflect.DeepEqual(origins, oldOrigins)
			}
			if len(origins) == 0 {
				if changed {
					return false
				}
				continue
			}
			if len(origins) != 1 {
				return false
			}
			origin := pgPhysicalOID(origins[0])
			source, found := parentIndexes[origin]
			if !found || indexMap[origin] != nil || !pgPhysicalIndexClone(source, raw, parent, child, mapping) {
				return false
			}
			indexMap[origin] = c["oid"]
		}
		if len(indexMap) != len(parentIndexes) {
			return false
		}
		parentConstraints := map[string]map[string]any{}
		for _, raw := range parent.Constraints {
			r, ok := pgPhysicalMap(raw)
			if !ok {
				return false
			}
			parentConstraints[pgPhysicalOID(r["oid"])] = r
		}
		oldConstraints := map[string]bool{}
		for _, raw := range old.Constraints {
			r, ok := pgPhysicalMap(raw)
			if !ok {
				return false
			}
			oldConstraints[pgPhysicalOID(r["oid"])] = true
		}
		constraintMap := map[string]any{}
		for _, raw := range child.Constraints {
			r, ok := pgPhysicalMap(raw)
			if !ok {
				return false
			}
			origin := pgPhysicalOID(r["conparentid"])
			source := parentConstraints[origin]
			inheritedCheck := false
			if source == nil && (r["contype"] == "c" || r["contype"] == "n") {
				for id, p := range parentConstraints {
					if p["contype"] != r["contype"] {
						continue
					}
					if pgPhysicalConstraintClone(p, r, parent, child, mapping, indexMap, true) {
						if source != nil {
							return false
						}
						source = p
						origin = id
						inheritedCheck = true
					}
				}
			}
			if source == nil {
				if oldConstraints[pgPhysicalOID(r["oid"])] {
					continue
				}
				return false
			}
			if !pgPhysicalConstraintClone(source, r, parent, child, mapping, indexMap, inheritedCheck) {
				return false
			}
			if constraintMap[origin] != nil {
				return false
			}
			constraintMap[origin] = r["oid"]
		}
		if len(constraintMap) != len(parentConstraints) {
			return false
		}
		parentTriggers := map[string]map[string]any{}
		for _, raw := range parent.Triggers {
			r, ok := pgPhysicalMap(raw)
			if !ok {
				return false
			}
			parentTriggers[pgPhysicalOID(r["oid"])] = r
		}
		oldTriggers := map[string]bool{}
		for _, raw := range old.Triggers {
			r, ok := pgPhysicalMap(raw)
			if !ok {
				return false
			}
			oldTriggers[pgPhysicalOID(r["oid"])] = true
		}
		legacyForeign := map[string]map[string]any{}
		for _, raw := range child.Constraints {
			c, _ := pgPhysicalMap(raw)
			origin := pgPhysicalOID(c["conparentid"])
			if origin != "" && constraintMap[origin] != nil && c["contype"] == "f" {
				legacyForeign[pgPhysicalOID(c["oid"])] = c
			}
		}
		seenLegacy := map[string]bool{}
		seenTriggers := map[string]bool{}
		for _, raw := range child.Triggers {
			r, ok := pgPhysicalMap(raw)
			if !ok {
				return false
			}
			if oldTriggers[pgPhysicalOID(r["oid"])] {
				continue
			}
			if before.Version >= 140000 && before.Version < 150000 && pgPhysicalOID(r["tgparentid"]) == "" {
				constraint := legacyForeign[pgPhysicalOID(r["tgconstraint"])]
				if constraint == nil {
					return false
				}
				key, ok := pgPhysicalLegacyForeignTrigger(r, constraint, child, before.RIFunctions)
				if !ok || seenLegacy[key] {
					return false
				}
				seenLegacy[key] = true
				continue
			}
			origin := pgPhysicalOID(r["tgparentid"])
			source := parentTriggers[origin]
			if seenTriggers[origin] {
				return false
			}
			seenTriggers[origin] = true
			validClone := false
			if source != nil {
				if before.Version >= 140000 && before.Version < 150000 {
					validClone = pgPhysicalLegacyUserTrigger(source, r, parent, child, mapping, indexMap, constraintMap)
				} else {
					validClone = pgPhysicalTriggerClone(source, r, parent, child, mapping, indexMap, constraintMap)
				}
			}
			if !validClone {
				return false
			}
		}
		if before.Version >= 140000 && before.Version < 150000 {
			for id, constraint := range legacyForeign {
				for function := range pgPhysicalLegacyForeignKeys(constraint, child) {
					if !seenLegacy[id+":"+function] {
						return false
					}
				}
			}
		}
		for id, parentTrigger := range parentTriggers {
			row, ok := pgPhysicalNumber(parentTrigger["tgtype"])
			if !ok {
				return false
			}
			if row&1 == 1 && !seenTriggers[id] {
				return false
			}
		}
	}
	return true
}
func pgPhysicalParentIndexesPreserved(old, next pgPhysicalRelation, kind string) bool {
	if len(old.Indexes) != len(next.Indexes) {
		return false
	}
	for i, raw := range old.Indexes {
		a, ok := pgPhysicalMap(raw)
		b, valid := pgPhysicalMap(next.Indexes[i])
		if !ok || !valid {
			return false
		}
		ac, _ := a["class"].(map[string]any)
		bc, _ := b["class"].(map[string]any)
		if ac == nil || bc == nil {
			return false
		}
		if (kind == "createPartition" || kind == "attachPartition") && ac["relhassubclass"] == false && bc["relhassubclass"] == true {
			ac["relhassubclass"] = true
		}
		if !reflect.DeepEqual(a, b) {
			return false
		}
	}
	return true
}
