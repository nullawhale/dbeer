package postgres

import (
	sc "dbeer/helper/internal/schemacompare"
	"dbeer/helper/internal/tableedit"
	"encoding/json"
	"errors"
	"fmt"
	"reflect"
	"regexp"
	"sort"
	"strconv"
	"strings"
)

// Identity maps are catalog-qualified. A coincidentally equal OID in another
// catalog, expression constant, function binding or unknown field stays exact.
type pgAdvancedCopyMap struct {
	ids         map[string]map[string]string
	attrs       map[string]map[int]int
	relations   map[string]string
	replaced    map[string]bool
	files       map[string]any
	toastNames  map[string]string
	ri          map[string]string
	acl         map[string]bool
	indexLayout map[string]bool
}

func pgAdvancedCopyPreservationError(before, after tableedit.Baseline, expectedOrders map[string][]string, replaced map[string]bool) error {
	if before.Engine != "postgresql" || after.Engine != before.Engine || before.Scope != after.Scope || before.Target != after.Target || before.AdvancedEvidence == nil || after.AdvancedEvidence == nil {
		return errors.New("The complete reviewed reconstruction catalog evidence is unavailable.")
	}
	a, b := tableedit.CloneAdvancedEvidence(before.AdvancedEvidence), tableedit.CloneAdvancedEvidence(after.AdvancedEvidence)
	m := &pgAdvancedCopyMap{ids: map[string]map[string]string{}, attrs: map[string]map[int]int{}, relations: map[string]string{}, replaced: replaced, files: map[string]any{}, toastNames: map[string]string{}, ri: map[string]string{}, acl: map[string]bool{}, indexLayout: map[string]bool{}}
	left, err := pgAdvancedCopyTargets(a)
	if err != nil {
		return err
	}
	right, err := pgAdvancedCopyTargets(b)
	if err != nil || len(left) != len(right) || len(expectedOrders) != len(left) {
		return errors.New("The complete reconstruction graph or reviewed column orders changed.")
	}
	for id := range replaced {
		if _, ok := a.Facts[id]; !ok {
			return errors.New("A replacement identity is outside the reviewed graph.")
		}
	}
	for target, id := range left {
		next, ok := right[target]
		if !ok || expectedOrders[id] == nil || id != next && !replaced[id] {
			return errors.New("An unreviewed relation identity or target changed.")
		}
		m.relations[id] = next
		if err := m.add("1259", id, next, replaced[id]); err != nil {
			return err
		}
	}
	if m.relations[before.Identity] != after.Identity {
		return errors.New("The selected reconstruction relation identity changed unexpectedly.")
	}
	// Establish own row-type identities before comparing attribute type bindings.
	for id, next := range m.relations {
		x, y := a.Rows[id+"/class"][0], b.Rows[next+"/class"][0]
		oldType, newType := pgPhysicalOID(x["reltype"]), pgPhysicalOID(y["reltype"])
		if oldType == "" || newType == "" {
			return errors.New("A reconstruction row-type identity is absent.")
		}
		if err := m.add("1247", oldType, newType, replaced[id]); err != nil {
			return err
		}
		ot, nt := pgAdvancedCopyFind(a.Rows[id+"/types"], "oid", oldType), pgAdvancedCopyFind(b.Rows[next+"/types"], "oid", newType)
		if ot == nil || nt == nil || pgPhysicalOID(ot["typrelid"]) != id || pgPhysicalOID(nt["typrelid"]) != next || ot["typtype"] != "c" || nt["typtype"] != "c" {
			return errors.New("The exact reconstruction row-type origin is unproven.")
		}
		if err := m.add("1247", pgPhysicalOID(ot["typarray"]), pgPhysicalOID(nt["typarray"]), replaced[id]); err != nil {
			return err
		}
		oa := pgAdvancedCopyFind(a.Rows[id+"/types"], "oid", pgPhysicalOID(ot["typarray"]))
		na := pgAdvancedCopyFind(b.Rows[next+"/types"], "oid", pgPhysicalOID(nt["typarray"]))
		if oa == nil || na == nil || pgPhysicalOID(oa["typelem"]) != oldType || pgPhysicalOID(na["typelem"]) != newType || pgPhysicalOID(oa["typrelid"]) != "" || pgPhysicalOID(na["typrelid"]) != "" {
			return errors.New("The exact reconstruction row-array type origin is unproven.")
		}
	}
	for id, next := range m.relations {
		p, q := pgAdvancedRelation(id+"/", a), pgAdvancedRelation(next+"/", b)
		// The mapping probe must not rewrite evidence that is transformed later.
		p.Columns = make([]map[string]any, len(p.Columns))
		for i, attr := range a.Rows[id+"/attributes"] {
			p.Columns[i] = pgPhysicalCopy(attr)
			m.slot(p.Columns[i], "atttypid", "1247")
		}
		mapping, ok := pgPhysicalAttributeMap(p, q)
		if !ok {
			return errors.New("The reconstruction column-name, type or collation mapping is incomplete.")
		}
		m.attrs[id] = mapping
		if !replaced[id] {
			for old, next := range mapping {
				if old != next {
					return errors.New("An unselected member changed physical attribute order.")
				}
			}
		}
		if !pgAdvancedCopyOrder(p.Columns, q.Columns, expectedOrders[id], replaced[id]) {
			return errors.New("A reconstruction member does not have its exact reviewed column order.")
		}
		if err := pgAdvancedCopyFacts(a.Facts[id], b.Facts[next]); err != nil {
			return err
		}
		if err := m.objects(a, b, id, next); err != nil {
			return err
		}
		if replaced[id] {
			for _, attr := range a.Rows[id+"/attributes"] {
				var nextAttr map[string]any
				for _, candidate := range b.Rows[next+"/attributes"] {
					if candidate["attname"] == attr["attname"] {
						nextAttr = candidate
					}
				}
				missing, nativeMissing := attr["attmissingval"].([]any)
				if nextAttr != nil && attr["atthasmissing"] == true && nextAttr["atthasmissing"] == false && nativeMissing && len(missing) == 1 && nextAttr["attmissingval"] == nil {
					// Apply separately proves exact stored values before accepting materialization.
					attr["atthasmissing"], attr["attmissingval"] = false, nil
				}
			}
		}
	}
	if err := m.indexAttributes(a, b); err != nil {
		return err
	}
	if err := m.namedObjects(a, b); err != nil {
		return err
	}
	if err := m.triggers(a, b); err != nil {
		return err
	}
	// Effective privileges must be complete even when no explicit ACL exists.
	for id, next := range m.relations {
		x, ok := a.Rows[id+"/copyPrivileges"]
		y, valid := b.Rows[next+"/copyPrivileges"]
		if !ok || !valid || x == nil || y == nil || !pgAdvancedCopyPrivileges(x, y, a.Rows[id+"/attributes"]) {
			return errors.New("Effective table/column privileges changed or their complete proof is absent.")
		}
		m.acl[next] = true
	}
	if len(a.Rows) != len(b.Rows) {
		return errors.New("The reconstruction catalog categories changed.")
	}
	for key, rows := range a.Rows {
		prefix, category, ok := strings.Cut(key, "/")
		newKey := key
		if next, mapped := m.relations[prefix]; mapped {
			newKey = next + "/" + category
		} else if prefix != "global" || !ok {
			return errors.New("The reconstruction contains an unpaired catalog member.")
		}
		rightRows, exists := b.Rows[newKey]
		if !exists {
			return errors.New("A reconstruction catalog category is absent.")
		}
		for _, row := range rows {
			if row == nil {
				return errors.New("A reconstruction catalog record is absent.")
			}
			if err := m.row(row, category, prefix); err != nil {
				return err
			}
		}
		// Location annotations do not participate in node-tree semantics.
		for _, row := range rightRows {
			if row == nil {
				return errors.New("A reconstruction catalog record is absent.")
			}
			m.normalize(row, category)
		}
		if !pgAdvancedCopyEqualRows(rows, rightRows) {
			return fmt.Errorf("Reconstruction did not preserve the complete %s catalog properties.", category)
		}
	}
	return nil
}

