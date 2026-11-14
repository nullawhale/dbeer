package postgres

import (
	"context"
	"dbeer/helper/internal/tableedit"
	"errors"
	"sort"
	"strconv"
)

// Conditions are already bound into the one-use plan digest. Keep the trusted
// support closure from Preview separate from the Apply-only row snapshots.
func pgAdvancedBindData(ctx context.Context, q structureReader, b tableedit.Baseline, p *tableedit.Prepared) error {
	q = pgCatalogReader(q)
	if b.Advanced == nil {
		return nil
	}
	needed := p.Reconstruction != nil && p.Reconstruction.Method == "postgresql-native-cluster"
	roots := map[uint32]bool{}
	for _, id := range pgAdvancedDataTypes(b) {
		roots[id] = true
	}
	for _, condition := range p.Conditions {
		needed = needed || pgAdvancedDataOperation(condition.Operation)
		if column := condition.Operation.Column; column != nil {
			var id uint64
			var err error
			if column.Resolved != nil {
				id, err = strconv.ParseUint(column.Resolved.Identity, 10, 32)
			} else {
				id = map[string]uint64{"integer": 23, "bigint": 20, "boolean": 16, "text": 25, "varchar": 1043, "numeric": 1700}[column.Type.Kind]
			}
			if err != nil || id == 0 {
				return tableedit.ErrUnsupported
			}
			roots[uint32(id)] = true
		}
	}
	if !needed {
		return nil
	}
	types := []uint32{}
	for id := range roots {
		types = append(types, id)
	}
	sort.Slice(types, func(i, j int) bool { return types[i] < types[j] })
	fingerprint, err := pgAdvancedBinaryTypes(ctx, q, types)
	if err != nil {
		return err
	}
	for i := range p.Conditions {
		if pgAdvancedDataOperation(p.Conditions[i].Operation) {
			p.Conditions[i].AdvancedDataTypes = append([]uint32(nil), types...)
			p.Conditions[i].AdvancedDataProof = fingerprint
		}
	}
	if p.Reconstruction != nil && p.Reconstruction.Method == "postgresql-native-cluster" {
		p.Reconstruction.AdvancedDataTypes = append([]uint32(nil), types...)
		p.Reconstruction.AdvancedDataProof = fingerprint
	}
	return nil
}
func pgAdvancedBoundDataCapture(ctx context.Context, q structureReader, b tableedit.Baseline, c tableedit.Condition) (*pgAdvancedDataProof, error) {
	q = pgCatalogReader(q)
	if b.Advanced == nil || !pgAdvancedDataOperation(c.Operation) {
		return nil, nil
	}
	if c.AdvancedDataProof == "" || len(c.AdvancedDataTypes) == 0 {
		return nil, errors.New("The exact trusted native support closure is not bound to this reviewed data-moving condition.")
	}
	current, err := pgAdvancedBinaryTypes(ctx, q, c.AdvancedDataTypes)
	if err != nil || current != c.AdvancedDataProof {
		return nil, errors.New("Native type/send support changed since Preview; no data-moving statement was sent.")
	}
	return pgAdvancedDataCapture(ctx, q, b, c)
}
