package postgres

import (
	"context"
	"errors"
	"fmt"
	"reflect"
	"sort"
	"strings"

	sc "dbeer/helper/internal/schemacompare"
	"dbeer/helper/internal/tableedit"
)

func pgAdvancedCopyRepairLoad(ctx context.Context, q structureReader, target tableedit.Target) (tableedit.Baseline, error) {
	b, err := readStructure(ctx, q, target)
	if err != nil {
		return b, err
	}
	if b.AdvancedEvidence == nil {
		b.AdvancedEvidence, err = pgAdvancedRaw(ctx, q, target)
		if err != nil {
			return b, err
		}
	}
	if err = pgAdvancedCopyMetadata(ctx, q, &b); err != nil {
		return b, err
	}
	return b, nil
}

func pgAdvancedCopyRepairCapture(ctx context.Context, q structureReader, b tableedit.Baseline, repairs []pgAdvancedCopyRepair) (tableedit.Baseline, error) {
	if len(repairs) == 0 {
		return b, nil
	}
	withCoverage := func(value tableedit.Baseline) (tableedit.Baseline, error) {
		value.AdvancedEvidence = tableedit.CloneAdvancedEvidence(value.AdvancedEvidence)
		for id := range value.AdvancedEvidence.Facts {
			triggers, present := value.AdvancedEvidence.Rows[id+"/triggers"]
			var count int64
			if !present || triggers == nil || pgCatalogReader(q).QueryRow(ctx, `SELECT pg_catalog.count(*) FROM pg_catalog.pg_trigger WHERE tgrelid=$1::pg_catalog.oid`, id).Scan(&count) != nil || count < 0 || count > 2048 || int(count) != len(triggers) {
				return value, errors.New("The complete all-trigger catalog, including native/internal triggers, could not be proved for a selected repair.")
			}
			value.AdvancedEvidence.Rows[id+"/copyTriggerCoverage"] = []map[string]any{{"catalog": "pg_catalog.pg_trigger", "allRows": true, "count": float64(count)}}
		}
		return value, nil
	}
	var err error
	b, err = withCoverage(b)
	if err != nil {
		return b, err
	}
	seen := map[tableedit.Target]bool{b.Target: true}
	refs := []tableedit.Baseline{}
	for _, repair := range repairs {
		if seen[repair.Source] {
			continue
		}
		seen[repair.Source] = true
		ref, err := pgAdvancedCopyRepairLoad(ctx, q, repair.Source)
		if err != nil {
			return b, err
		}
		ref, err = withCoverage(ref)
		if err != nil {
			return b, err
		}
		refs = append(refs, ref)
	}
	proof, err := pgAdvancedCombined(ctx, q, b, refs)
	if err != nil {
		return b, err
	}
	b.AdvancedEvidence = proof
	return b, nil
}

