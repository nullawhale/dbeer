package syncplan

import (
	"context"
	"dbeer/helper/internal/resultcompare"
	tc "dbeer/helper/internal/tablecapture"
	"fmt"
	"sort"
	"strconv"
	"strings"
	"unicode"
	"unicode/utf8"
)

type DataSide struct {
	Descriptor tc.Descriptor
	Outcome    tc.Outcome
	Filters    []tc.Filter
}
type DataInput struct {
	Source, Target DataSide
	Mappings       []tc.Mapping
	Originals      string
}
type DataMapping struct {
	SourceIndex, TargetIndex int
	Key                      bool
}
type DataOperation struct {
	Kind           string
	Descriptor     tc.Descriptor
	Mappings       []DataMapping
	Source, Target []*string
}
type DataRenderer func(DataOperation) (string, error)

// BuildData uses retained full rows. A failure never publishes a SQL prefix.
func BuildData(ctx context.Context, in DataInput, result *resultcompare.Result, digest string, render DataRenderer) (Plan, error) {
	p := New("data", in.Target.Descriptor.Engine, digest)
	manual := func(reason string) (Plan, error) {
		p.Steps = []Step{{ID: "data-manual", Title: "Review data synchronization manually", Manual: true, Reason: reason, DependsOn: []string{}}}
		return p, p.Validate()
	}
	if result == nil || render == nil || in.Source.Descriptor.Engine != p.Engine || (p.Engine != "postgresql" && p.Engine != "mysql") {
		return p, ErrInvalid
	}
	s := result.Summary()
	if !s.Complete || len(in.Source.Outcome.PartialReasons) > 0 || len(in.Target.Outcome.PartialReasons) > 0 {
		return manual("The comparison is partial. Capture both complete inputs before generating executable data SQL.")
	}
	if s.AmbiguousRows > 0 || s.UncertainRows > 0 || !result.MappedTypesCompatible() {
		return manual("Duplicate or uncertain keys, or incompatible mapped types, prevent a safe automatic data plan.")
	}
	if in.Originals != "allColumns" || !in.Source.Outcome.FullOriginals || !in.Target.Outcome.FullOriginals {
		return manual("Full original columns were not retained. Compare again with all original columns enabled.")
	}
	if s.ReportRows > MaxSteps {
		return manual("The plan exceeds 2,000 operations. Narrow the comparison scope; no partial SQL plan was generated.")
	}
	a, b := in.Source.Descriptor, in.Target.Descriptor
	if !a.Table.Valid() || !b.Table.Valid() || len(a.Columns) == 0 || len(b.Columns) == 0 {
		return p, ErrInvalid
	}
	left, right := map[string]int{}, map[string]int{}
	for i, c := range a.Columns {
		if c.Index != i {
			return p, ErrInvalid
		}
		left[c.Name] = i
	}
	for i, c := range b.Columns {
		if c.Index != i {
			return p, ErrInvalid
		}
		right[c.Name] = i
	}
	mappings := []DataMapping{}
	seenA, seenB := map[int]bool{}, map[int]bool{}
	primary, keys := map[int]bool{}, map[int]bool{}
	for i, c := range b.Columns {
		if c.PrimaryKey > 0 {
			primary[i] = true
		}
		if c.ValueComparison != "" {
			return manual("An original target column has an unresolved stored representation.")
		}
	}
	for _, m := range in.Mappings {
		x, ok := left[m.Source]
		y, yes := right[m.Target]
		if !ok || !yes || seenA[x] || seenB[y] {
			return p, ErrInvalid
		}
		seenA[x] = true
		seenB[y] = true
		ac, bc := a.Columns[x], b.Columns[y]
		if ac.NativeType != bc.NativeType || ac.Encoding != bc.Encoding || ac.ValueComparison != "" || bc.ValueComparison != "" {
			return manual("Mapped columns require identical resolved native types and encodings. Conversions need manual work.")
		}
		mappings = append(mappings, DataMapping{x, y, m.Key})
		if m.Key {
			keys[y] = true
		}
	}
	if len(primary) == 0 || len(primary) != len(keys) {
		return manual("Select the complete target primary key as the comparison key before generating data SQL.")
	}
	for i := range primary {
		if !keys[i] {
			return manual("Select the complete target primary key as the comparison key before generating data SQL.")
		}
	}
	if len(mappings) != len(a.Columns) || len(mappings) != len(b.Columns) {
		p.Warnings = append(p.Warnings, "Only explicitly mapped columns are synchronized. Excluded target columns are retained as original-value guards. INSERT requires complete supported target values.")
	}
	if len(in.Source.Filters) > 0 || len(in.Target.Filters) > 0 {
		p.Warnings = append(p.Warnings, "The plan covers only the explicitly filtered comparison scope, not whole tables.")
	}
	p.Warnings = append(p.Warnings, "Each UPDATE/DELETE checks every captured target original. A changed row is skipped; inspect affected row counts. Inserts rely on the target primary key to reject concurrent duplicates.", "Foreign keys, triggers, unique constraints and generated values may require manual ordering. Review all operations and target schema before execution.")
	bytes := 0
	for index := int64(0); index < s.ReportRows; index++ {
		if err := ctx.Err(); err != nil {
			return p, err
		}
		kind, source, target, err := result.OriginalDifference(ctx, index)
		if err != nil {
			return p, err
		}
		action := ""
		switch kind {
		case "deleted":
			action = "insert"
		case "added":
			action = "delete"
		case "changed":
			action = "update"
		default:
			return manual("Uncertain or ambiguous row identities require manual synchronization.")
		}
		if source != nil && len(source) != len(a.Columns) || target != nil && len(target) != len(b.Columns) {
			return p, ErrInvalid
		}
		for _, m := range mappings {
			if m.Key && (source != nil && source[m.SourceIndex] == nil || target != nil && target[m.TargetIndex] == nil) {
				return manual("A comparison key contains NULL; automatic synchronization requires complete non-NULL primary keys.")
			}
		}
		op := DataOperation{action, b, mappings, source, target}
		step := Step{ID: fmt.Sprintf("data-%d", index+1), Title: dataStepTitle(op), DependsOn: []string{}, Destructive: action != "insert"}
		var sql string
		var e error
		if action == "insert" {
			for i, column := range b.Columns {
				if !column.Generated && !seenB[i] {
					e = ErrInvalid
					break
				}
			}
		}
		if e == nil {
			sql, e = render(op)
		}
		if e != nil {
			step.Manual = true
			step.Reason = "This row uses an unsupported type, generated value, identity or incomplete insert mapping. Review and write its SQL manually."
		} else {
			step.SQL = sql
			step.Selected = !step.Destructive
		}
		bytes += len(step.SQL) + len(step.Title) + len(step.Reason) + 256
		if bytes > MaxBytes-32768 {
			return manual("The complete SQL plan exceeds 4 MiB. Narrow the comparison scope; no partial SQL plan was generated.")
		}
		p.Steps = append(p.Steps, step)
	}
	if err := p.Validate(); err != nil {
		if err == ErrLimit {
			return manual("The complete SQL plan exceeds 4 MiB. Narrow the comparison scope; no partial SQL plan was generated.")
		}
		return p, err
	}
	return p, nil
}