func pgAdvancedCopyTargets(e *tableedit.AdvancedEvidence) (map[tableedit.Target]string, error) {
	out := map[tableedit.Target]string{}
	if e == nil || len(e.Facts) == 0 || len(e.Facts) != len(e.Targets) || len(e.Facts) > 64 {
		return nil, errors.New("The reconstruction graph is incomplete.")
	}
	for id, facts := range e.Facts {
		if pgPhysicalOID(id) != id || facts == nil || !facts.Proof || !facts.Table.Columns.Complete || facts.ServerVersion < 140000 || facts.ServerVersion >= 190000 {
			return nil, errors.New("A reconstruction member identity is invalid.")
		}
		t := tableedit.Target{Schema: facts.Table.Ref.Schema, Table: facts.Table.Ref.Name}
		class := e.Rows[id+"/class"]
		if !t.Valid() || out[t] != "" || len(class) != 1 || pgPhysicalOID(class[0]["oid"]) != id || class[0]["relname"] != t.Table {
			return nil, errors.New("A reconstruction member target or class is ambiguous.")
		}
		out[t] = id
		if class[0]["relkind"] != "r" && class[0]["relkind"] != "p" || class[0]["relpersistence"] != "p" && class[0]["relpersistence"] != "u" {
			return nil, errors.New("A reconstruction member has an unsupported native class.")
		}
		for _, category := range []string{"attributes", "defaults", "constraints", "indexes", "indexAttributes", "triggers", "policies", "inherits", "partition", "types", "typeAttributes", "statistics", "rules", "publication", "dependencies", "comments", "labels", "toast", "sequences", "copyPrivileges"} {
			if _, ok := e.Rows[id+"/"+category]; !ok {
				return nil, errors.New("A complete native catalog category is absent.")
			}
		}
	}
	classes := map[string]bool{}
	for id := range e.Facts {
		classes[id] = true
		for _, index := range e.Rows[id+"/indexes"] {
			cl, cok := index["class"].(map[string]any)
			idx, iok := index["index"].(map[string]any)
			if !cok || !iok || pgPhysicalOID(cl["oid"]) == "" || pgPhysicalOID(cl["oid"]) != pgPhysicalOID(idx["indexrelid"]) || pgPhysicalOID(idx["indrelid"]) != id {
				return nil, errors.New("A retained index has no exact owning relation origin.")
			}
			classes[pgPhysicalOID(cl["oid"])] = true
		}
		for _, attr := range e.Rows[id+"/attributes"] {
			if pgPhysicalOID(attr["attrelid"]) != id {
				return nil, errors.New("A retained attribute belongs to an uncaptured relation.")
			}
		}
	}
	connected := map[string]bool{}
	for id := range e.Facts {
		connected[id] = true
		break
	}
	for changed := true; changed; {
		changed = false
		for id := range e.Facts {
			for _, edge := range e.Rows[id+"/inherits"] {
				parent, child := pgPhysicalOID(edge["inhparent"]), pgPhysicalOID(edge["inhrelid"])
				if !classes[parent] || !classes[child] {
					return nil, errors.New("The complete connected hierarchy contains an uncaptured object.")
				}
				if e.Facts[parent] != nil && e.Facts[child] != nil && (connected[parent] || connected[child]) {
					if !connected[parent] || !connected[child] {
						changed = true
					}
					connected[parent], connected[child] = true, true
				}
			}
		}
	}
	if len(connected) != len(e.Facts) {
		return nil, errors.New("The reconstruction relation graph is disconnected.")
	}
	for _, category := range []string{"roles", "memberships", "copyRIFunctions", "copyDefaultPrivileges"} {
		if _, ok := e.Rows["global/"+category]; !ok {
			return nil, errors.New("A complete global catalog category is absent.")
		}
	}
	seen := map[tableedit.Target]bool{}
	for _, t := range e.Targets {
		if out[t] == "" || seen[t] {
			return nil, errors.New("The full reconstruction target list is incomplete.")
		}
		seen[t] = true
	}
	return out, nil
}

func (m *pgAdvancedCopyMap) add(catalog, old, next string, allowed bool) error {
	if old == "" || next == "" || old != next && !allowed {
		return errors.New("An unreviewed catalog object identity changed.")
	}
	if m.ids[catalog] == nil {
		m.ids[catalog] = map[string]string{}
	}
	for source, target := range m.ids[catalog] {
		if source != old && target == next {
			return errors.New("A reconstruction identity mapping is not one-to-one.")
		}
	}
	if existing := m.ids[catalog][old]; existing != "" && existing != next {
		return errors.New("A reconstruction object has conflicting identity mappings.")
	}
	m.ids[catalog][old] = next
	return nil
}

func pgAdvancedCopyFind(rows []map[string]any, key, id string) map[string]any {
	var found map[string]any
	for _, row := range rows {
		if pgPhysicalOID(row[key]) == id {
			if found != nil {
				return nil
			}
			found = row
		}
	}
	return found
}

func pgAdvancedCopyOrder(before, after []map[string]any, order []string, replaced bool) bool {
	if len(before) != len(after) || len(order) == 0 {
		return false
	}
	seen, positions := map[string]bool{}, map[int]string{}
	for _, attr := range after {
		if attr["attisdropped"] == true {
			if replaced {
				return false
			}
			continue
		}
		name, ok := attr["attname"].(string)
		n, valid := pgPhysicalNumber(attr["attnum"])
		if !ok || !valid || !tableedit.Identifier(name) || n <= 0 || seen[name] || positions[n] != "" || attr["attisdropped"] != false {
			return false
		}
		seen[name], positions[n] = true, name
	}
	if len(order) != len(positions) {
		return false
	}
	ordinals := []int{}
	for n := range positions {
		ordinals = append(ordinals, n)
	}
	sort.Ints(ordinals)
	for i, name := range order {
		if positions[ordinals[i]] != name || replaced && ordinals[i] != i+1 {
			return false
		}
	}
	for _, attr := range before {
		if attr["attisdropped"] == true && !replaced {
			continue
		}
		if attr["attisdropped"] != false || !seen[fmt.Sprint(attr["attname"])] {
			return false
		}
	}
	return true
}