func pgAdvancedCopyPrepareRepairs(ctx context.Context, q structureReader, b tableedit.Baseline, order []string, originalPath string, load func(tableedit.Target) (tableedit.Baseline, error)) (tableedit.Baseline, tableedit.Baseline, []pgAdvancedCopyRepair, *tableedit.AdvancedEvidence, error) {
	layout, err := pgAdvancedCopyGraph(b, order)
	if err != nil {
		return b, b, nil, nil, err
	}
	repairs := []pgAdvancedCopyRepair{}
	seen := map[string]bool{}
	originals, projections := map[tableedit.Target]tableedit.Baseline{}, map[tableedit.Target]tableedit.Baseline{}
	for _, id := range layout.CreateOrder {
		facts := b.AdvancedEvidence.Facts[id]
		if facts == nil {
			return b, b, nil, nil, tableedit.ErrUnsupported
		}
		for _, incoming := range facts.Incoming {
			if load == nil {
				return b, b, nil, nil, errors.New("An incoming foreign key requires its individually selected removal and restoration in the existing migration workflow; this copy plan never removes an outside key automatically.")
			}
			source := tableedit.Target{Schema: incoming.Schema, Table: incoming.Table}
			projected, e := load(source)
			if e != nil || projected.Target != source {
				return b, b, nil, nil, errors.New("Every selected incoming-key owner must be captured by this migration before copy planning.")
			}
			for _, key := range projected.Keys {
				if key.Name == incoming.Name {
					return b, b, nil, nil, errors.New("An unselected incoming foreign key still references a replacement relation; select its explicit repair before Preview.")
				}
			}
			original, e := pgAdvancedCopyRepairLoad(ctx, q, source)
			// Metadata is currently interpreted under the reviewed fixed path.
			// Bind the loader's original scope using observed physical database,
			// role and namespace plus the path observed before that local switch.
			var environment string
			var schemaOID uint32
			scopeError := pgCatalogReader(q).QueryRow(ctx, `SELECT n.oid,pg_catalog.current_database() || ':' || pg_catalog.current_setting('server_version_num') || ':' || pg_catalog.current_setting('server_encoding') || ':' || current_user || ':' || $2::pg_catalog.text || ':' || pg_catalog.current_setting('standard_conforming_strings') FROM pg_catalog.pg_namespace n WHERE n.nspname=$1`, source.Schema, originalPath).Scan(&schemaOID, &environment)
			if e != nil || scopeError != nil || original.Identity != projected.Identity || tableedit.Fingerprint([]any{environment, schemaOID}) != projected.Scope || original.Guard != projected.Guard || !reflect.DeepEqual(original.Attributes, projected.Attributes) || !reflect.DeepEqual(original.Columns, projected.Columns) || !reflect.DeepEqual(original.Indexes, projected.Indexes) {
				return b, b, nil, nil, errors.New("The selected foreign-key repair owner has other projected identity, column or index changes; split those changes into a separately reviewed migration.")
			}
			originals[source], projections[source] = original, projected
			var root map[string]any
			for _, row := range original.AdvancedEvidence.Rows[original.Identity+"/constraints"] {
				if row["contype"] == "f" && row["conname"] == incoming.Name && pgPhysicalOID(row["conrelid"]) == original.Identity && pgPhysicalOID(row["confrelid"]) == id && pgPhysicalOID(row["conparentid"]) == "" {
					if root != nil {
						return b, b, nil, nil, tableedit.ErrUnsupported
					}
					root = row
				}
			}
			if root == nil {
				return b, b, nil, nil, errors.New("A selected incoming key has no exact captured native root; inherited or auxiliary keys need their explicit declaring-owner repair.")
			}
			constraintID := pgPhysicalOID(root["oid"])
			if !seen[constraintID] {
				seen[constraintID] = true
				repairs = append(repairs, pgAdvancedCopyRepair{Source: source, SourceID: original.Identity, ConstraintID: constraintID, Name: incoming.Name, ReferenceID: id})
			}
		}
	}
	if len(repairs) > 16 {
		return b, b, nil, nil, errors.New("The copy migration supports at most sixteen individually selected foreign-key roots.")
	}
	selected := map[string]bool{}
	for _, repair := range repairs {
		selected[repair.Source.Schema+"\x00"+repair.Source.Table+"\x00"+repair.Name] = true
	}
	for target, original := range originals {
		projected := projections[target]
		expectedKeys := []tableedit.Key{}
		for _, key := range original.Keys {
			if !selected[target.Schema+"\x00"+target.Table+"\x00"+key.Name] {
				expectedKeys = append(expectedKeys, key)
			}
		}
		if !reflect.DeepEqual(expectedKeys, projected.Keys) || original.Facts == nil || projected.Facts == nil {
			return b, b, nil, nil, errors.New("The selected repair owner has other projected key changes; split those changes before this copy migration.")
		}
		expectedFacts := tableedit.CloneAdvancedEvidence(&tableedit.AdvancedEvidence{Facts: map[string]*tableedit.Facts{original.Identity: original.Facts}}).Facts
		pgAdvancedCopyRepairFilterFacts(expectedFacts, selected)
		actualFacts := tableedit.CloneAdvancedEvidence(&tableedit.AdvancedEvidence{Facts: map[string]*tableedit.Facts{original.Identity: projected.Facts}}).Facts[original.Identity]
		actualFacts.Incoming = append([]tableedit.Incoming{}, actualFacts.Incoming...)
		if !reflect.DeepEqual(expectedFacts[original.Identity], actualFacts) {
			return b, b, nil, nil, errors.New("The selected repair owner has other projected typed-property changes; split those changes before this copy migration.")
		}
	}
	sort.Slice(repairs, func(i, j int) bool {
		return repairs[i].Source.Schema+"\x00"+repairs[i].Source.Table+"\x00"+repairs[i].Name < repairs[j].Source.Schema+"\x00"+repairs[j].Source.Table+"\x00"+repairs[j].Name
	})
	if len(repairs) == 0 {
		return b, b, nil, nil, nil
	}
	observed, err := pgAdvancedCopyRepairCapture(ctx, q, b, repairs)
	if err != nil {
		return b, b, nil, nil, err
	}
	expectedProof, _, err := pgAdvancedCopyRepairExpected(observed.AdvancedEvidence, repairs)
	if err != nil {
		return b, b, nil, nil, err
	}
	expected := b
	expected.AdvancedEvidence = tableedit.CloneAdvancedEvidence(b.AdvancedEvidence)
	for key := range expected.AdvancedEvidence.Rows {
		rows, ok := expectedProof.Rows[key]
		if !ok {
			return b, b, nil, nil, tableedit.ErrUnsupported
		}
		expected.AdvancedEvidence.Rows[key] = rows
	}
	for id := range expected.AdvancedEvidence.Facts {
		expected.AdvancedEvidence.Facts[id] = expectedProof.Facts[id]
	}
	expected.Facts = expected.AdvancedEvidence.Facts[expected.Identity]
	expected.Keys = append([]tableedit.Key(nil), b.Keys...)
	for _, repair := range repairs {
		if repair.SourceID == expected.Identity {
			keys := []tableedit.Key{}
			for _, key := range expected.Keys {
				if key.Name != repair.Name {
					keys = append(keys, key)
				}
			}
			expected.Keys = keys
		}
	}
	return b, expected, repairs, observed.AdvancedEvidence, nil
}

