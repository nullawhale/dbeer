package tableedit

import (
	sc "dbeer/helper/internal/schemacompare"
	"errors"
	"reflect"
	"sort"
	"strconv"
	"strings"
)

type Backfill struct {
	Column     string `json:"column"`
	Expression string `json:"expression"`
}

// Reconstruction is private exact-plan evidence; portable drafts never carry it.
type Reconstruction struct {
	TemporaryTable     string
	Method             string
	ColumnOrder        []string
	ExpectedDefinition string
	RowID              string
}

func (d Draft) NeedsAuthoringV5() bool {
	return len(d.Backfills) > 0 || len(d.ColumnOrder) > 0 || d.Reconstruct
}
func (d Draft) validateReconstruction() error {
	if !d.NeedsAuthoringV5() {
		return nil
	}
	if d.AuthoringVersion != 5 || d.DropTable || d.RenameTable != nil || len(d.Changes)+len(d.Keys)+len(d.Indexes) > 0 || len(d.Backfills) > MaxColumns || len(d.ColumnOrder) > MaxColumns {
		return ErrInvalid
	}
	seen := map[string]bool{}
	for _, b := range d.Backfills {
		if !Identifier(b.Column) || !authoredText(b.Expression) || seen[b.Column] {
			return ErrInvalid
		}
		seen[b.Column] = true
		found := false
		for _, c := range d.Columns {
			if c.Name == b.Column {
				found = true
				if c.Nullable || c.Default.Kind != "none" || c.Type.Reference != nil || c.Generated != nil || c.Identity != nil {
					return errors.New("A backfill requires an appended NOT NULL built-in column without DEFAULT, generation or identity. Review defaults separately.")
				}
			}
		}
		if !found {
			return errors.New("Each backfill must name an appended required column; existing values cannot be overwritten by this workflow.")
		}
	}
	for _, c := range d.Columns {
		if !seen[c.Name] {
			return errors.New("Review reconstruction/backfill separately from ordinary appended columns.")
		}
	}
	seen = map[string]bool{}
	for _, n := range d.ColumnOrder {
		if !Identifier(n) || seen[n] {
			return ErrInvalid
		}
		seen[n] = true
	}
	return nil
}
func ReconstructionOrder(b Baseline, d Draft) ([]string, error) {
	if err := d.Validate(); err != nil {
		return nil, err
	}
	if b.Target.Create || !d.NeedsAuthoringV5() || len(b.Columns)+len(d.Columns) > MaxColumns {
		return nil, ErrInvalid
	}
	names := []string{}
	seen := map[string]bool{}
	for _, c := range b.Columns {
		names = append(names, c.Name)
		seen[c.Name] = true
	}
	for _, c := range d.Columns {
		if seen[c.Name] {
			return nil, ErrInvalid
		}
		names = append(names, c.Name)
		seen[c.Name] = true
	}
	for _, x := range d.Backfills {
		if _, err := ExpressionSlot(b.Engine, x.Expression); err != nil {
			return nil, err
		}
	}
	if len(d.ColumnOrder) == 0 {
		return names, nil
	}
	if len(d.ColumnOrder) != len(names) {
		return nil, errors.New("Column order must list every retained and appended column exactly once.")
	}
	for _, n := range d.ColumnOrder {
		if !seen[n] {
			return nil, ErrInvalid
		}
	}
	return append([]string(nil), d.ColumnOrder...), nil
}
func ReconstructionReview(b Baseline, d Draft) ([]Consequence, []ValidationCheck) {
	consequences := []Consequence{{Kind: "locking", Object: b.Target.Schema + "." + b.Target.Table, Message: "Physical changes can rewrite the full table and require extra disk space and exclusive locks. Stop cannot undo an acknowledged step; uncertain outcomes must be reconciled explicitly."}}
	checks := []ValidationCheck{}
	for _, x := range d.Backfills {
		consequences = append(consequences, Consequence{Kind: "backfill", Object: x.Column, Message: "The exact displayed expression runs during Apply against existing rows, may execute user code, and can fail or change external state. UPDATE fires applicable UPDATE triggers; copy reconstruction evaluates expressions and constraints while retained triggers are recreated after copying. Trigger/function side effects may not roll back."})
		why := "Preview never executes backfill expressions or scans rows. Independent data validation does not evaluate the backfill: it cannot prove non-NULL results, absence of side effects, or future constraint acceptance. Apply performs the reviewed write and enforces constraints."
		checks = append(checks, ValidationCheck{ID: "backfill-" + strconv.Itoa(len(checks)), Summary: "Backfill expression and required-value acceptance for " + x.Column, Risks: []string{}, UnavailableReason: &why})
	}
	return consequences, checks
}
func VerifyColumnOrder(before, after Baseline, order []string, changedIdentity bool) bool {
	if before.Facts == nil || after.Facts == nil || before.Scope != after.Scope || before.Guard != after.Guard || !changedIdentity && before.Identity != after.Identity || len(after.Columns) != len(order) {
		return false
	}
	for i, n := range order {
		if after.Columns[i].Name != n {
			return false
		}
	}
	a, z := cloneFacts(before.Facts), cloneFacts(after.Facts)
	normalize := func(f *Facts) {
		sort.Slice(f.Table.Columns.Items, func(i, j int) bool { return f.Table.Columns.Items[i].Ref.Name < f.Table.Columns.Items[j].Ref.Name })
		for i := range f.Table.Columns.Items {
			f.Table.Columns.Items[i].Ordinal = sc.Known(i)
		}
	}
	normalize(a)
	normalize(z)
	return reflect.DeepEqual(a, z)
}

// pg_attver is server-owned tuple-layout identity, added by the November 2026
// security backpatch. It changes on reconstruction and cannot be restored by DDL.
// See PostgreSQL src/backend/catalog/README.attver.md; raw fingerprints retain it.
func SemanticPostgresAttributeOptions(value any) any {
	if value == nil {
		return nil
	}
	options, ok := value.([]any)
	if !ok {
		return value
	}
	out := []any{}
	seen := false
	for _, option := range options {
		text, ok := option.(string)
		if !ok || !strings.HasPrefix(text, "pg_attver=") {
			out = append(out, option)
			continue
		}
		version := strings.TrimPrefix(text, "pg_attver=")
		if seen || !postgresAttributeVersion(version) {
			return value
		}
		seen = true
	}
	if len(out) == 0 {
		return nil
	}
	return out
}
func postgresAttributeVersion(s string) bool {
	if n, e := strconv.ParseUint(s, 10, 64); e == nil && strconv.FormatUint(n, 10) == s {
		return true
	}
	parts := strings.Split(s, "/")
	if len(parts) != 2 {
		return false
	}
	for _, p := range parts {
		if len(p) == 0 || len(p) > 8 {
			return false
		}
		if _, e := strconv.ParseUint(p, 16, 32); e != nil {
			return false
		}
	}
	return true
}
func EmptyPostgresOptions(value any) bool { return SemanticPostgresAttributeOptions(value) == nil }
