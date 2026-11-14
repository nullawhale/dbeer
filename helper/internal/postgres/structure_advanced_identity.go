package postgres

import (
	sc "dbeer/helper/internal/schemacompare"
	"dbeer/helper/internal/tableedit"
	"errors"
	"reflect"
)

func pgAdvancedPartitionIdentity(b tableedit.Baseline, c tableedit.Condition) bool {
	return b.Advanced != nil && b.AdvancedEvidence != nil && b.Facts != nil && b.Facts.ServerVersion >= 170000 && b.Facts.Table.Kind.Value != nil && *b.Facts.Table.Kind.Value == "p" && len(b.AdvancedEvidence.Rows[b.Identity+"/class"]) == 1 && b.AdvancedEvidence.Rows[b.Identity+"/class"][0]["relispartition"] == false && c.Operation.Kind == "changeColumn" && c.Operation.Change != nil && c.Operation.Change.Identity != nil
}

// A native partition root owns the sequence. Descendants can receive its mode
// without acquiring a second owned sequence; every other child property stays exact.
func pgAdvancedInheritedIdentityPreserved(before, after tableedit.Baseline, c tableedit.Condition, rootBefore, rootAfter tableedit.Baseline) error {
	if !pgAdvancedPartitionIdentity(rootBefore, c) || c.Operation.Change == nil || c.Operation.Change.Identity == nil || before.Identity == rootBefore.Identity {
		return tableedit.ErrUnsupported
	}
	name := c.Operation.Change.Name
	if len(before.AdvancedEvidence.Rows[before.Identity+"/class"]) != 1 || before.AdvancedEvidence.Rows[before.Identity+"/class"][0]["relispartition"] != true {
		return errors.New("Identity propagation requires an exactly captured native partition member.")
	}
	old, ok := tableedit.FindColumn(before, name)
	next, exists := tableedit.FindColumn(after, name)
	if !ok || !exists || old.Identity.Value == nil || next.Identity.Value == nil || old.Identity.Value.Sequence != nil || next.Identity.Value.Sequence != nil {
		return errors.New("A partition member has an unexpected local identity sequence binding.")
	}
	for _, node := range []tableedit.Baseline{before, after} {
		for _, row := range node.AdvancedEvidence.Rows[node.Identity+"/sequences"] {
			if row["column"] == name {
				return errors.New("The inherited identity unexpectedly acquired a separately owned child sequence.")
			}
		}
	}
	a, b := tableedit.CloneAdvancedEvidence(before.AdvancedEvidence), tableedit.CloneAdvancedEvidence(after.AdvancedEvidence)
	oldMode, newMode := before.Attributes[name]["attidentity"], after.Attributes[name]["attidentity"]
	if !reflect.DeepEqual(oldMode, newMode) {
		want := map[string]string{"none": "", "always": "a", "byDefault": "d"}[c.Operation.Change.Identity.Kind]
		if newMode != want || newMode != rootAfter.Attributes[name]["attidentity"] || next.Identity.Value.Kind != c.Operation.Change.Identity.Kind || next.Identity.State != "known" || next.Identity.Code != "" {
			return errors.New("A partition identity mode differs from its exact reviewed root mode.")
		}
		expected := sc.Known(sc.Identity{Kind: c.Operation.Change.Identity.Kind})
		if !reflect.DeepEqual(next.Identity, expected) {
			return errors.New("An inherited identity has unexpected extra typed properties.")
		}
		for _, row := range a.Rows[before.Identity+"/attributes"] {
			if row["attname"] == name {
				row["attidentity"] = want
			}
		}
		for i := range a.Facts[before.Identity].Table.Columns.Items {
			column := &a.Facts[before.Identity].Table.Columns.Items[i]
			if column.Ref.Name == name {
				column.Identity = expected
			}
		}
	}
	if !reflect.DeepEqual(a, b) {
		return errors.New("A descendant changed beyond the exact inherited identity mode; all native properties remain required.")
	}
	return nil
}