func pgAdvancedCopyFacts(before, after *tableedit.Facts) error {
	if before == nil || after == nil || before.ServerVersion != after.ServerVersion {
		return errors.New("The reconstruction native fact/version proof is incomplete.")
	}
	for _, facts := range []*tableedit.Facts{before, after} {
		// Descriptions are captured in dependency OID order; reviewed clones
		// change that order, while every exact label and multiplicity remains.
		for _, labels := range facts.Dependents {
			sort.Strings(labels)
		}
		sort.Slice(facts.Table.Columns.Items, func(i, j int) bool {
			return facts.Table.Columns.Items[i].Ref.Name < facts.Table.Columns.Items[j].Ref.Name
		})
		for i := range facts.Table.Columns.Items {
			facts.Table.Columns.Items[i].Ordinal = sc.Known(i)
			generated := facts.Table.Columns.Items[i].Generated.Value
			if generated != nil && generated.Expression != nil && generated.Expression.Dependencies.Complete && generated.Expression.Dependencies.State == "known" {
				// Named dependency refs are a complete multiset, captured in
				// physical attribute order; raw address edges stay mandatory.
				refs := generated.Expression.Dependencies.Items
				sort.Slice(refs, func(i, j int) bool { return pgAdvancedCopyJSON(refs[i]) < pgAdvancedCopyJSON(refs[j]) })
			}
		}
	}
	if !reflect.DeepEqual(before, after) {
		return errors.New("Reconstruction changed retained typed table properties.")
	}
	return nil
}

func (m *pgAdvancedCopyMap) objects(a, b *tableedit.AdvancedEvidence, id, next string) error {
	allowed := m.replaced[id]
	pairClass := func(x, y map[string]any, replace bool) error {
		if x == nil || y == nil {
			return errors.New("A reconstructed native class is incomplete.")
		}
		old, target := pgPhysicalOID(x["oid"]), pgPhysicalOID(y["oid"])
		if err := m.add("1259", old, target, replace); err != nil {
			return err
		}
		if replace {
			physical := x["relkind"] == "r" || x["relkind"] == "t" || x["relkind"] == "i" || x["relkind"] == "S"
			if physical && (pgPhysicalOID(x["relfilenode"]) == "" || pgPhysicalOID(y["relfilenode"]) == "") {
				return errors.New("A reconstructed physical class has no valid storage identity.")
			}
			m.files[old] = y["relfilenode"]
		}
		return nil
	}
	if err := pairClass(a.Rows[id+"/class"][0], b.Rows[next+"/class"][0], allowed); err != nil {
		return err
	}
	for _, category := range []string{"indexes", "sequences"} {
		left, right := a.Rows[id+"/"+category], b.Rows[next+"/"+category]
		if len(left) != len(right) {
			return errors.New("A retained native index or owned sequence is absent.")
		}
		seen := map[string]bool{}
		for _, x := range left {
			xc, ok := x["class"].(map[string]any)
			if !ok {
				return errors.New("A retained native object class is absent.")
			}
			var y map[string]any
			for _, candidate := range right {
				yc, ok := candidate["class"].(map[string]any)
				if ok && yc["relname"] == xc["relname"] && yc["relnamespace"] == xc["relnamespace"] && (category != "sequences" || candidate["column"] == x["column"]) {
					if y != nil {
						return errors.New("A retained native object name is ambiguous.")
					}
					y = candidate
				}
			}
			if y == nil || seen[pgPhysicalOID(xc["oid"])] {
				return errors.New("A retained native index or sequence origin is ambiguous.")
			}
			seen[pgPhysicalOID(xc["oid"])] = true
			replace := allowed
			if category == "sequences" {
				identity, err := pgAdvancedCopySequenceOrigin(x, id, a.Rows[id+"/attributes"])
				if err != nil {
					return err
				}
				nextIdentity, err := pgAdvancedCopySequenceOrigin(y, next, b.Rows[next+"/attributes"])
				if err != nil || identity != nextIdentity {
					return errors.New("Owned sequence provenance changed.")
				}
				replace = allowed && identity
				xp, xok := pgAdvancedCopyRecordRows(x["copyPrivileges"])
				yp, yok := pgAdvancedCopyRecordRows(y["copyPrivileges"])
				if !xok || !yok || !pgAdvancedCopyPrivileges(xp, yp, nil) {
					return errors.New("Complete effective owned-sequence privileges changed or are absent.")
				}
				m.acl[pgPhysicalOID(y["class"].(map[string]any)["oid"])] = true
			}
			if err := pairClass(xc, y["class"].(map[string]any), replace); err != nil {
				return err
			}
		}
	}
	left, right := a.Rows[id+"/toast"], b.Rows[next+"/toast"]
	if len(left) != len(right) || len(left) > 1 {
		return errors.New("The retained internal TOAST graph changed.")
	}
	if len(left) == 1 {
		x, y := left[0], right[0]
		xc, xok := x["class"].(map[string]any)
		yc, yok := y["class"].(map[string]any)
		if !xok || !yok {
			return errors.New("The internal TOAST class is incomplete.")
		}
		if pgPhysicalOID(a.Rows[id+"/class"][0]["reltoastrelid"]) != pgPhysicalOID(xc["oid"]) || pgPhysicalOID(b.Rows[next+"/class"][0]["reltoastrelid"]) != pgPhysicalOID(yc["oid"]) {
			return errors.New("Internal TOAST storage has no exact owning relation origin.")
		}
		if err := pairClass(xc, yc, allowed); err != nil {
			return err
		}
		if allowed {
			if xc["relname"] != "pg_toast_"+id || yc["relname"] != "pg_toast_"+next {
				return errors.New("An internal TOAST name has no exact relation origin.")
			}
			m.toastNames[pgPhysicalOID(xc["oid"])] = "pg_toast_" + next
		}
		xattrs, xok := pgAdvancedCopyRecordRows(x["attributes"])
		yattrs, yok := pgAdvancedCopyRecordRows(y["attributes"])
		if !xok || !yok {
			return errors.New("The internal TOAST attribute graph is invalid.")
		}
		mapping, ok := pgPhysicalAttributeMap(pgPhysicalRelation{Columns: xattrs}, pgPhysicalRelation{Columns: yattrs})
		if !ok {
			return errors.New("The internal TOAST attribute identity mapping is incomplete.")
		}
		m.attrs[pgPhysicalOID(xc["oid"])] = mapping
		xi, xok := x["indexes"].([]any)
		yi, yok := y["indexes"].([]any)
		if !xok || !yok || len(xi) != 1 || len(yi) != 1 {
			return errors.New("The complete internal TOAST index is absent.")
		}
		xindex, xok := xi[0].(map[string]any)
		yindex, yok := yi[0].(map[string]any)
		if !xok || !yok {
			return errors.New("The internal TOAST index is invalid.")
		}
		xic, xok := xindex["class"].(map[string]any)
		yic, yok := yindex["class"].(map[string]any)
		if !xok || !yok {
			return errors.New("The internal TOAST index class is invalid.")
		}
		if err := pairClass(xic, yic, allowed); err != nil {
			return err
		}
		if allowed {
			if xic["relname"] != "pg_toast_"+id+"_index" || yic["relname"] != "pg_toast_"+next+"_index" {
				return errors.New("An internal TOAST index name has no exact relation origin.")
			}
			m.toastNames[pgPhysicalOID(xic["oid"])] = "pg_toast_" + next + "_index"
		}
	} else if pgPhysicalOID(a.Rows[id+"/class"][0]["reltoastrelid"]) != "" || pgPhysicalOID(b.Rows[next+"/class"][0]["reltoastrelid"]) != "" {
		return errors.New("An owning relation's internal TOAST graph is absent.")
	}
	return nil
}

