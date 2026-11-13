package mysql

import (
	"context"
	"dbeer/helper/internal/tableedit"
	"errors"
	"reflect"
	"strings"
)

func (s *Session) prepareStructureReconstruction(ctx context.Context, b tableedit.Baseline, d tableedit.Draft) (tableedit.Prepared, error) {
	order, err := tableedit.ReconstructionOrder(b, d)
	if err != nil {
		return tableedit.Prepared{}, err
	}
	p := tableedit.Prepared{}
	target := QuoteIdentifier(b.Target.Schema) + "." + QuoteIdentifier(b.Target.Table)
	if len(d.Backfills) > 0 {
		if d.Reconstruct || len(d.ColumnOrder) > 0 {
			return p, errors.New("Review MySQL backfill separately from physical reordering or reconstruction.")
		}
		strict := false
		if b.Facts != nil {
			for _, o := range b.Facts.EngineContext {
				if o.Name == "sqlMode" {
					for _, m := range strings.Split(o.Value, ",") {
						strict = strict || m == "STRICT_ALL_TABLES" || m == "STRICT_TRANS_TABLES"
					}
				}
			}
		}
		if !strict {
			return p, errors.New("Backfill requires an already strict MySQL session SQL mode; the helper never changes SQL mode implicitly.")
		}
		relaxed := tableedit.Draft{AuthoringVersion: 2, Columns: append([]tableedit.Column(nil), d.Columns...)}
		for i := range relaxed.Columns {
			relaxed.Columns[i].Nullable = true
		}
		p, err = s.StructurePrepare(ctx, b, relaxed)
		if err != nil {
			return p, err
		}
		for _, x := range d.Backfills {
			expression, e := tableedit.ExpressionSlot("mysql", x.Expression)
			if e != nil {
				return p, e
			}
			name := QuoteIdentifier(x.Column)
			p.SQL = append(p.SQL, "UPDATE "+target+" SET "+name+" = "+expression+" WHERE "+name+" IS NULL;")
			p.Conditions = append(p.Conditions, tableedit.Condition{Operation: tableedit.Operation{Kind: "backfill"}})
			for _, c := range d.Columns {
				if c.Name == x.Column {
					definition, e := structureColumn(c)
					if e != nil {
						return p, e
					}
					p.SQL = append(p.SQL, "ALTER TABLE "+target+" MODIFY COLUMN "+definition+";")
					required := false
					p.Conditions = append(p.Conditions, tableedit.Condition{Operation: tableedit.Operation{Kind: "changeColumn", Change: &tableedit.ColumnChange{Name: x.Column, Nullable: &required}}})
				}
			}
		}
		p.Risks = []string{"ADD, the displayed UPDATE and NOT NULL enforcement are independent autocommit steps on the dedicated structure session. Earlier acknowledged writes survive later failure or Stop. No implicit replay occurs.", "Backfill runs only during Apply and may scan, lock, run user functions and UPDATE triggers, modify other values or external state, and fail. Concurrent writes between steps can make NOT NULL enforcement fail. Metadata rechecks cannot close concurrent MySQL DDL races. Strict session SQL mode is required and is never changed implicitly."}
	} else {
		if b.Facts == nil || !b.Facts.Proof || !b.Facts.Table.Columns.Complete || !b.Facts.Table.Constraints.Complete || !b.Facts.Table.Indexes.Complete {
			return p, errors.New("Physical reordering requires complete retained column, constraint, index and dependency metadata.")
		}

		definitions, _, _, ok := mysqlReconstructionDefinition(b.NativeDefinition, b.Facts)
		if !ok || len(definitions) != len(b.Columns) {
			return p, errors.New("The complete native MySQL column definitions are unavailable; reconstruction cannot silently omit attributes.")
		}
		for _, c := range b.Columns {
			if _, ok := definitions[c.Name]; !ok {
				return p, tableedit.ErrUnsupported
			}
		}
		if len(d.ColumnOrder) > 0 && b.Facts.ServerVersion < 80400 {
			for i, c := range b.Columns {
				fact, ok := tableedit.FindColumn(b, c.Name)
				if !ok || fact.Generated.Value == nil {
					return p, tableedit.ErrUnsupported
				}
				if fact.Generated.Value.Kind == "virtual" && order[i] != c.Name {
					return p, errors.New("Moving a virtual generated column on this MySQL version requires ALGORITHM=COPY. Review a separate migration preserving native values and AUTO_INCREMENT zeros; this workflow keeps ALGORITHM=INPLACE and never silently falls back.")
				}
			}
		}
		if len(d.ColumnOrder) > 0 {
			parts := []string{}
			for i, n := range order {
				definition, ok := definitions[n]
				if !ok {
					return p, tableedit.ErrInvalid
				}
				position := " FIRST"
				if i > 0 {
					position = " AFTER " + QuoteIdentifier(order[i-1])
				}
				parts = append(parts, "MODIFY COLUMN "+definition+position)
			}
			if d.Reconstruct {
				parts = append(parts, "FORCE")
			}
			p.SQL = []string{"ALTER TABLE " + target + " " + strings.Join(parts, ", ") + ", ALGORITHM=INPLACE, LOCK=EXCLUSIVE;"}
		} else {
			p.SQL = []string{"ALTER TABLE " + target + " FORCE, ALGORITHM=INPLACE, LOCK=EXCLUSIVE;"}
		}

		p.Conditions = []tableedit.Condition{{Operation: tableedit.Operation{Kind: "reorder"}, ColumnOrder: order}}
		p.Risks = []string{"MySQL performs one native ALTER TABLE using full captured column definitions, FIRST/AFTER when requested, FORCE for every explicitly requested reconstruction, ALGORITHM=INPLACE and LOCK=EXCLUSIVE. The server retains native constraints, indexes, triggers and foreign-key relationships; this may require extra disk space and block reads and writes.", "The DDL implicitly commits. Stop and Discard cannot undo acknowledged reconstruction, and lost acknowledgement remains unknown without replay. Metadata rechecks are best effort and cannot close concurrent DDL races. The post-step comparison verifies every captured retained schema fact and exact requested order; a mismatch stops further work."}
	}
	p.Consequences, p.ValidationChecks = tableedit.ReconstructionReview(b, d)
	return p, nil
}

