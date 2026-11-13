package postgres

import (
	"context"
	sc "dbeer/helper/internal/schemacompare"
	"dbeer/helper/internal/tableedit"
	"errors"
	"github.com/jackc/pgx/v5"
	"strings"
)

func (s *Session) StructurePrepare(ctx context.Context, b tableedit.Baseline, d tableedit.Draft) (tableedit.Prepared, error) {
	var guards []tableedit.TypeGuard
	var e error
	d, guards, e = s.resolveAuthoredTypes(ctx, b, d)
	if e != nil {
		return tableedit.Prepared{}, e
	}
	for _, c := range d.Columns {
		if e = validatePGAuthoredColumn(b, c); e != nil {
			return tableedit.Prepared{}, e
		}
	}
	indexGuards, e := s.prepareAuthoredIndexes(ctx, b, d)
	if e != nil {
		return tableedit.Prepared{}, e
	}
	ops, refs, e := tableedit.PlanOperations(b, d, "postgresql", func(t tableedit.Target) (tableedit.Baseline, error) { return s.StructureLoad(ctx, t) })
	if e != nil {
		return tableedit.Prepared{}, e
	}
	out := tableedit.Prepared{Types: guards, IndexGuards: indexGuards, ResultTarget: tableedit.ResultTarget(b.Target, d), References: refs, Risks: []string{"Every displayed statement is an independent execution unit using a dedicated session: BEGIN, SET LOCAL lock_timeout='5s', ordered ACCESS EXCLUSIVE locks, metadata rechecks, the reviewed DDL and COMMIT. The entire plan is not atomic; earlier acknowledged steps survive later failure or Stop.", "DDL may block, scan or rewrite tables. No backfill, CASCADE or automatic replay is generated. Catalogs cannot prove the absence of dynamic SQL dependencies."}}
	if d.HasAuthoredExpressions() || len(guards) > 0 || len(indexGuards) > 0 {
		out.Risks = append(out.Risks, pgExpressionRisk())
	}
	target := pgx.Identifier{b.Target.Schema, b.Target.Table}.Sanitize()
	quote := func(x string) string { return pgx.Identifier{x}.Sanitize() }
	columns := func(names []string) string {
		v := []string{}
		for _, n := range names {
			v = append(v, quote(n))
		}
		return strings.Join(v, ", ")
	}
	for _, op := range ops {
		stepStart := len(out.SQL)
		switch op.Kind {
		case "create":
			sql, _, e := s.StructureRender(b, tableedit.Draft{AuthoringVersion: d.AuthoringVersion, Columns: d.Columns})
			if e != nil {
				return out, e
			}
			out.SQL = append(out.SQL, sql...)
		case "addColumn":
			definition, e := structureColumn(*op.Column)
			if e != nil {
				return out, e
			}
			out.SQL = append(out.SQL, "ALTER TABLE "+target+" ADD COLUMN "+definition+";")
		case "changeColumn":
			c := op.Change
			if c.Generated != nil {
				steps, err := pgGeneratedChange(b, *c, target)
				if err != nil {
					return out, err
				}
				out.SQL = append(out.SQL, steps...)
				break
			}
			if c.Identity != nil {
				steps, err := pgIdentityChange(b, *c, target)
				if err != nil {
					return out, err
				}
				out.SQL = append(out.SQL, steps...)
				break
			}
			old, ok := tableedit.FindColumn(b, c.Name)
			if !ok {
				return out, tableedit.ErrUnsupported
			}
			typ, ok := tableedit.ColumnType(old)
			if !ok {
				return out, tableedit.ErrUnsupported
			}
			prefix := "ALTER TABLE " + target + " ALTER COLUMN " + quote(c.Name)
			if c.Type != nil {
				typ = *c.Type
				definition, e := structureColumn(tableedit.Column{Name: c.Name, Type: typ, Nullable: true, Default: tableedit.Default{Kind: "none"}})
				if e != nil {
					return out, e
				}
				out.SQL = append(out.SQL, prefix+" TYPE "+strings.TrimPrefix(definition, quote(c.Name)+" ")+";")
			}
			if c.Nullable != nil {
				action := " SET NOT NULL;"
				if *c.Nullable {
					action = " DROP NOT NULL;"
				}
				out.SQL = append(out.SQL, prefix+action)
			}
			if c.Default != nil {
				if c.Default.Kind == "none" {
					out.SQL = append(out.SQL, prefix+" DROP DEFAULT;")
				} else {
					nullable := old.Nullable.Value != nil && *old.Nullable.Value
					if c.Nullable != nil {
						nullable = *c.Nullable
					}
					definition, e := structureColumn(tableedit.Column{Name: "value", Type: typ, Nullable: nullable, Default: *c.Default})
					if e != nil {
						return out, e
					}
					i := strings.Index(definition, " DEFAULT ")
					if i < 0 {
						return out, tableedit.ErrInvalid
					}
					out.SQL = append(out.SQL, prefix+" SET DEFAULT "+definition[i+9:]+";")
				}
			}
		case "renameColumn":
			out.SQL = append(out.SQL, "ALTER TABLE "+target+" RENAME COLUMN "+quote(op.Change.Name)+" TO "+quote(*op.Change.RenameTo)+";")
		case "renameTable":
			out.SQL = append(out.SQL, "ALTER TABLE "+target+" RENAME TO "+quote(*op.Name)+";")
		case "dropIndex":
			out.SQL = append(out.SQL, "DROP INDEX "+pgx.Identifier{b.Target.Schema, op.Index.Name}.Sanitize()+";")
		case "addIndex":
			if op.Index.Definition != nil {
				sql, err := renderPGIndex(ctx, b.Target, *op.Index)
				if err != nil {
					return out, err
				}
				out.SQL = append(out.SQL, sql)
				break
			}
			x := op.Index
			unique := ""
			if x.Unique {
				unique = "UNIQUE "
			}
			out.SQL = append(out.SQL, "CREATE "+unique+"INDEX "+quote(x.Name)+" ON "+target+" USING btree ("+columns(x.Columns)+");")
		case "dropKey":
			out.SQL = append(out.SQL, "ALTER TABLE "+target+" DROP CONSTRAINT "+quote(op.Key.Name)+";")
		case "addKey":
			k := op.Key
			definition := "CONSTRAINT " + quote(k.Name) + " "
			switch k.Kind {
			case "primary":
				definition += "PRIMARY KEY (" + columns(k.Columns) + ")"
			case "unique":
				definition += "UNIQUE (" + columns(k.Columns) + ")"
			case "foreign":
				definition += "FOREIGN KEY (" + columns(k.Columns) + ") REFERENCES " + pgx.Identifier{k.Reference.Schema, k.Reference.Table}.Sanitize() + " (" + columns(k.ReferenceColumns) + ") ON UPDATE " + k.OnUpdate + " ON DELETE " + k.OnDelete
			default:
				return out, tableedit.ErrInvalid
			}
			out.SQL = append(out.SQL, "ALTER TABLE "+target+" ADD "+definition+";")
		default:
			return out, errors.New("Unsupported structure operation.")
		}
		for i := stepStart; i < len(out.SQL); i++ {
			condition := tableedit.Condition{Operation: op}
			if op.Kind == "create" {
				condition.Columns = d.Columns
			}
			if op.Kind == "changeColumn" && op.Change.Generated == nil && op.Change.Identity == nil {
				changes := []tableedit.ColumnChange{}
				c := op.Change
				if c.Type != nil {
					changes = append(changes, tableedit.ColumnChange{Name: c.Name, Type: c.Type})
				}
				if c.Nullable != nil {
					changes = append(changes, tableedit.ColumnChange{Name: c.Name, Nullable: c.Nullable})
				}
				if c.Default != nil {
					changes = append(changes, tableedit.ColumnChange{Name: c.Name, Default: c.Default})
				}
				condition.Operation.Change = &changes[i-stepStart]
			}
			out.Conditions = append(out.Conditions, condition)
		}

	}
	return out, nil
}
func (s *Session) StructureApplySteps(ctx context.Context, b tableedit.Baseline, plan tableedit.Plan) []tableedit.Execution {
	if len(plan.Conditions) != len(plan.SQL) {
		return []tableedit.Execution{{State: "notStarted", Message: "The retained plan conditions are invalid."}}
	}
	out := []tableedit.Execution{}
	current := b
	refs := append([]tableedit.Baseline(nil), plan.References...)
	for i, step := range plan.SQL {
		if ctx.Err() != nil {
			return append(out, tableedit.Execution{State: "notStarted", Message: "Cancelled before the next DDL step."})
		}
		x := s.applyStructureStep(ctx, current, []string{step}, refs, structureGuards{Types: plan.Types, Indexes: plan.IndexGuards})
		out = append(out, x)
		if x.State != "applied" {
			break
		}
		target := tableedit.StepTarget(current.Target, plan.Conditions[i])
		fresh, e := s.StructureLoad(ctx, target)
		verified := e == nil && tableedit.ValidBaseline(fresh) && verifyIndexGuards(ctx, s.conn, plan.IndexGuards) && tableedit.VerifyTransition(current, fresh, plan.Conditions[i], func(c sc.Column, w tableedit.Default) bool { return structureDefaultMatchesFacts(c, w, fresh.Facts) })
		if !verified {
			out[len(out)-1].Message = "The DDL step was acknowledged, but observed structure did not match the expected change and preservation conditions. Reconcile before continuing."
			break
		}
		for j, ref := range refs {
			observed, err := s.StructureLoad(ctx, ref.Target)
			if err != nil || !tableedit.ValidBaseline(observed) || !tableedit.VerifyReference(ref, observed, current, plan.Conditions[i]) {
				out[len(out)-1].Message = "The DDL step was acknowledged, but referenced metadata changed unexpectedly. Reconcile before continuing."
				return out
			}
			refs[j] = observed
		}
		current = fresh
		if s.afterStructureStep != nil {
			s.afterStructureStep(i)
		}
	}
	return out
}