func pgAdvancedCopyRecordRows(value any) ([]map[string]any, bool) {
	values, ok := value.([]any)
	if !ok {
		return nil, false
	}
	rows := make([]map[string]any, len(values))
	for i, v := range values {
		row, ok := v.(map[string]any)
		if !ok {
			return nil, false
		}
		rows[i] = row
	}
	return rows, true
}

func pgAdvancedCopyIndexCounts(e *tableedit.AdvancedEvidence, id string) (map[string]int, error) {
	out := map[string]int{}
	add := func(row map[string]any, owner string) error {
		cl, cok := row["class"].(map[string]any)
		index, iok := row["index"].(map[string]any)
		if !cok || !iok {
			return errors.New("A complete native index origin is absent.")
		}
		oid := pgPhysicalOID(cl["oid"])
		n, ok := pgPhysicalNumber(index["indnatts"])
		if oid == "" || pgPhysicalOID(index["indexrelid"]) != oid || pgPhysicalOID(index["indrelid"]) != owner || !ok || n < 1 || n > tableedit.MaxColumns || out[oid] != 0 || cl["relkind"] != "i" && cl["relkind"] != "I" {
			return errors.New("A native index tuple layout has no exact class/owner origin.")
		}
		out[oid] = n
		return nil
	}
	for _, row := range e.Rows[id+"/indexes"] {
		if err := add(row, id); err != nil {
			return nil, err
		}
	}
	for _, toast := range e.Rows[id+"/toast"] {
		cl, ok := toast["class"].(map[string]any)
		rows, valid := pgAdvancedCopyRecordRows(toast["indexes"])
		if !ok || !valid {
			return nil, errors.New("A native TOAST index tuple layout is incomplete.")
		}
		for _, row := range rows {
			if err := add(row, pgPhysicalOID(cl["oid"])); err != nil {
				return nil, err
			}
		}
	}
	return out, nil
}

func pgAdvancedCopyIndexRows(e *tableedit.AdvancedEvidence, id string, counts map[string]int) (map[string]map[int]bool, error) {
	out := map[string]map[int]bool{}
	for _, row := range e.Rows[id+"/indexAttributes"] {
		oid := pgPhysicalOID(row["attrelid"])
		n, ok := pgPhysicalNumber(row["attnum"])
		if counts[oid] == 0 || !ok || n < 1 || n > counts[oid] || out[oid][n] || pgPhysicalOID(row["atttypid"]) == "" || row["attisdropped"] != false || row["atthasmissing"] != false || row["attmissingval"] != nil {
			return nil, errors.New("A native index attribute has no exact nonmissing term ordinal/class proof.")
		}
		if out[oid] == nil {
			out[oid] = map[int]bool{}
		}
		out[oid][n] = true
	}
	for oid, n := range counts {
		if len(out[oid]) != n {
			return nil, errors.New("The complete native index attribute layout is absent.")
		}
	}
	return out, nil
}

func (m *pgAdvancedCopyMap) indexAttributes(a, b *tableedit.AdvancedEvidence) error {
	for id, next := range m.relations {
		left, err := pgAdvancedCopyIndexCounts(a, id)
		if err != nil {
			return err
		}
		right, err := pgAdvancedCopyIndexCounts(b, next)
		if err != nil {
			return err
		}
		oldRows, err := pgAdvancedCopyIndexRows(a, id, left)
		if err != nil {
			return err
		}
		if _, err = pgAdvancedCopyIndexRows(b, next, right); err != nil {
			return err
		}
		if len(left) != len(right) {
			return errors.New("The native index tuple layout graph changed.")
		}
		for oid, n := range left {
			mapped := m.id("1259", oid)
			if right[mapped] != n || m.attrs[oid] != nil {
				return errors.New("A native index tuple layout has no unique mapped class origin.")
			}
			m.attrs[oid] = map[int]int{}
			for ordinal := range oldRows[oid] {
				m.attrs[oid][ordinal] = ordinal
			}
			if m.replaced[id] && mapped != oid {
				m.indexLayout[mapped] = true
			}
		}
	}
	return nil
}

func pgAdvancedCopySequenceOrigin(row map[string]any, relation string, attrs []map[string]any) (bool, error) {
	cl, ok := row["class"].(map[string]any)
	if !ok || cl["relkind"] != "S" {
		return false, errors.New("An owned sequence class has no exact native origin.")
	}
	var attr map[string]any
	for _, candidate := range attrs {
		if candidate["attname"] == row["column"] {
			if attr != nil {
				return false, errors.New("An owned sequence column is ambiguous.")
			}
			attr = candidate
		}
	}
	if attr == nil {
		return false, errors.New("An owned sequence column is absent.")
	}
	deps, ok := pgAdvancedCopyRecordRows(row["dependencies"])
	if !ok {
		return false, errors.New("An owned sequence dependency proof is absent.")
	}
	count, identity := 0, false
	for _, d := range deps {
		if pgPhysicalOID(d["classid"]) == "1259" && pgPhysicalOID(d["objid"]) == pgPhysicalOID(cl["oid"]) && pgPhysicalOID(d["refclassid"]) == "1259" && pgPhysicalOID(d["refobjid"]) == relation && reflect.DeepEqual(d["refobjsubid"], attr["attnum"]) && (d["deptype"] == "i" || d["deptype"] == "a") {
			count++
			identity = d["deptype"] == "i"
		}
	}
	if count != 1 || identity != (attr["attidentity"] == "a" || attr["attidentity"] == "d") {
		return false, errors.New("An owned sequence lacks exact column/ownership provenance.")
	}
	sequence, ok := row["sequence"].(map[string]any)
	if !ok || pgPhysicalOID(sequence["seqrelid"]) != pgPhysicalOID(cl["oid"]) {
		return false, errors.New("An owned sequence definition has no exact class origin.")
	}
	return identity, nil
}