const planTitleBytes = 4096

// Titles identify selectable operations without converting exact key strings to
// numeric values. They are UI summaries only; SQL retains complete originals.
func dataStepTitle(op DataOperation) string {
	keys := []DataMapping{}
	for _, mapping := range op.Mappings {
		if mapping.Key {
			keys = append(keys, mapping)
		}
	}
	sort.SliceStable(keys, func(i, j int) bool {
		a, b := keys[i].TargetIndex, keys[j].TargetIndex
		if a < 0 || b < 0 || a >= len(op.Descriptor.Columns) || b >= len(op.Descriptor.Columns) {
			return a < b
		}
		x, y := op.Descriptor.Columns[a].PrimaryKey, op.Descriptor.Columns[b].PrimaryKey
		if x != y {
			return x < y
		}
		return a < b
	})
	path := displayPlanName(op.Descriptor.Table.Schema, 320) + "." + displayPlanName(op.Descriptor.Table.Name, 320)
	prefix := strings.ToUpper(op.Kind) + " target row " + path + " ["
	if len(keys) == 0 {
		return boundedPlanTitle(prefix + "key unavailable]")
	}
	count := min(len(keys), 32)
	budget := (planTitleBytes-len(prefix)-8)/count - 2
	parts := make([]string, 0, count)
	for _, mapping := range keys[:count] {
		if mapping.TargetIndex < 0 || mapping.TargetIndex >= len(op.Descriptor.Columns) {
			parts = append(parts, "key unavailable")
			continue
		}
		column := op.Descriptor.Columns[mapping.TargetIndex]
		nameBudget := min(96, max(16, budget/3))
		name := displayPlanName(column.Name, nameBudget)
		valueBudget := max(16, budget-len(name)-1)
		var value *string
		if op.Kind == "insert" {
			if mapping.SourceIndex >= 0 && mapping.SourceIndex < len(op.Source) {
				value = op.Source[mapping.SourceIndex]
			}
		} else if mapping.TargetIndex < len(op.Target) {
			value = op.Target[mapping.TargetIndex]
		}
		shown := "NULL"
		if value != nil {
			if column.Encoding == "base64" {
				shown = "base64(" + quotedPlanTitle(*value, max(8, valueBudget-8)) + ")"
			} else {
				shown = quotedPlanTitle(*value, valueBudget)
			}
		}
		parts = append(parts, name+"="+shown)
	}
	if len(keys) > count {
		parts = append(parts, "…")
	}
	return boundedPlanTitle(prefix + strings.Join(parts, ", ") + "]")
}

func boundedPlanTitle(value string) string { return boundedPlanText(value, planTitleBytes) }
func boundedPlanText(value string, limit int) string {
	if len(value) <= limit && utf8.ValidString(value) && !strings.ContainsRune(value, 0) {
		return value
	}
	value = strings.ReplaceAll(strings.ToValidUTF8(value, "�"), "\x00", `\0`)
	if len(value) <= limit {
		return value
	}
	n := max(0, limit-len("…"))
	for n > 0 && !utf8.ValidString(value[:n]) {
		n--
	}
	return value[:n] + "…"
}

func displayPlanName(value string, limit int) string {
	plain := value != ""
	for i, r := range value {
		if !(unicode.IsLetter(r) || r == '_' || i > 0 && unicode.IsDigit(r)) {
			plain = false
			break
		}
	}
	if plain {
		return boundedPlanText(value, limit)
	}
	return quotedPlanTitle(value, limit)
}

func quotedPlanTitle(value string, limit int) string {
	// At most a title-sized prefix is ever escaped, even for megabyte keys.
	cut := min(len(value), limit)
	for cut > 0 && !utf8.ValidString(value[:cut]) {
		cut--
	}
	if cut == len(value) {
		encoded := strconv.Quote(value)
		if len(encoded) <= limit {
			return encoded
		}
	}
	lo, hi, best := 0, cut, 0
	for lo <= hi {
		mid := (lo + hi) / 2
		n := mid
		for n > 0 && !utf8.ValidString(value[:n]) {
			n--
		}
		if len(strconv.Quote(value[:n])) <= limit-len("…") {
			best = n
			lo = mid + 1
		} else {
			hi = mid - 1
		}
	}
	return strconv.Quote(value[:best]) + "…"
}