func pgAdvancedCopyRepairExpected(before *tableedit.AdvancedEvidence, repairs []pgAdvancedCopyRepair) (*tableedit.AdvancedEvidence, map[string]bool, error) {
	if before == nil || len(repairs) > 16 {
		return nil, nil, tableedit.ErrUnsupported
	}
	proof := tableedit.CloneAdvancedEvidence(before)
	if len(repairs) == 0 {
		return proof, map[string]bool{}, nil
	}
	constraints := map[string]map[string]any{}
	for key, rows := range before.Rows {
		if strings.HasSuffix(key, "/constraints") {
			for _, row := range rows {
				id := pgPhysicalOID(row["oid"])
				if old, ok := constraints[id]; id == "" || ok && !reflect.DeepEqual(old, row) {
					return nil, nil, errors.New("The selected-key catalog contains an inconsistent constraint identity.")
				}
				constraints[id] = row
			}
		}
	}
	affected := map[string]bool{}
	for _, repair := range repairs {
		row := constraints[repair.ConstraintID]
		facts := before.Facts[repair.SourceID]
		if !repair.Source.Valid() || repair.Source.Create || !tableedit.Identifier(repair.Name) || row == nil || facts == nil || facts.Table.Ref.Schema != repair.Source.Schema || facts.Table.Ref.Name != repair.Source.Table || row["contype"] != "f" || row["conname"] != repair.Name || pgPhysicalOID(row["conrelid"]) != repair.SourceID || pgPhysicalOID(row["confrelid"]) != repair.ReferenceID || pgPhysicalOID(row["conparentid"]) != "" || affected[repair.ConstraintID] {
			return nil, nil, errors.New("A selected foreign-key removal has no unique exact captured source/reference root.")
		}
		if row["condeferrable"] != false || row["condeferred"] != false || row["convalidated"] != true || row["confmatchtype"] != "s" || row["conislocal"] != true || row["conenforced"] == false {
			return nil, nil, errors.New("The selected foreign key has native semantics outside the existing summarized repair editor; review its explicit native migration.")
		}
		affected[repair.ConstraintID] = true
	}
	for changed := true; changed; {
		changed = false
		for id, row := range constraints {
			if !affected[id] && affected[pgPhysicalOID(row["conparentid"])] {
				affected[id], changed = true, true
			}
		}
	}
	triggers, triggerRelations := map[string]bool{}, map[string]bool{}
	for key, rows := range before.Rows {
		if strings.HasSuffix(key, "/triggers") {
			for _, row := range rows {
				if affected[pgPhysicalOID(row["tgconstraint"])] {
					triggers[pgPhysicalOID(row["oid"])], triggerRelations[pgPhysicalOID(row["tgrelid"])] = true, true
				}
			}
		}
	}
	selectedAddress := func(catalog, object any) bool {
		return fmt.Sprint(catalog) == "2606" && affected[pgPhysicalOID(object)] || fmt.Sprint(catalog) == "2620" && triggers[pgPhysicalOID(object)]
	}
	for key, rows := range proof.Rows {
		var out []map[string]any
		if rows != nil {
			out = make([]map[string]any, 0, len(rows))
		}
		for _, row := range rows {
			remove := false
			switch {
			case strings.HasSuffix(key, "/constraints"):
				remove = affected[pgPhysicalOID(row["oid"])]
			case strings.HasSuffix(key, "/triggers"):
				remove = triggers[pgPhysicalOID(row["oid"])]
			case strings.HasSuffix(key, "/dependencies"):
				remove = selectedAddress(row["classid"], row["objid"]) || selectedAddress(row["refclassid"], row["refobjid"])
			case strings.HasSuffix(key, "/comments"), strings.HasSuffix(key, "/labels"):
				if selectedAddress(row["classoid"], row["objoid"]) {
					return nil, nil, errors.New("The selected foreign-key repair has native comments or security labels that the summarized repair editor does not restore; review a native property-preserving repair first.")
				}
			}
			if !remove {
				out = append(out, row)
			}
		}
		proof.Rows[key] = out
	}
	for id := range triggerRelations {
		coverage := proof.Rows[id+"/copyTriggerCoverage"]
		if coverage != nil {
			if len(coverage) != 1 || coverage[0]["catalog"] != "pg_catalog.pg_trigger" || coverage[0]["allRows"] != true || coverage[0]["count"] != float64(len(before.Rows[id+"/triggers"])) {
				return nil, nil, errors.New("The selected removal's complete all-trigger coverage is inconsistent.")
			}
			coverage[0]["count"] = float64(len(proof.Rows[id+"/triggers"]))
		}
	}
	selectedFacts := map[string]bool{}
	for id := range affected {
		row := constraints[id]
		facts := proof.Facts[pgPhysicalOID(row["conrelid"])]
		if facts == nil || proof.Facts[pgPhysicalOID(row["confrelid"])] == nil {
			return nil, nil, errors.New("A selected foreign-key endpoint is outside the complete bounded repair graph.")
		}
		selectedFacts[facts.Table.Ref.Schema+"\x00"+facts.Table.Ref.Name+"\x00"+fmt.Sprint(row["conname"])] = true
	}
	pgAdvancedCopyRepairFilterFacts(proof.Facts, selectedFacts)
	return proof, triggerRelations, nil
}