func (m *pgAdvancedCopyMap) namedObjects(a, b *tableedit.AdvancedEvidence) error {
	for id, next := range m.relations {
		for _, spec := range []struct{ category, catalog, name, owner string }{{"defaults", "2604", "adnum", "adrelid"}, {"constraints", "2606", "conname", "conrelid"}, {"policies", "3256", "polname", "polrelid"}} {
			left, right := a.Rows[id+"/"+spec.category], b.Rows[next+"/"+spec.category]
			if len(left) != len(right) {
				return errors.New("A retained constraint, policy or default is absent.")
			}
			seen := map[string]bool{}
			for _, x := range left {
				owner := pgPhysicalOID(x[spec.owner])
				mappedOwner := m.id("1259", owner)
				name := x[spec.name]
				if spec.category == "defaults" {
					n, ok := pgPhysicalNumber(name)
					mapped, exists := m.attrs[owner][n]
					if !ok || !exists {
						return errors.New("An attribute default has no exact named-column mapping.")
					}
					name = pgPhysicalIDLike(name, mapped)
				}
				var y map[string]any
				for _, candidate := range right {
					if pgPhysicalOID(candidate[spec.owner]) == mappedOwner && reflect.DeepEqual(candidate[spec.name], name) && (spec.category != "constraints" || candidate["contype"] == x["contype"]) {
						if y != nil {
							return errors.New("A retained catalog object name is ambiguous.")
						}
						y = candidate
					}
				}
				if y == nil || seen[pgPhysicalOID(y["oid"])] {
					return errors.New("A retained catalog object has no exact origin.")
				}
				seen[pgPhysicalOID(y["oid"])] = true
				allowed := m.replaced[owner]
				if spec.category == "constraints" {
					allowed = allowed || m.constraintAffected(a, x, map[string]bool{})
				}
				if err := m.add(spec.catalog, pgPhysicalOID(x["oid"]), pgPhysicalOID(y["oid"]), allowed); err != nil {
					return err
				}
			}
		}
	}
	return nil
}

func (m *pgAdvancedCopyMap) triggers(a, b *tableedit.AdvancedEvidence) error {
	if !pgAdvancedCopyEqualRows(a.Rows["global/copyRIFunctions"], b.Rows["global/copyRIFunctions"]) || len(a.Rows["global/copyRIFunctions"]) != 12 {
		return errors.New("Native referential-integrity function provenance changed.")
	}
	seenFunctions := map[string]bool{}
	for _, p := range a.Rows["global/copyRIFunctions"] {
		name, _ := p["proname"].(string)
		id := pgPhysicalOID(p["oid"])
		n, _ := strconv.ParseUint(id, 10, 32)
		validName := false
		for _, name := range []string{"RI_FKey_check_ins", "RI_FKey_check_upd", "RI_FKey_noaction_del", "RI_FKey_noaction_upd", "RI_FKey_restrict_del", "RI_FKey_restrict_upd", "RI_FKey_cascade_del", "RI_FKey_cascade_upd", "RI_FKey_setnull_del", "RI_FKey_setnull_upd", "RI_FKey_setdefault_del", "RI_FKey_setdefault_upd"} {
			validName = validName || p["proname"] == name
		}
		if id == "" || n >= 16384 || seenFunctions[id] || m.ri[name] != "" || !validName || p["prosrc"] != name || pgPhysicalOID(p["pronamespace"]) != "11" || pgPhysicalOID(p["prolang"]) != "12" || pgPhysicalOID(p["prorettype"]) != "2279" || fmt.Sprint(p["pronargs"]) != "0" || fmt.Sprint(p["pronargdefaults"]) != "0" || p["proconfig"] != nil || p["prosecdef"] != false {
			return errors.New("Native referential-integrity function provenance is ambiguous.")
		}
		m.ri[name] = id
		seenFunctions[id] = true
	}
	for id, next := range m.relations {
		left, right := a.Rows[id+"/triggers"], b.Rows[next+"/triggers"]
		if len(left) != len(right) {
			return errors.New("A retained trigger is absent.")
		}
		seen := map[string]bool{}
		for _, x := range left {
			var y map[string]any
			for _, candidate := range right {
				match := candidate["tgname"] == x["tgname"]
				if x["tgisinternal"] == true && strings.HasPrefix(fmt.Sprint(x["tgname"]), "RI_ConstraintTrigger_") {
					match = false
					if len(m.ri) == 12 {
						constraint := pgAdvancedCopyFind(a.Rows[id+"/constraints"], "oid", pgPhysicalOID(x["tgconstraint"]))
						nextConstraint := pgAdvancedCopyFind(b.Rows[next+"/constraints"], "oid", m.id("2606", pgPhysicalOID(x["tgconstraint"])))
						if constraint != nil && nextConstraint != nil {
							p, q := pgPhysicalCopy(x), pgPhysicalCopy(candidate)
							p["tgparentid"], q["tgparentid"] = "0", "0"
							pk, pok := pgPhysicalLegacyForeignTrigger(p, constraint, pgAdvancedRelation(id+"/", a), m.ri)
							qk, qok := pgPhysicalLegacyForeignTrigger(q, nextConstraint, pgAdvancedRelation(next+"/", b), m.ri)
							_, pf, _ := strings.Cut(pk, ":")
							_, qf, _ := strings.Cut(qk, ":")
							match = pok && qok && pf == qf
						}
					}
				}
				if match {
					if y != nil {
						return errors.New("A retained trigger origin is ambiguous.")
					}
					y = candidate
				}
			}
			if y == nil || seen[pgPhysicalOID(y["oid"])] {
				return errors.New("A retained trigger has no exact native origin.")
			}
			seen[pgPhysicalOID(y["oid"])] = true
			allowed := m.replaced[id] || m.triggerAffected(a, id, x, map[string]bool{})
			if err := m.add("2620", pgPhysicalOID(x["oid"]), pgPhysicalOID(y["oid"]), allowed); err != nil {
				return err
			}
			if x["tgname"] != y["tgname"] {
				x["tgname"] = y["tgname"]
			}
		}
	}
	for id, next := range m.relations {
		for _, x := range a.Rows[id+"/triggers"] {
			if pgPhysicalOID(x["tgparentid"]) != "" && m.id("2620", pgPhysicalOID(x["oid"])) != pgPhysicalOID(x["oid"]) {
				y := pgAdvancedCopyFind(b.Rows[next+"/triggers"], "oid", m.id("2620", pgPhysicalOID(x["oid"])))
				if y == nil || !pgAdvancedCopyTriggerClone(b, next, y) {
					return errors.New("A recreated descendant trigger lost its exact native parent provenance.")
				}
			}
		}
	}
	return nil
}

