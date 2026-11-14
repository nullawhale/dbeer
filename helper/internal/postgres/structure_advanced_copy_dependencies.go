package postgres

import (
	"errors"
	"fmt"
	"strings"

	"dbeer/helper/internal/tableedit"
)

// A replacement may recreate its own captured members and explicitly relink
// the captured family. Outside dependents require a separate reviewed repair.
func pgAdvancedCopyDependencyBoundary(b tableedit.Baseline, layout *pgAdvancedCopyLayout) error {
	if b.AdvancedEvidence == nil || layout == nil {
		return tableedit.ErrUnsupported
	}
	e := b.AdvancedEvidence
	removed := map[string]bool{}
	address := func(catalog, object any) string {
		c, o := pgPhysicalOID(catalog), pgPhysicalOID(object)
		if c == "" || o == "" {
			return ""
		}
		return c + "/" + o
	}
	add := func(catalog, object any, replacing bool) error {
		key := address(catalog, object)
		if key == "" {
			return errors.New("A native reconstruction member has no exact catalog-qualified object address.")
		}
		removed[key] = removed[key] || replacing
		return nil
	}
	for id := range layout.Targets {
		classes := e.Rows[id+"/class"]
		if len(classes) != 1 || pgPhysicalOID(classes[0]["oid"]) != id {
			return tableedit.ErrUnsupported
		}
		replacing := layout.Replaced[id]
		if replacing && len(e.Rows[id+"/rules"])+len(e.Rows[id+"/statistics"])+len(e.Rows[id+"/publication"]) != 0 {
			return errors.New("This client does not yet recreate rules, extended-statistics identities or publication memberships during copy. Review those objects in an explicit native migration; their captured properties are never discarded.")
		}
		if err := add("1259", id, replacing); err != nil {
			return err
		}
		rowTypeFound := false
		for _, typ := range e.Rows[id+"/types"] {
			if pgPhysicalOID(typ["oid"]) != pgPhysicalOID(classes[0]["reltype"]) {
				continue
			}
			if pgPhysicalOID(typ["typrelid"]) != id || add("1247", typ["oid"], replacing) != nil {
				return tableedit.ErrUnsupported
			}
			rowTypeFound = true
			if pgPhysicalOID(typ["typarray"]) != "" {
				if err := add("1247", typ["typarray"], replacing); err != nil {
					return err
				}
			}
		}
		if !rowTypeFound {
			return errors.New("The complete native owning row-type identity is absent from the reconstruction catalog.")
		}
		for _, member := range []struct{ category, catalog, owner string }{{"defaults", "2604", "adrelid"}, {"constraints", "2606", "conrelid"}, {"policies", "3256", "polrelid"}, {"triggers", "2620", "tgrelid"}} {
			for _, row := range e.Rows[id+"/"+member.category] {
				if pgPhysicalOID(row[member.owner]) == id {
					if err := add(member.catalog, row["oid"], replacing); err != nil {
						return err
					}
				}
			}
		}
		for _, row := range e.Rows[id+"/indexes"] {
			class, ok := row["class"].(map[string]any)
			if !ok || add("1259", class["oid"], replacing) != nil {
				return tableedit.ErrUnsupported
			}
		}
		for _, toast := range e.Rows[id+"/toast"] {
			class, ok := toast["class"].(map[string]any)
			if !ok || add("1259", class["oid"], replacing) != nil {
				return tableedit.ErrUnsupported
			}
			indexes, ok := toast["indexes"].([]any)
			if !ok {
				return tableedit.ErrUnsupported
			}
			for _, raw := range indexes {
				index, ok := raw.(map[string]any)
				if !ok {
					return tableedit.ErrUnsupported
				}
				class, ok := index["class"].(map[string]any)
				if !ok || add("1259", class["oid"], replacing) != nil {
					return tableedit.ErrUnsupported
				}
			}
		}
		for _, sequence := range e.Rows[id+"/sequences"] {
			class, ok := sequence["class"].(map[string]any)
			// Serial sequences keep their original physical identity and are
			// detached/reowned explicitly; outside users of that identity stay.
			if !ok || add("1259", class["oid"], false) != nil {
				return tableedit.ErrUnsupported
			}
		}
	}
	for changed := true; changed; {
		changed = false
		for id := range layout.Targets {
			for _, trigger := range e.Rows[id+"/triggers"] {
				key := address("2620", trigger["oid"])
				if !removed[key] && removed[address("2620", trigger["tgparentid"])] {
					removed[key], changed = true, true
				}
			}
		}
	}
	// Captured is not equivalent to recreated. These maps authorize only
	// exact native edges handled by the reviewed detach/reattach/ownership SQL.
	type indexOrigin struct {
		owner   string
		parents map[string]bool
	}
	indexes := map[string]indexOrigin{}
	constraints := map[string]map[string]any{}
	parents := map[string]map[string]bool{}
	serialEdges := map[string]bool{}
	edgeKey := func(row map[string]any) string {
		objectSlot, objectOK := pgPhysicalNumber(row["objsubid"])
		referenceSlot, referenceOK := pgPhysicalNumber(row["refobjsubid"])
		if !objectOK || !referenceOK || objectSlot != 0 || referenceSlot < 0 {
			return ""
		}
		return address(row["classid"], row["objid"]) + "/" + address(row["refclassid"], row["refobjid"]) + "/" + fmt.Sprint(referenceSlot) + "/" + fmt.Sprint(row["deptype"])
	}
	for id := range layout.Targets {
		parents[id] = map[string]bool{}
		for _, parent := range layout.Parents[id] {
			parents[id][parent] = true
		}
		for _, row := range e.Rows[id+"/indexes"] {
			cl, cok := row["class"].(map[string]any)
			ix, iok := row["index"].(map[string]any)
			links, complete := row["parents"].([]any)
			if !cok || !iok || !complete || pgPhysicalOID(ix["indrelid"]) != id || pgPhysicalOID(ix["indexrelid"]) != pgPhysicalOID(cl["oid"]) {
				return tableedit.ErrUnsupported
			}
			origin := indexOrigin{owner: id, parents: map[string]bool{}}
			for _, link := range links {
				origin.parents[pgPhysicalOID(link)] = true
			}
			indexes[pgPhysicalOID(cl["oid"])] = origin
		}
		for _, row := range e.Rows[id+"/constraints"] {
			constraints[pgPhysicalOID(row["oid"])] = row
		}
		if !layout.Replaced[id] {
			continue
		}
		for _, sequence := range e.Rows[id+"/sequences"] {
			identity, err := pgAdvancedCopySequenceOrigin(sequence, id, e.Rows[id+"/attributes"])
			if err != nil {
				return err
			}
			if identity {
				return errors.New("An identity-owned sequence cannot be detached from its native internal ownership by ALTER SEQUENCE. Recreating it changes its OID and other backends' private currval/cache state, which this table copy cannot transfer. Review a separate identity/session migration, or retain native identities with same-order reconstruction.")
			}
			dependencies, complete := pgAdvancedCopyRecordRows(sequence["dependencies"])
			if !complete {
				return tableedit.ErrUnsupported
			}
			for _, dependency := range dependencies {
				if pgPhysicalOID(dependency["classid"]) == "1259" && pgPhysicalOID(dependency["refclassid"]) == "1259" && pgPhysicalOID(dependency["refobjid"]) == id && dependency["deptype"] == "a" {
					if key := edgeKey(dependency); key != "" {
						serialEdges[key] = true
					}
				}
			}
		}
	}
	relinked := func(row map[string]any) bool {
		key := edgeKey(row)
		if key == "" {
			return false
		}
		if serialEdges[key] {
			return true
		}
		class, object := pgPhysicalOID(row["classid"]), pgPhysicalOID(row["objid"])
		refClass, reference := pgPhysicalOID(row["refclassid"]), pgPhysicalOID(row["refobjid"])
		slot, _ := pgPhysicalNumber(row["refobjsubid"])
		if slot != 0 {
			return false
		}
		if class == "1259" && refClass == "1259" {
			if rows := e.Rows[object+"/class"]; len(rows) == 1 && rows[0]["relispartition"] == true && parents[object][reference] && row["deptype"] == "a" {
				return true
			}
			child, cok := indexes[object]
			parent, pok := indexes[reference]
			return cok && pok && child.parents[reference] && parents[child.owner][parent.owner] && e.Rows[child.owner+"/class"][0]["relispartition"] == true && (row["deptype"] == "P" || row["deptype"] == "i")
		}
		if class == "2606" && refClass == "2606" && (row["deptype"] == "P" || row["deptype"] == "i") {
			child, parent := constraints[object], constraints[reference]
			if child == nil || parent == nil || pgPhysicalOID(child["conparentid"]) != reference || child["contype"] != parent["contype"] || child["contype"] != "p" && child["contype"] != "u" && child["contype"] != "n" {
				return false
			}
			owner, ancestor := pgPhysicalOID(child["conrelid"]), pgPhysicalOID(parent["conrelid"])
			return parents[owner][ancestor] && e.Rows[owner+"/class"][0]["relispartition"] == true
		}
		return false
	}
	for key, rows := range e.Rows {
		if !strings.HasSuffix(key, "/dependencies") {
			continue
		}
		for _, row := range rows {
			object, reference := address(row["classid"], row["objid"]), address(row["refclassid"], row["refobjid"])
			if object == "" || reference == "" {
				return errors.New("A captured native dependency address is incomplete.")
			}
			if removed[object] && row["deptype"] == "e" {
				return errors.New("This client does not recreate extension-owned members during copy. Review the owning extension's explicit native migration.")
			}
			if removed[reference] && !removed[object] && !relinked(row) {
				return errors.New("This client does not yet reconstruct an outside object depending on a replacement relation, row type, index or native member. Select a supported explicit foreign-key repair, or review that object's native migration separately; no outside object is removed automatically.")
			}
		}
	}
	return nil
}
