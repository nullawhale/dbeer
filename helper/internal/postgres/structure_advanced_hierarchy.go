package postgres

import (
	sc "dbeer/helper/internal/schemacompare"
	"dbeer/helper/internal/tableedit"
	"encoding/json"
	"errors"
	"fmt"
	"reflect"
	"sort"
	"strings"
)

func pgAdvancedDescendants(b tableedit.Baseline) map[string]bool {
	out := map[string]bool{b.Identity: true}
	if b.AdvancedEvidence == nil {
		return out
	}
	for changed := true; changed; {
		changed = false
		for key, rows := range b.AdvancedEvidence.Rows {
			if !strings.HasSuffix(key, "/inherits") {
				continue
			}
			for _, row := range rows {
				parent, child := pgPhysicalOID(row["inhparent"]), pgPhysicalOID(row["inhrelid"])
				if out[parent] && !out[child] && len(b.AdvancedEvidence.Rows[child+"/class"]) == 1 {
					out[child] = true
					changed = true
				}
			}
		}
	}
	return out
}
func pgAdvancedRecursiveCondition(b tableedit.Baseline, c tableedit.Condition) bool {
	if b.Advanced == nil {
		return false
	}
	if pgAdvancedPartitionIdentity(b, c) {
		return true
	}
	if len(pgAdvancedDescendants(b)) < 2 {
		return false
	}
	switch c.Operation.Kind {
	case "addColumn", "dropColumn", "renameColumn":
		return true
	case "changeColumn":
		return c.Operation.Change != nil && (c.Operation.Change.Nullable != nil || c.Operation.Change.Type != nil || c.Operation.Change.Generated != nil && c.Operation.Change.Generated.Storage == "none")
	}
	return false
}
func pgAdvancedRecursiveOperation(b tableedit.Baseline, op tableedit.Operation) bool {
	return pgAdvancedRecursiveCondition(b, tableedit.Condition{Operation: op})
}
func pgAdvancedNode(b tableedit.Baseline, id string) tableedit.Baseline {
	e := b.AdvancedEvidence
	classes := e.Rows[id+"/class"]
	if len(classes) != 1 {
		return tableedit.Baseline{}
	}
	class := classes[0]
	node := tableedit.Baseline{Engine: "postgresql", Identity: id, Scope: b.Scope, Guard: tableedit.Fingerprint([]any{class["relowner"], class["relam"], class["relpersistence"], class["relkind"], class["relrowsecurity"], class["relforcerowsecurity"], class["reloftype"], class["relispartition"], class["reloptions"], class["relacl"]}), Facts: e.Facts[id], Attributes: map[string]map[string]any{}, Advanced: b.Advanced}
	if node.Facts == nil {
		return tableedit.Baseline{}
	}
	node.Target = tableedit.Target{Schema: node.Facts.Table.Ref.Schema, Table: node.Facts.Table.Ref.Name}
	for _, row := range e.Rows[id+"/attributes"] {
		name, ok := row["attname"].(string)
		if !ok {
			return tableedit.Baseline{}
		}
		node.Attributes[name] = row
	}
	for _, column := range node.Facts.Table.Columns.Items {
		nullable := column.Nullable.Value != nil && *column.Nullable.Value
		node.Columns = append(node.Columns, tableedit.ObservedColumn{Name: column.Ref.Name, Nullable: nullable})
	}
	tableedit.Summarize(&node)
	proof := &tableedit.AdvancedEvidence{Rows: map[string][]map[string]any{}, Facts: map[string]*tableedit.Facts{id: node.Facts}, Targets: []tableedit.Target{node.Target}}
	for key, rows := range e.Rows {
		if strings.HasPrefix(key, id+"/") || strings.HasPrefix(key, "global/") {
			proof.Rows[key] = rows
		}
	}
	node.AdvancedEvidence = proof
	node.Fingerprint = tableedit.Fingerprint([]any{node.Facts, node.Attributes, proof.Rows})
	return node
}
func pgAdvancedCopyAttrs(b tableedit.Baseline) tableedit.Baseline {
	raw, _ := json.Marshal(b.Attributes)
	var attrs map[string]map[string]any
	_ = json.Unmarshal(raw, &attrs)
	b.Attributes = attrs
	return b
}
func pgAdvancedAncestors(e *tableedit.AdvancedEvidence, id string) map[string]bool {
	out := map[string]bool{id: true}
	for changed := true; changed; {
		changed = false
		for key, rows := range e.Rows {
			if !strings.HasSuffix(key, "/inherits") {
				continue
			}
			for _, row := range rows {
				parent, child := pgPhysicalOID(row["inhparent"]), pgPhysicalOID(row["inhrelid"])
				if out[child] && !out[parent] && len(e.Rows[parent+"/class"]) == 1 {
					out[parent] = true
					changed = true
				}
			}
		}
	}
	return out
}
func pgAdvancedHierarchyDraft(b tableedit.Baseline, d tableedit.Draft) error {
	if b.Advanced == nil {
		return nil
	}
	affected := pgAdvancedDescendants(b)
	for _, column := range d.Columns {
		for id := range affected {
			node := pgAdvancedNode(b, id)
			if node.Facts == nil {
				return tableedit.ErrUnsupported
			}
			if len(node.Columns) >= tableedit.MaxColumns {
				return errors.New("Every affected descendant must remain within the complete column-proof bound.")
			}
			if _, exists := tableedit.FindColumn(node, column.Name); exists {
				return errors.New("Recursive append requires the new column name to be absent from every affected descendant; merging an existing local column needs an explicit multi-object migration.")
			}
		}
	}
	for _, change := range d.Changes {
		for id := range affected {
			node := pgAdvancedNode(b, id)
			if node.Facts == nil {
				return tableedit.ErrUnsupported
			}
			old, exists := tableedit.FindColumn(node, change.Name)
			if !exists {
				return errors.New("An affected descendant lacks the exact selected column.")
			}
			if change.RenameTo != nil {
				if _, exists := tableedit.FindColumn(node, *change.RenameTo); exists {
					return errors.New("A recursive rename destination is occupied in an affected descendant.")
				}
				if e := tableedit.CheckRename(node, change.Name); e != nil {
					return e
				}
				for parent := range pgAdvancedAncestors(b.AdvancedEvidence, id) {
					if !affected[parent] {
						ancestor := pgAdvancedNode(b, parent)
						if _, exists := tableedit.FindColumn(ancestor, change.Name); exists {
							return errors.New("This column also comes from an unselected inheritance ancestor. Rename its declaring ancestors together in an explicit multi-object migration.")
						}
					}
				}
			}
			if change.Type != nil || change.Drop {
				attrs := node.Attributes[change.Name]
				for _, part := range b.AdvancedEvidence.Rows[id+"/partition"] {
					for _, number := range pgAdvancedAttnums(part["partattrs"]) {
						if number == fmt.Sprint(attrs["attnum"]) {
							return errors.New("PostgreSQL does not permit dropping or changing the type of a partition-key column while that partition hierarchy remains attached. Review explicit partition detach/migration steps first.")
						}
					}
				}
				if change.Type != nil {
					for ancestor := range pgAdvancedAncestors(b.AdvancedEvidence, id) {
						if !affected[ancestor] {
							other := pgAdvancedNode(b, ancestor)
							if _, exists := tableedit.FindColumn(other, change.Name); exists {
								return errors.New("This inherited type also comes from an unselected ancestor; coordinated ancestor type changes require an explicit multi-object migration.")
							}
						}
					}
				}
			}
			if change.Type != nil {
				if !tableedit.CanWiden(old, *change.Type) {
					return errors.New("Every affected descendant must support the same lossless built-in widening.")
				}
				local := change
				local.RenameTo = nil
				if e := tableedit.CheckChange(node, local); e != nil {
					return e
				}
				typ, _ := tableedit.ColumnType(old)
				if e := pgConversionStorageProof(node, change.Name, typ); e != nil {
					return e
				}
			}
			if change.Generated != nil && change.Generated.Storage == "none" {
				for ancestor := range pgAdvancedAncestors(b.AdvancedEvidence, id) {
					if affected[ancestor] {
						continue
					}
					parent := pgAdvancedNode(b, ancestor)
					if column, exists := tableedit.FindColumn(parent, change.Name); exists && column.Generated.Value != nil && column.Generated.Value.Kind != "none" {
						return errors.New("An unselected declaring ancestor still requires this column to be generated. Drop its expression through that parent hierarchy; a local inherited DROP EXPRESSION is not permitted.")
					}
				}
			}
			if change.Nullable != nil && *change.Nullable {
				for ancestor := range pgAdvancedAncestors(b.AdvancedEvidence, id) {
					if affected[ancestor] {
						continue
					}
					parent := pgAdvancedNode(b, ancestor)
					if column, exists := tableedit.FindColumn(parent, change.Name); exists && column.Nullable.Value != nil && !*column.Nullable.Value {
						return errors.New("An unselected ancestor still requires NOT NULL; this local/recursive action cannot weaken that inherited constraint.")
					}
				}
			}
			if change.Drop {
				check := d
				check.Changes = []tableedit.ColumnChange{change}
				if e := tableedit.CheckDropColumn(node, check, change.Name); e != nil {
					return e
				}
			}
		}
	}
	return nil
}
func pgAdvancedRecursivePreservationError(before, after tableedit.Baseline, c tableedit.Condition) error {
	affected := pgAdvancedDescendants(before)
	if !reflect.DeepEqual(affected, pgAdvancedDescendants(after)) {
		return errors.New("The recursive hierarchy topology changed unexpectedly.")
	}
	if !reflect.DeepEqual(before.AdvancedEvidence.Targets, after.AdvancedEvidence.Targets) {
		return errors.New("The complete connected hierarchy changed unexpectedly.")
	}
	// The proof still includes unselected ancestors and siblings; compare every
	// category of those objects without operation normalization.
	for key, rows := range before.AdvancedEvidence.Rows {
		id := strings.SplitN(key, "/", 2)[0]
		if !affected[id] && !reflect.DeepEqual(rows, after.AdvancedEvidence.Rows[key]) {
			return errors.New("An unselected ancestor/sibling native property changed.")
		}
	}
	removed := map[string]bool{}
	if c.Operation.Kind == "dropColumn" {
		removed[before.Identity] = true
		for changed := true; changed; {
			changed = false
			for id := range affected {
				if removed[id] {
					continue
				}
				node := pgAdvancedNode(before, id)
				attrs := node.Attributes[c.Operation.Change.Name]
				if attrs == nil {
					return tableedit.ErrUnsupported
				}
				count := int(attrs["attinhcount"].(float64))
				for _, link := range before.AdvancedEvidence.Rows[id+"/inherits"] {
					if pgPhysicalOID(link["inhrelid"]) == id && removed[pgPhysicalOID(link["inhparent"])] {
						count--
					}
				}
				if count == 0 && attrs["attislocal"] == false {
					removed[id] = true
					changed = true
				}
			}
		}
	}
	ids := []string{}
	for id := range affected {
		ids = append(ids, id)
	}
	sort.Strings(ids)
	for _, id := range ids {
		old, next := pgAdvancedNode(before, id), pgAdvancedNode(after, id)
		if old.Facts == nil || next.Facts == nil {
			return tableedit.ErrUnsupported
		}
		condition := c
		if pgAdvancedPartitionIdentity(before, c) && id != before.Identity {
			if err := pgAdvancedInheritedIdentityPreserved(old, next, c, before, after); err != nil {
				return err
			}
			continue
		}
		if c.Operation.Kind == "addColumn" && id != before.Identity {
			attrs := next.Attributes[c.Operation.Column.Name]
			if attrs == nil {
				return errors.New("A reviewed inherited column is missing.")
			}
			count := 0
			for _, link := range before.AdvancedEvidence.Rows[id+"/inherits"] {
				if pgPhysicalOID(link["inhrelid"]) == id && affected[pgPhysicalOID(link["inhparent"])] {
					count++
				}
			}
			if attrs["attinhcount"] != float64(count) || attrs["attislocal"] != false {
				return errors.New("A new inherited column has unexpected declaring-parent/local provenance.")
			}
			next = pgAdvancedCopyAttrs(next)
			next.Attributes[c.Operation.Column.Name]["attinhcount"] = float64(0)
			next.Attributes[c.Operation.Column.Name]["attislocal"] = true
		}
		if c.Operation.Kind == "dropColumn" && !removed[id] {
			if err := pgAdvancedRetainedInheritedColumn(old, next, before.AdvancedEvidence, id, c.Operation.Change.Name, removed); err != nil {
				return err
			}
			continue
		}
		if !pgAdvancedGenerationTransition(old, next, condition, func(column sc.Column, w tableedit.Default) bool {
			return structureDefaultMatchesFacts(column, w, next.Facts)
		}) {
			return errors.New("An affected descendant typed transition did not match its reviewed column effect.")
		}
		if err := pgAdvancedLocalPreservationError(old, next, condition, before.AdvancedEvidence, after.AdvancedEvidence); err != nil {
			return err
		}
	}
	return nil
}
func pgAdvancedRetainedInheritedColumn(before, after tableedit.Baseline, whole *tableedit.AdvancedEvidence, id, name string, removed map[string]bool) error {
	a, b := tableedit.CloneAdvancedEvidence(before.AdvancedEvidence), tableedit.CloneAdvancedEvidence(after.AdvancedEvidence)
	count := int(before.Attributes[name]["attinhcount"].(float64))
	for _, link := range whole.Rows[id+"/inherits"] {
		if pgPhysicalOID(link["inhrelid"]) == id && removed[pgPhysicalOID(link["inhparent"])] {
			count--
		}
	}
	attrs := after.Attributes[name]
	if attrs == nil || attrs["attinhcount"] != float64(count) || attrs["attislocal"] != before.Attributes[name]["attislocal"] {
		return errors.New("The retained descendant column lost unexpected local/other-parent provenance.")
	}
	for _, row := range a.Rows[id+"/attributes"] {
		if row["attname"] == name {
			row["attinhcount"] = float64(count)
		}
	}
	if !reflect.DeepEqual(a.Rows, b.Rows) || !reflect.DeepEqual(before.Facts, after.Facts) {
		return errors.New("A retained multiple-inheritance column changed beyond the reviewed inheritance-count reduction.")
	}
	return nil
}
func pgAdvancedHierarchyReview(b tableedit.Baseline, d tableedit.Draft, out *tableedit.Prepared) error {
	if b.Advanced == nil {
		return nil
	}
	shape := len(d.Columns) > 0
	for _, c := range d.Changes {
		shape = shape || c.Drop || c.RenameTo != nil || c.Nullable != nil || c.Type != nil || c.Generated != nil && c.Generated.Storage == "none" || pgAdvancedPartitionIdentity(b, tableedit.Condition{Operation: tableedit.Operation{Kind: "changeColumn", Change: &c}})
	}
	if !shape {
		return nil
	}
	affected := pgAdvancedDescendants(b)
	for id := range affected {
		node := pgAdvancedNode(b, id)
		if node.Facts == nil {
			return tableedit.ErrUnsupported
		}
		identity := false
		for _, change := range d.Changes {
			identity = identity || pgAdvancedPartitionIdentity(b, tableedit.Condition{Operation: tableedit.Operation{Kind: "changeColumn", Change: &change}})
		}
		message := "The displayed parent column statement explicitly affects this exact descendant. Appends require absent names throughout the affected subtree; renames retain OID/attribute provenance; NOT NULL/type acceptance is enforced by server DDL. Local defaults remain ONLY-scoped. All unselected ancestors/siblings and all unrelated policy/type/ACL/index/trigger/native properties remain compared before COMMIT."
		if identity {
			message = "The displayed partition-root identity statement explicitly propagates its native identity mode through this affected subtree. The root owns the single sequence; no separate child sequence or row-copy is generated. Every existing identity value is compared exactly, and all unrelated descendant/sibling native properties remain checked before COMMIT."
		}
		for _, c := range d.Changes {
			if c.Drop {
				attrs := node.Attributes[c.Name]
				raw, _ := json.Marshal(map[string]any{"column": c.Name, "attributes": attrs})
				message += " Recursive DROP removes an inherited-only column when no declaring parents remain; an independently local or other-parent column remains with its exact reduced inheritance count. Current exact provenance: " + string(raw)
			}
		}
		if len(message) > 4096 {
			return errors.New("The complete descendant column-effect description exceeds the review bound.")
		}
		out.Consequences = append(out.Consequences, tableedit.Consequence{Kind: "recursiveColumns", Object: pgPhysicalName(node.Target), Message: message})
	}
	return nil
}