func pgAdvancedCopyObject(e *tableedit.AdvancedEvidence, category, id string) (string, map[string]any) {
	var owner string
	var found map[string]any
	for relation := range e.Facts {
		for _, row := range e.Rows[relation+"/"+category] {
			if pgPhysicalOID(row["oid"]) == id {
				if found != nil && !reflect.DeepEqual(found, row) {
					return "", nil
				}
				found = row
				owner = pgPhysicalOID(row[map[string]string{"constraints": "conrelid", "triggers": "tgrelid"}[category]])
			}
		}
	}
	return owner, found
}
func pgAdvancedCopyPartitionLink(e *tableedit.AdvancedEvidence, parent, child string) bool {
	cl := e.Rows[child+"/class"]
	if len(cl) != 1 || cl[0]["relispartition"] != true {
		return false
	}
	count := 0
	for _, row := range e.Rows[child+"/inherits"] {
		if pgPhysicalOID(row["inhrelid"]) == child && pgPhysicalOID(row["inhparent"]) == parent && row["inhdetachpending"] != true {
			count++
		}
	}
	return count == 1
}
func (m *pgAdvancedCopyMap) constraintAffected(e *tableedit.AdvancedEvidence, row map[string]any, seen map[string]bool) bool {
	id, owner := pgPhysicalOID(row["oid"]), pgPhysicalOID(row["conrelid"])
	if seen[id] {
		return false
	}
	seen[id] = true
	if m.replaced[owner] {
		return true
	}
	if row["conislocal"] != false || fmt.Sprint(row["coninhcount"]) != "1" || row["connoinherit"] != false {
		return false
	}
	parentOwner, parent := pgAdvancedCopyObject(e, "constraints", pgPhysicalOID(row["conparentid"]))
	return parent != nil && parent["contype"] == row["contype"] && pgAdvancedCopyPartitionLink(e, parentOwner, owner) && m.constraintAffected(e, parent, seen)
}
func (m *pgAdvancedCopyMap) triggerAffected(e *tableedit.AdvancedEvidence, owner string, row map[string]any, seen map[string]bool) bool {
	id := pgPhysicalOID(row["oid"])
	if seen[id] {
		return false
	}
	seen[id] = true
	constraint := pgPhysicalOID(row["tgconstraint"])
	if constraint != "" && m.id("2606", constraint) != constraint && row["tgisinternal"] == true && strings.HasPrefix(fmt.Sprint(row["tgname"]), "RI_ConstraintTrigger_") {
		return true
	}
	parentOwner, parent := pgAdvancedCopyObject(e, "triggers", pgPhysicalOID(row["tgparentid"]))
	return parent != nil && pgAdvancedCopyTriggerClone(e, owner, row) && (m.replaced[parentOwner] || m.triggerAffected(e, parentOwner, parent, seen))
}
func pgAdvancedCopyTriggerClone(e *tableedit.AdvancedEvidence, owner string, row map[string]any) bool {
	parentOwner, parent := pgAdvancedCopyObject(e, "triggers", pgPhysicalOID(row["tgparentid"]))
	if parent == nil || !pgAdvancedCopyPartitionLink(e, parentOwner, owner) {
		return false
	}
	p, c := pgAdvancedRelation(parentOwner+"/", e), pgAdvancedRelation(owner+"/", e)
	mapping, ok := pgPhysicalAttributeMap(p, c)
	if !ok {
		return false
	}
	indexes, constraints := map[string]any{}, map[string]any{}
	for _, index := range e.Rows[owner+"/indexes"] {
		cl, cok := index["class"].(map[string]any)
		parents, pok := index["parents"].([]any)
		if cok && pok && len(parents) == 1 {
			indexes[pgPhysicalOID(parents[0])] = cl["oid"]
		}
	}
	for _, constraint := range e.Rows[owner+"/constraints"] {
		if origin := pgPhysicalOID(constraint["conparentid"]); origin != "" {
			constraints[origin] = constraint["oid"]
		}
	}
	version := e.Facts[owner].ServerVersion
	if version >= 140000 && version < 150000 {
		return pgPhysicalLegacyUserTrigger(parent, row, p, c, mapping, indexes, constraints)
	}
	return version >= 150000 && version < 190000 && pgPhysicalTriggerClone(parent, row, p, c, mapping, indexes, constraints)
}

func (m *pgAdvancedCopyMap) id(catalog, old string) string {
	if next := m.ids[catalog][old]; next != "" {
		return next
	}
	return old
}
func (m *pgAdvancedCopyMap) slot(row map[string]any, key, catalog string) {
	if old := pgPhysicalOID(row[key]); old != "" {
		if next := m.ids[catalog][old]; next != "" {
			if _, ok := row[key].(string); ok {
				row[key] = next
			} else {
				n, _ := strconv.ParseUint(next, 10, 32)
				row[key] = float64(n)
			}
		}
	}
}
func (m *pgAdvancedCopyMap) attnum(row map[string]any, key, owner string) error {
	value, present := row[key]
	if !present || value == nil {
		return nil
	}
	n, ok := pgPhysicalNumber(value)
	if !ok {
		return errors.New("A catalog attribute address is invalid.")
	}
	if n <= 0 {
		return nil
	}
	next, ok := m.attrs[owner][n]
	if !ok {
		if m.attrs[owner] == nil {
			return nil
		}
		return errors.New("A catalog attribute address has no named-column mapping.")
	}
	row[key] = pgPhysicalIDLike(value, next)
	return nil
}
func (m *pgAdvancedCopyMap) attnums(row map[string]any, key, owner string) error {
	value, present := row[key]
	if !present {
		return nil
	}
	if m.attrs[owner] == nil {
		return nil
	}
	next, ok := pgPhysicalMapAttnums(value, m.attrs[owner])
	if !ok {
		return errors.New("A catalog attribute vector has no complete named-column mapping.")
	}
	row[key] = next
	return nil
}
func (m *pgAdvancedCopyMap) node(row map[string]any, key, owner string) error {
	value, present := row[key]
	if !present {
		return nil
	}
	if text, ok := value.(string); ok {
		reordered := false
		for a, b := range m.attrs[owner] {
			reordered = reordered || a != b
		}
		if reordered {
			// E6's Var mapper is local-relation only. Nested queries need a
			// separate range-table-aware repair, never a global attnum rewrite.
			if strings.Contains(text, "{QUERY ") || strings.Contains(text, "{SUBLINK ") || strings.Contains(text, "{SUBPLAN ") {
				return errors.New("A nested node tree requires explicit external relation repair.")
			}
			vars := pgAdvancedCopyVars.FindAllString(text, -1)
			if len(vars) != strings.Count(text, "{VAR ") {
				return errors.New("A node-tree Var record cannot be mapped precisely.")
			}
			for _, v := range vars {
				for _, field := range []string{"varno", "varlevelsup"} {
					parts := regexp.MustCompile(`:` + field + ` ([0-9]+)`).FindStringSubmatch(v)
					if len(parts) != 2 {
						return errors.New("A node-tree Var address is incomplete.")
					}
					n, _ := strconv.Atoi(parts[1])
					if field == "varlevelsup" && n != 0 || field == "varno" && n != 1 && !(key == "tgqual" && n == 2) {
						return errors.New("A node tree contains an unproven external Var address.")
					}
				}
			}
		}
	}
	next, ok := pgPhysicalMapNode(value, m.attrs[owner])
	if !ok {
		return errors.New("A node tree needs an unsupported whole-row or external attribute repair.")
	}
	row[key] = next
	return nil
}

