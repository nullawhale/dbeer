package postgres

import (
	"context"
	"errors"
	"reflect"
	"sort"

	"dbeer/helper/internal/tableedit"
)

func pgAdvancedMigrationForeignUnit(conditions []tableedit.Condition) bool {
	return len(conditions) == 1 && pgAdvancedForeignCondition(conditions[0])
}

func pgAdvancedMigrationBaseline(values []tableedit.Baseline, target tableedit.Target) (tableedit.Baseline, error) {
	for _, b := range values {
		if b.Target == target {
			return b, nil
		}
	}
	return tableedit.Baseline{}, tableedit.ErrStale
}
func pgAdvancedMigrationRowsEqual(a, b []map[string]any) bool {
	if len(a) != len(b) || (a == nil) != (b == nil) {
		return false
	}
	left, right := []string{}, []string{}
	for _, row := range a {
		left = append(left, pgAdvancedCopyJSON(row))
	}
	for _, row := range b {
		right = append(right, pgAdvancedCopyJSON(row))
	}
	sort.Strings(left)
	sort.Strings(right)
	return reflect.DeepEqual(left, right)
}

// Every catalog row carried by an observed public baseline must belong to the
// independently proved complete native checkpoint, including unknown fields.
func pgAdvancedMigrationEvidenceCovers(b tableedit.Baseline, e *tableedit.AdvancedEvidence) bool {
	if e == nil || e.Facts[b.Identity] == nil || e.Facts[b.Identity].Table.Ref.Schema != b.Target.Schema || e.Facts[b.Identity].Table.Ref.Name != b.Target.Table {
		return false
	}
	if b.AdvancedEvidence == nil {
		return reflect.DeepEqual(b.Facts, e.Facts[b.Identity])
	}
	for key, rows := range b.AdvancedEvidence.Rows {
		expected, exists := e.Rows[key]
		if !exists || !pgAdvancedMigrationRowsEqual(rows, expected) {
			return false
		}
	}
	return true
}

func (s *Session) StructureMigrationCheckpoint(ctx context.Context, c tableedit.MigrationCheckpoint) ([]tableedit.Target, error) {
	before, err := pgAdvancedMigrationBaseline(c.Before, c.Target)
	if err != nil {
		return nil, err
	}
	after, err := pgAdvancedMigrationBaseline(c.After, c.Target)
	if err != nil {
		return nil, err
	}
	var proof *tableedit.AdvancedEvidence
	switch {
	case c.Plan.Reconstruction != nil && c.Plan.Reconstruction.Method == "postgresql-advanced-copy":
		checkpoint, err := s.pgAdvancedCopyConsumeCheckpoint(c.Plan)
		if err != nil {
			return nil, err
		}
		family, combined, err := s.pgAdvancedCopyObserveCheckpoint(ctx, after, checkpoint)
		if err != nil {
			return nil, err
		}
		if err = pgAdvancedCopyCheckpointPreserved(checkpoint, family, combined); err != nil {
			return nil, err
		}
		proof = combined.AdvancedEvidence
	case c.Plan.Reconstruction != nil && c.Plan.Reconstruction.Method == "postgresql-native-cluster":
		if !pgAdvancedReconstructionPreserved(before, after, c.Plan.Reconstruction.ColumnOrder) {
			return nil, tableedit.ErrStale
		}
		proof = after.AdvancedEvidence
	case pgAdvancedMigrationForeignUnit(c.Plan.Conditions) && c.Plan.AdvancedProof != nil:
		refs := []tableedit.Baseline{}
		for _, old := range c.Plan.References {
			ref, err := pgAdvancedMigrationBaseline(c.After, old.Target)
			if err != nil {
				return nil, err
			}
			refs = append(refs, ref)
		}
		proof, err = pgAdvancedCombined(ctx, s.conn, after, refs)
		if err != nil {
			return nil, err
		}
		if err = pgAdvancedForeignPreservationError(before, after, c.Plan.Conditions[0], c.Plan.AdvancedProof, proof); err != nil {
			return nil, err
		}
	default:
		return nil, tableedit.ErrUnsupported
	}
	covered := []tableedit.Target{}
	for _, b := range c.After {
		if pgAdvancedMigrationEvidenceCovers(b, proof) {
			covered = append(covered, b.Target)
		}
	}
	return covered, nil
}

func (s *Session) StructureBindMigrationCheckpoint(ctx context.Context, b tableedit.Baseline, p tableedit.Plan, d tableedit.Draft, load func(tableedit.Target) (tableedit.Baseline, error)) (tableedit.Plan, error) {
	if p.AdvancedProof == nil || !pgAdvancedMigrationForeignUnit(p.Conditions) || p.Reconstruction != nil || len(d.Keys) != 1 || len(d.Columns)+len(d.Changes)+len(d.Indexes) != 0 {
		return p, tableedit.ErrUnsupported
	}
	observed, err := s.StructurePrepareMigration(ctx, b, d, load)
	if err != nil {
		return p, err
	}
	if observed.AdvancedProof == nil || !reflect.DeepEqual(observed.SQL, p.SQL) || !reflect.DeepEqual(observed.Conditions, p.Conditions) || !reflect.DeepEqual(observed.Types, p.Types) || !reflect.DeepEqual(observed.IndexGuards, p.IndexGuards) || !reflect.DeepEqual(observed.ResultTarget, p.ResultTarget) || observed.DroppedTarget != p.DroppedTarget || !reflect.DeepEqual(observed.Risks, p.Risks) || !reflect.DeepEqual(observed.Consequences, p.Consequences) || !reflect.DeepEqual(observed.ValidationChecks, p.ValidationChecks) || !reflect.DeepEqual(observed.AdvancedProof.Targets, p.AdvancedProof.Targets) {
		return p, errors.New("The acknowledged checkpoint requires a different reviewed foreign-key unit.")
	}
	// Only the independently verified native observation advances. The retained
	// original plan ID/digest, SQL, conditions and references remain unchanged.
	p.AdvancedProof = observed.AdvancedProof
	return p, nil
}