// Native SHOW CREATE clauses preserve properties that the portable model cannot
// express. Nothing inside a retained column definition is rewritten.
func mysqlReconstructionDefinition(raw string, f *tableedit.Facts) (map[string]string, []string, string, bool) {
	mode := ""
	if f == nil {
		return nil, nil, "", false
	}
	for _, o := range f.EngineContext {
		if o.Name == "sqlMode" {
			mode = o.Value
		}
	}
	tokens, ok := mysqlIndexMetadataTokens(raw, mode, 0)
	if !ok {
		return nil, nil, "", false
	}
	open := -1
	for i, t := range tokens {
		if t.kind == "punct" && t.value == "(" {
			open = i
			break
		}
	}
	if open < 0 {
		return nil, nil, "", false
	}
	columns := map[string]string{}
	other := []string{}
	start := open + 1
	offset := tokens[open].end
	depth := 1
	add := func(end, until int) bool {
		clause := tokens[start:until]
		if len(clause) == 0 {
			return false
		}
		text := strings.TrimSpace(raw[offset:end])
		if clause[0].kind == "identifier" {
			name := clause[0].value
			if _, exists := columns[name]; exists {
				return false
			}
			columns[name] = text
		} else {
			other = append(other, text)
		}
		return true
	}
	for i := open + 1; i < len(tokens); i++ {
		t := tokens[i]
		if t.kind != "punct" {
			continue
		}
		switch t.value {
		case "(":
			depth++
		case ")":
			depth--
			if depth == 0 {
				if !add(t.start, i) {
					return nil, nil, "", false
				}
				return columns, other, strings.TrimSpace(raw[t.end:]), true
			}
		case ",":
			if depth == 1 {
				if !add(t.start, i) {
					return nil, nil, "", false
				}
				start = i + 1
				offset = t.end
			}
		}
	}
	return nil, nil, "", false
}
func mysqlReconstructionPreserved(a, b tableedit.Baseline) bool {
	ca, oa, sa, ok := mysqlReconstructionDefinition(a.NativeDefinition, a.Facts)
	if !ok {
		return false
	}
	cb, ob, sb, ok := mysqlReconstructionDefinition(b.NativeDefinition, b.Facts)
	return ok && reflect.DeepEqual(ca, cb) && reflect.DeepEqual(oa, ob) && sa == sb
}