var pgAdvancedCopyVars = regexp.MustCompile(`\{VAR [^{}]*\}`)

func (m *pgAdvancedCopyMap) row(row map[string]any, category, owner string) error {
	mapSlots := func(catalog string, keys ...string) {
		for _, key := range keys {
			m.slot(row, key, catalog)
		}
	}
	mapAttnums := func(rel string, keys ...string) error {
		for _, key := range keys {
			if err := m.attnums(row, key, rel); err != nil {
				return err
			}
		}
		return nil
	}
	mapNodes := func(rel string, keys ...string) error {
		for _, key := range keys {
			if err := m.node(row, key, rel); err != nil {
				return err
			}
		}
		return nil
	}
	switch category {
	case "class":
		id := pgPhysicalOID(row["oid"])
		if err := mapNodes(id, "relpartbound"); err != nil {
			return err
		}
		if file, ok := m.files[id]; ok {
			row["relfilenode"] = file
		}
		if name, ok := m.toastNames[id]; ok {
			row["relname"] = name
		}
		mapSlots("1259", "oid", "reltoastrelid")
		mapSlots("1247", "reltype")
	case "attributes":
		rel := pgPhysicalOID(row["attrelid"])
		if row["attisdropped"] != true {
			if err := m.attnum(row, "attnum", rel); err != nil {
				return err
			}
		}
		mapSlots("1259", "attrelid")
		mapSlots("1247", "atttypid")
	case "indexAttributes":
		// Index terms have their own native ordinal, independent of the table
		// attribute order. Only their proved class and type addresses map.
		mapSlots("1259", "attrelid")
		mapSlots("1247", "atttypid")
	case "types":
		if _, own := m.ids["1247"][pgPhysicalOID(row["oid"])]; own {
			mapSlots("1247", "oid", "typarray", "typelem")
			mapSlots("1259", "typrelid")
		}
	case "defaults":
		rel := pgPhysicalOID(row["adrelid"])
		if err := m.attnum(row, "adnum", rel); err != nil {
			return err
		}
		if err := mapNodes(rel, "adbin"); err != nil {
			return err
		}
		mapSlots("2604", "oid")
		mapSlots("1259", "adrelid")
	case "constraints":
		rel, ref := pgPhysicalOID(row["conrelid"]), pgPhysicalOID(row["confrelid"])
		if err := mapAttnums(rel, "conkey", "confdelsetcols"); err != nil {
			return err
		}
		if err := mapAttnums(ref, "confkey"); err != nil {
			return err
		}
		if err := mapNodes(rel, "conbin"); err != nil {
			return err
		}
		mapSlots("2606", "oid", "conparentid")
		mapSlots("1259", "conrelid", "confrelid", "conindid")
		mapSlots("1247", "contypid")
	case "indexes":
		cl, ok := row["class"].(map[string]any)
		if !ok {
			return errors.New("A native index class is invalid.")
		}
		if err := m.row(cl, "class", owner); err != nil {
			return err
		}
		idx, ok := row["index"].(map[string]any)
		if !ok {
			return errors.New("A native index record is invalid.")
		}
		if err := m.row(idx, "index", owner); err != nil {
			return err
		}
		if parents, present := row["parents"]; present {
			values, ok := parents.([]any)
			if !ok {
				return errors.New("Native index parent addresses are invalid.")
			}
			for i, v := range values {
				tmp := map[string]any{"id": v}
				m.slot(tmp, "id", "1259")
				values[i] = tmp["id"]
			}
			sort.Slice(values, func(i, j int) bool { return fmt.Sprint(values[i]) < fmt.Sprint(values[j]) })
		}
	case "index":
		rel := pgPhysicalOID(row["indrelid"])
		if err := mapAttnums(rel, "indkey"); err != nil {
			return err
		}
		if err := mapNodes(rel, "indexprs", "indpred"); err != nil {
			return err
		}
		mapSlots("1259", "indexrelid", "indrelid")
		if m.indexLayout[pgPhysicalOID(row["indexrelid"])] {
			for _, key := range []string{"indexprs", "indpred"} {
				next, err := pgAdvancedCopyIndexNodeFormats(row[key])
				if err != nil {
					return err
				}
				row[key] = next
			}
		}
	case "triggers":
		rel := pgPhysicalOID(row["tgrelid"])
		if err := mapAttnums(rel, "tgattr"); err != nil {
			return err
		}
		if err := mapNodes(rel, "tgqual"); err != nil {
			return err
		}
		mapSlots("2620", "oid", "tgparentid")
		mapSlots("1259", "tgrelid", "tgconstrrelid", "tgconstrindid")
		mapSlots("2606", "tgconstraint")
	case "policies":
		rel := pgPhysicalOID(row["polrelid"])
		if err := mapNodes(rel, "polqual", "polwithcheck"); err != nil {
			return err
		}
		mapSlots("3256", "oid")
		mapSlots("1259", "polrelid")
	case "inherits":
		mapSlots("1259", "inhrelid", "inhparent")
	case "partition":
		rel := pgPhysicalOID(row["partrelid"])
		if err := mapAttnums(rel, "partattrs"); err != nil {
			return err
		}
		if err := mapNodes(rel, "partexprs"); err != nil {
			return err
		}
		mapSlots("1259", "partrelid")
	case "dependencies":
		for _, p := range [][3]string{{"classid", "objid", "objsubid"}, {"refclassid", "refobjid", "refobjsubid"}} {
			catalog := pgPhysicalOID(row[p[0]])
			rel := pgPhysicalOID(row[p[1]])
			if catalog == "1259" {
				if err := m.attnum(row, p[2], rel); err != nil {
					return err
				}
			}
			m.slot(row, p[1], catalog)
		}
	case "comments", "labels":
		catalog, rel := pgPhysicalOID(row["classoid"]), pgPhysicalOID(row["objoid"])
		if catalog == "1259" {
			if err := m.attnum(row, "objsubid", rel); err != nil {
				return err
			}
		}
		m.slot(row, "objoid", catalog)
	case "sequences":
		cl, ok := row["class"].(map[string]any)
		if !ok {
			return errors.New("An owned sequence class is invalid.")
		}
		if err := m.row(cl, "class", owner); err != nil {
			return err
		}
		seq, ok := row["sequence"].(map[string]any)
		if !ok {
			return errors.New("An owned sequence definition is invalid.")
		}
		m.slot(seq, "seqrelid", "1259")
		m.slot(seq, "seqtypid", "1247")
		for _, key := range []string{"dependencies", "comments", "labels"} {
			values, ok := row[key].([]any)
			if !ok {
				return errors.New("An owned sequence catalog proof is incomplete.")
			}
			for _, v := range values {
				child, ok := v.(map[string]any)
				if !ok {
					return errors.New("An owned sequence catalog record is invalid.")
				}
				if err := m.row(child, key, owner); err != nil {
					return err
				}
			}
			pgAdvancedCopySortValues(values)
		}
	case "toast":
		cl, ok := row["class"].(map[string]any)
		if !ok {
			return errors.New("An internal TOAST class is invalid.")
		}
		if err := m.row(cl, "class", owner); err != nil {
			return err
		}
		for _, key := range []string{"attributes", "indexes"} {
			values, ok := row[key].([]any)
			if !ok {
				return errors.New("The internal TOAST catalog graph is incomplete.")
			}
			for _, v := range values {
				child, ok := v.(map[string]any)
				if !ok {
					return errors.New("An internal TOAST catalog record is invalid.")
				}
				if err := m.row(child, key, owner); err != nil {
					return err
				}
			}
		}
	case "statistics":
		rel := pgPhysicalOID(row["stxrelid"])
		if err := mapAttnums(rel, "stxkeys"); err != nil {
			return err
		}
		if err := mapNodes(rel, "stxexprs"); err != nil {
			return err
		}
		mapSlots("1259", "stxrelid")
	case "rules":
		mapSlots("1259", "ev_class")
	case "publication":
		rel := pgPhysicalOID(row["prrelid"])
		if err := mapAttnums(rel, "prattrs"); err != nil {
			return err
		}
		if err := mapNodes(rel, "prqual"); err != nil {
			return err
		}
		mapSlots("1259", "prrelid")
	}
	m.normalize(row, category)
	return nil
}