func pgAdvancedCopyRepairFilterFacts(all map[string]*tableedit.Facts, selectedFacts map[string]bool) {
	for _, facts := range all {
		keys := []sc.Constraint{}
		for _, key := range facts.Table.Constraints.Items {
			if !selectedFacts[key.Ref.Schema+"\x00"+key.Ref.Table+"\x00"+key.Ref.Name] {
				keys = append(keys, key)
			}
		}
		facts.Table.Constraints.Items = keys
		incoming := []tableedit.Incoming{}
		for _, key := range facts.Incoming {
			if !selectedFacts[key.Schema+"\x00"+key.Table+"\x00"+key.Name] {
				incoming = append(incoming, key)
			}
		}
		facts.Incoming = incoming
		facts.Table.Dependencies = sc.DerivedDependencies(facts.Table)
	}
}

func pgAdvancedCopyRepairsPreserved(before, after *tableedit.AdvancedEvidence, repairs []pgAdvancedCopyRepair) error {
	expected, triggerRelations, err := pgAdvancedCopyRepairExpected(before, repairs)
	if err != nil || after == nil {
		return errors.New("The reviewed selected foreign-key removal proof is incomplete.")
	}
	actual := tableedit.CloneAdvancedEvidence(after)
	for _, facts := range actual.Facts {
		facts.Incoming = append([]tableedit.Incoming{}, facts.Incoming...)
		facts.Table.Constraints.Items = append([]sc.Constraint{}, facts.Table.Constraints.Items...)
		// This field is derived typed intent. The complete native dependency
		// rows remain independently compared with only selected removals.
		facts.Table.Dependencies = sc.DerivedDependencies(facts.Table)
	}
	for id := range triggerRelations {
		if len(expected.Rows[id+"/class"]) != 1 || len(actual.Rows[id+"/class"]) != 1 {
			return tableedit.ErrStale
		}
		left, right := expected.Rows[id+"/class"][0], actual.Rows[id+"/class"][0]
		// relhastriggers is a one-way catalog hint and can remain true after
		// the last trigger is dropped. Complete trigger records stay exact.
		if left["relhastriggers"] != true || right["relhastriggers"] != true && (right["relhastriggers"] != false || len(actual.Rows[id+"/triggers"]) != 0) {
			return errors.New("A selected-key endpoint has an inconsistent native trigger hint.")
		}
		delete(left, "relhastriggers")
		delete(right, "relhastriggers")
	}
	if !reflect.DeepEqual(expected.Targets, actual.Targets) || !reflect.DeepEqual(expected.Facts, actual.Facts) {
		return errors.New("An unaffected selected-repair typed fact or captured target changed.")
	}
	if len(expected.Rows) != len(actual.Rows) {
		return errors.New("An unaffected selected-repair native category changed.")
	}
	for key, rows := range expected.Rows {
		actualRows, present := actual.Rows[key]
		if !present || !reflect.DeepEqual(rows, actualRows) {
			return fmt.Errorf("An unaffected selected-repair native %s property changed.", key[strings.LastIndex(key, "/")+1:])
		}
	}
	return nil
}

