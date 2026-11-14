package sqlite

import (
	"context"
	"dbeer/helper/internal/tableedit"
	"reflect"
	"strings"
)

// Compare the complete retained schema, not just the selected table's local
// indexes: incoming references and unrelated triggers must remain unchanged.
func (s *Session) verifyReconstructionSchema(ctx context.Context, b tableedit.Baseline, p tableedit.Plan, before []structureSchemaRow, sequence string) bool {
	proof := p.Reconstruction
	if proof == nil {
		return false
	}
	after, err := s.structureSchema(ctx, false)
	if err != nil {
		return false
	}
	strip := func(rows []structureSchemaRow) []structureSchemaRow {
		out := []structureSchemaRow{}
		for _, r := range rows {
			if r.Kind == "table" && r.Name == b.Target.Table {
				continue
			}
			r.SQL = strings.TrimSuffix(strings.TrimSpace(r.SQL), ";")
			out = append(out, r)
		}
		return out
	}
	if !reflect.DeepEqual(strip(before), strip(after)) {
		return false
	}
	expected, err := parseDDLTable(proof.ExpectedDefinition)
	if err != nil {
		return false
	}
	actualRaw := ""
	for _, r := range after {
		if r.Kind == "table" && r.Name == b.Target.Table {
			actualRaw = r.SQL
		}
	}
	actual, err := parseDDLTable(actualRaw)
	if err != nil || len(expected.terms) != len(actual.terms) || expected.strict != actual.strict || expected.without != actual.without || expected.autoincrement != actual.autoincrement {
		return false
	}
	for i, t := range expected.terms {
		if t.name != actual.terms[i].name || strings.TrimSpace(t.raw) != strings.TrimSpace(actual.terms[i].raw) {
			return false
		}
	}
	info, err := s.tableInfo(ctx, "main", b.Target.Table)
	if err != nil || len(info) != len(proof.ColumnOrder) {
		return false
	}
	for i, n := range proof.ColumnOrder {
		if info[i].Name != n {
			return false
		}
	}
	if expected.autoincrement {
		rows, _, err := s.query(ctx, "SELECT seq FROM main.sqlite_sequence WHERE name=?", b.Target.Table)
		if err != nil || len(rows) > 1 {
			return false
		}
		afterSequence := ""
		if len(rows) == 1 {
			afterSequence = cellText(rows[0][0])
		}
		if sequence != "" && afterSequence != sequence {
			return false
		}
	}
	return true
}