func (m *pgAdvancedCopyMap) normalize(row map[string]any, category string) {
	keys := map[string][]string{"class": {"relpartbound"}, "defaults": {"adbin"}, "constraints": {"conbin"}, "index": {"indexprs", "indpred"}, "triggers": {"tgqual"}, "policies": {"polqual", "polwithcheck"}, "partition": {"partexprs"}, "statistics": {"stxexprs"}, "publication": {"prqual"}}
	for _, key := range keys[category] {
		if v, ok := row[key]; ok {
			row[key] = pgPhysicalNodePositions(v)
		}
	}
	if category == "index" && m.indexLayout[pgPhysicalOID(row["indexrelid"])] {
		for _, key := range []string{"indexprs", "indpred"} {
			if next, err := pgAdvancedCopyIndexNodeFormats(row[key]); err == nil {
				row[key] = next
			}
		}
	}
	if category == "class" && m.acl[pgPhysicalOID(row["oid"])] {
		if _, ok := row["relacl"]; ok {
			row["relacl"] = nil
		}
	}
	if category == "attributes" && m.acl[pgPhysicalOID(row["attrelid"])] {
		if _, ok := row["attacl"]; ok {
			row["attacl"] = nil
		}
	}
	if category == "attributes" {
		for old := range m.files {
			if pgPhysicalOID(row["attrelid"]) == m.id("1259", old) {
				if value, present := row["attoptions"]; present {
					row["attoptions"] = tableedit.SemanticPostgresAttributeOptions(value)
				}
			}
		}
	}
	if category == "indexAttributes" && m.indexLayout[pgPhysicalOID(row["attrelid"])] {
		if value, present := row["attoptions"]; present {
			row["attoptions"] = tableedit.SemanticPostgresAttributeOptions(value)
		}
	}
	if category == "indexes" {
		if cl, ok := row["class"].(map[string]any); ok {
			m.normalize(cl, "class")
		}
		if index, ok := row["index"].(map[string]any); ok {
			m.normalize(index, "index")
		}
		if values, ok := row["parents"].([]any); ok {
			sort.Slice(values, func(i, j int) bool { return fmt.Sprint(values[i]) < fmt.Sprint(values[j]) })
		}
	}
	if category == "sequences" || category == "toast" {
		if cl, ok := row["class"].(map[string]any); ok {
			m.normalize(cl, "class")
		}
		for _, key := range []string{"attributes", "indexes", "dependencies", "comments", "labels", "copyPrivileges"} {
			if values, ok := row[key].([]any); ok {
				for _, v := range values {
					if child, ok := v.(map[string]any); ok {
						m.normalize(child, key)
					}
				}
				if category == "sequences" {
					pgAdvancedCopySortValues(values)
				}
			}
		}
	}
}

func pgAdvancedCopyPrivileges(a, b []map[string]any, attrs []map[string]any) bool {
	names := map[string]bool{"": true}
	for _, attr := range attrs {
		if name, ok := attr["attname"].(string); ok {
			names[name] = true
		}
	}
	for _, rows := range [][]map[string]any{a, b} {
		seen := map[string]bool{}
		for _, row := range rows {
			column, cok := row["column"].(string)
			grantor, gok := row["grantor"].(string)
			grantee, rok := row["grantee"].(string)
			privilege, pok := row["privilege"].(string)
			_, bok := row["grantable"].(bool)
			if len(row) != 5 || !cok || !names[column] || !gok || pgPhysicalOID(grantor) != grantor || !rok || grantee != "0" && pgPhysicalOID(grantee) != grantee || !pok || privilege == "" || !bok {
				return false
			}
			key := pgAdvancedCopyJSON(row)
			if seen[key] {
				return false
			}
			seen[key] = true
		}
	}
	return pgAdvancedCopyEqualRows(a, b)
}
func pgAdvancedCopyJSON(v any) string { raw, _ := json.Marshal(v); return string(raw) }
func pgAdvancedCopyEqualRows(a, b []map[string]any) bool {
	if len(a) != len(b) || (a == nil) != (b == nil) {
		return false
	}
	x, y := make([]string, len(a)), make([]string, len(b))
	for i := range a {
		x[i] = pgAdvancedCopyJSON(a[i])
		y[i] = pgAdvancedCopyJSON(b[i])
	}
	sort.Strings(x)
	sort.Strings(y)
	return reflect.DeepEqual(x, y)
}
func pgAdvancedCopySortValues(values []any) {
	sort.Slice(values, func(i, j int) bool { return pgAdvancedCopyJSON(values[i]) < pgAdvancedCopyJSON(values[j]) })
}