func pgAdvancedCopyRepairOwnersPreserved(before, after, beforeFamily, afterFamily *tableedit.AdvancedEvidence) error {
	if before == nil || after == nil || beforeFamily == nil || afterFamily == nil {
		return tableedit.ErrUnsupported
	}
	outside := func(all, family *tableedit.AdvancedEvidence) *tableedit.AdvancedEvidence {
		out := tableedit.CloneAdvancedEvidence(all)
		for id := range family.Facts {
			delete(out.Facts, id)
		}
		for key := range out.Rows {
			id, _, ok := strings.Cut(key, "/")
			if ok && family.Facts[id] != nil {
				delete(out.Rows, key)
			}
		}
		targets := map[tableedit.Target]bool{}
		for _, target := range family.Targets {
			targets[target] = true
		}
		out.Targets = []tableedit.Target{}
		for _, target := range all.Targets {
			if !targets[target] {
				out.Targets = append(out.Targets, target)
			}
		}
		return out
	}
	if !reflect.DeepEqual(outside(before, beforeFamily), outside(after, afterFamily)) {
		return errors.New("An untouched selected-repair owner's complete native/typed catalog changed during copy.")
	}
	return nil
}

func pgAdvancedCopyRepairPropertiesPreserved(before, after, combinedBefore, combinedAfter tableedit.Baseline, orders map[string][]string, replaced map[string]bool) error {
	if before.AdvancedEvidence == nil || after.AdvancedEvidence == nil || combinedBefore.AdvancedEvidence == nil || combinedAfter.AdvancedEvidence == nil {
		return tableedit.ErrUnsupported
	}
	left, err := pgAdvancedCopyTargets(before.AdvancedEvidence)
	if err != nil {
		return err
	}
	right, err := pgAdvancedCopyTargets(after.AdvancedEvidence)
	if err != nil {
		return err
	}
	comparison := before
	comparison.AdvancedEvidence = tableedit.CloneAdvancedEvidence(before.AdvancedEvidence)
	completeEmpty := func(family, combined *tableedit.AdvancedEvidence, id string) bool {
		rows, present := family.Rows[id+"/triggers"]
		all, captured := combined.Rows[id+"/triggers"]
		coverage, proved := combined.Rows[id+"/copyTriggerCoverage"]
		return present && captured && proved && rows != nil && all != nil && len(rows) == 0 && len(all) == 0 && len(coverage) == 1 && len(coverage[0]) == 3 && coverage[0]["catalog"] == "pg_catalog.pg_trigger" && coverage[0]["allRows"] == true && coverage[0]["count"] == float64(0)
	}
	for target, id := range left {
		next, paired := right[target]
		if !paired || len(before.AdvancedEvidence.Rows[id+"/class"]) != 1 || len(after.AdvancedEvidence.Rows[next+"/class"]) != 1 {
			return tableedit.ErrUnsupported
		}
		oldClass, newClass := before.AdvancedEvidence.Rows[id+"/class"][0], after.AdvancedEvidence.Rows[next+"/class"][0]
		if oldClass["relhastriggers"] != true || newClass["relhastriggers"] != false {
			continue
		}
		if !replaced[id] || id == next || pgPhysicalOID(oldClass["oid"]) != id || pgPhysicalOID(newClass["oid"]) != next || !completeEmpty(before.AdvancedEvidence, combinedBefore.AdvancedEvidence, id) || !completeEmpty(after.AdvancedEvidence, combinedAfter.AdvancedEvidence, next) {
			return errors.New("A changed native trigger hint lacks a new reviewed relation and complete empty all-trigger catalogs.")
		}
		oldRelation, newRelation := pgAdvancedRelation(id+"/", before.AdvancedEvidence), pgAdvancedRelation(next+"/", after.AdvancedEvidence)
		if _, complete := pgPhysicalAttributeMap(oldRelation, newRelation); !complete || !pgAdvancedCopyOrder(oldRelation.Columns, newRelation.Columns, orders[id], true) {
			return errors.New("The trigger-hint reset has no exact named native column-layout origin.")
		}
		// PostgreSQL's hint records has-or-once-had triggers. A newly created
		// relation with a proved complete empty catalog clears a stale true.
		comparison.AdvancedEvidence.Rows[id+"/class"][0]["relhastriggers"] = false
	}
	return pgAdvancedCopyPreservationError(comparison, after, orders, replaced)
}
