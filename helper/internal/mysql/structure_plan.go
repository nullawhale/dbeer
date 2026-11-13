package mysql

import (
	"context"
	sc "dbeer/helper/internal/schemacompare"
	"dbeer/helper/internal/syncplan"
	"dbeer/helper/internal/tableedit"
	"encoding/json"
	"errors"
	"strings"
)

func (s *Session) StructurePrepare(ctx context.Context, b tableedit.Baseline, d tableedit.Draft) (tableedit.Prepared, error) {
	var enable []tableedit.Operation
	var e error
	d, enable, e = mysqlAuthoredDraft(b, d)
	if e != nil {
		return tableedit.Prepared{}, e
	}
	ops, refs, e := tableedit.PlanOperations(b, d, "mysql", func(t tableedit.Target) (tableedit.Baseline, error) { return s.StructureLoad(ctx, t) })
	if e != nil {
		return tableedit.Prepared{}, e
	}
	ops = insertMySQLIdentityOperations(ops, enable)
	for _, edit := range d.Indexes {
		if edit.Definition != nil {
			if err := validateMySQLIndexDefinition(tableedit.PlanningSource(b, d, "mysql"), *edit.Definition); err != nil {
				return tableedit.Prepared{}, err
			}
		}
	}
	out := tableedit.Prepared{ResultTarget: tableedit.ResultTarget(b.Target, d), References: refs, Risks: []string{"MySQL DDL implicitly commits. Each displayed statement is an independent step on a dedicated session with lock_wait_timeout=5. The entire plan is not atomic; earlier acknowledged steps survive later failure or Stop.", "DDL may block, rebuild or scan tables. Metadata rechecks are best effort and cannot close concurrent DDL races or prove drop/recreate identity. Catalogs cannot prove absence of dynamic SQL dependencies. No backfill, disabled checks, CASCADE removal or automatic replay is generated.", "Foreign keys are generated only against a supported primary/unique key; any required supporting index is an explicit reviewed step. MySQL may normalize nullable defaults and key-owned backing structures."}}
	if e = s.mysqlDestructiveReview(ctx, b, d, &out); e != nil {
		return out, e
	}
	if d.HasAuthoredExpressions() || len(enable) > 0 || d.NeedsAuthoringV3() {
		out.Risks = append(out.Risks, "Expressions and value generation run only during Apply or later writes. Preview reads metadata and validates boundaries; it does not evaluate expressions. AUTO_INCREMENT uses only an explicitly selected leading key and does not guarantee gap-free values.")
	}
	existingIdentityEnable := !b.Target.Create && len(enable) > 0
	for _, change := range d.Changes {
		existingIdentityEnable = existingIdentityEnable || change.Identity != nil && change.Identity.Kind == "autoIncrement"
	}
	if existingIdentityEnable {
		out.Risks = append(out.Risks, "Enabling AUTO_INCREMENT may replace stored zero values with generated IDs unless the captured session SQL mode includes NO_AUTO_VALUE_ON_ZERO. This value-changing effect requires confirmation of this exact plan; Preview does not scan values or change SQL mode.")
	}
	target := QuoteIdentifier(b.Target.Schema) + "." + QuoteIdentifier(b.Target.Table)
	columns := func(names []string) string {
		v := []string{}
		for _, n := range names {
			v = append(v, QuoteIdentifier(n))
		}
		return strings.Join(v, ", ")
	}
	for _, op := range ops {
		stepStart := len(out.SQL)
		switch op.Kind {
		case "dropTable":
			out.SQL = append(out.SQL, "DROP TABLE "+target+";")
		case "dropColumn":
			out.SQL = append(out.SQL, "ALTER TABLE "+target+" DROP COLUMN "+QuoteIdentifier(op.Change.Name)+";")
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
			sql, e := mysqlPlannedChange(ctx, b, d, *op.Change, target)
			if e != nil {
				return out, e
			}
			out.SQL = append(out.SQL, sql...)
		case "renameColumn":
			out.SQL = append(out.SQL, "ALTER TABLE "+target+" RENAME COLUMN "+QuoteIdentifier(op.Change.Name)+" TO "+QuoteIdentifier(*op.Change.RenameTo)+";")
		case "renameTable":
			out.SQL = append(out.SQL, "RENAME TABLE "+target+" TO "+QuoteIdentifier(b.Target.Schema)+"."+QuoteIdentifier(*op.Name)+";")
		case "dropIndex":
			out.SQL = append(out.SQL, "ALTER TABLE "+target+" DROP INDEX "+QuoteIdentifier(op.Index.Name)+";")
		case "addIndex":
			if op.Index.Definition != nil {
				sql, err := renderMySQLIndex(ctx, b, *op.Index)
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
			out.SQL = append(out.SQL, "CREATE "+unique+"INDEX "+QuoteIdentifier(x.Name)+" USING BTREE ON "+target+" ("+columns(x.Columns)+");")
		case "dropKey":
			k := op.Key
			drop := "DROP INDEX " + QuoteIdentifier(k.Name)
			if k.Kind == "primary" {
				drop = "DROP PRIMARY KEY"
			} else if k.Kind == "foreign" {
				drop = "DROP FOREIGN KEY " + QuoteIdentifier(k.Name)
			}
			out.SQL = append(out.SQL, "ALTER TABLE "+target+" "+drop+";")
		case "addKey":
			k := op.Key
			definition := "CONSTRAINT " + QuoteIdentifier(k.Name) + " "
			switch k.Kind {
			case "primary":
				definition += "PRIMARY KEY (" + columns(k.Columns) + ")"
			case "unique":
				definition += "UNIQUE (" + columns(k.Columns) + ")"
			case "foreign":
				definition += "FOREIGN KEY (" + columns(k.Columns) + ") REFERENCES " + QuoteIdentifier(k.Reference.Schema) + "." + QuoteIdentifier(k.Reference.Table) + " (" + columns(k.ReferenceColumns) + ") ON UPDATE " + k.OnUpdate + " ON DELETE " + k.OnDelete
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
			out.Conditions = append(out.Conditions, condition)
		}

	}
	return out, nil
}
func mysqlPlannedChange(ctx context.Context, b tableedit.Baseline, d tableedit.Draft, change tableedit.ColumnChange, target string) ([]string, error) {
	if d.NeedsAuthoringV4() && change.Conversion() {
		return mysqlConversionChange(ctx, b, change, target)
	}
	if change.Identity != nil {
		for _, c := range d.Columns {
			if c.Name == change.Name {
				c.Identity = change.Identity
				definition, err := structureColumn(c)
				if err != nil {
					return nil, err
				}
				return []string{"ALTER TABLE " + target + " MODIFY COLUMN " + definition + ";"}, nil
			}
		}
	}
	return mysqlStructureChange(ctx, b, change, target)
}

func mysqlStructureChange(ctx context.Context, b tableedit.Baseline, change tableedit.ColumnChange, target string) ([]string, error) {
	captured, ok := tableedit.FindColumn(b, change.Name)
	if !ok {
		return nil, tableedit.ErrUnsupported
	}
	raw, _ := json.Marshal(captured)
	var c sc.Column
	_ = json.Unmarshal(raw, &c)
	typ, ok := tableedit.ColumnType(c)
	if !ok {
		return nil, tableedit.ErrUnsupported
	}
	if change.Generated != nil || change.Identity != nil {
		return mysqlAuthoredChange(ctx, b, c, change, target)
	}
	if change.Type == nil && change.Nullable == nil {
		if change.Default.Kind == "none" {
			return []string{"ALTER TABLE " + target + " ALTER COLUMN " + QuoteIdentifier(change.Name) + " DROP DEFAULT;"}, nil
		}
		definition, e := structureColumn(tableedit.Column{Name: "value", Type: typ, Nullable: c.Nullable.Value != nil && *c.Nullable.Value, Default: *change.Default})
		if e != nil {
			return nil, e
		}
		i := strings.Index(definition, " DEFAULT ")
		if i < 0 {
			return nil, tableedit.ErrInvalid
		}
		return []string{"ALTER TABLE " + target + " ALTER COLUMN " + QuoteIdentifier(change.Name) + " SET DEFAULT " + definition[i+9:] + ";"}, nil
	}
	if change.Type != nil {
		if !tableedit.CanWiden(c, *change.Type) {
			return nil, tableedit.ErrUnsupported
		}
		switch change.Type.Kind {
		case "bigint":
			c.Type.Value.Ref.Name = "bigint"
		case "varchar":
			n := int64(change.Type.Length)
			c.Type.Value.Modifiers.Value.Length = &n
		}
		typ = *change.Type
	}
	if change.Nullable != nil {
		c.Nullable = sc.Known(*change.Nullable)
	}
	if change.Default != nil {
		definition, e := structureColumn(tableedit.Column{Name: "value", Type: typ, Nullable: c.Nullable.Value != nil && *c.Nullable.Value, Default: *change.Default})
		if e != nil {
			return nil, e
		}
		_ = definition
		value := sc.Default{Kind: "none"}
		switch change.Default.Kind {
		case "none":
		case "null":
			value.Kind = "sqlNull"
		case "expression":
			value.Kind = "expression"
			value.Expression = &sc.Expression{Text: *change.Default.Value}
		default:
			value.Kind = "literal"
			value.Value = change.Default.Value
			value.Type = c.Type.Value
			value.Encoding = "text"
		}
		c.Default = sc.Known(value)
	}
	proof := c
	authored := map[*sc.Expression]bool{}
	if change.Default != nil && change.Default.Kind == "expression" {
		proof.Default = sc.Known(sc.Default{Kind: "none"})
		authored[c.Default.Value.Expression] = true
	}
	if reason := syncplan.SchemaFactsReason(proof); reason != "" {
		return nil, errors.New("MySQL MODIFY cannot preserve all unchanged column attributes: " + reason)
	}
	renderer := myDefinition{w: &sc.DefinitionWriter{Context: ctx}, engine: sc.Known(b.Facts.EngineContext), authored: authored}
	renderer.column(c)
	definition, e := renderer.w.Finish()
	if e != nil || definition.Limited {
		return nil, tableedit.ErrUnsupported
	}
	return []string{"ALTER TABLE " + target + " MODIFY COLUMN " + definition.SQL + ";"}, nil
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
		x := s.applyStructureStep(ctx, current, []string{step}, refs)
		out = append(out, x)
		if x.State != "applied" {
			break
		}
		if plan.Conditions[i].Operation.Kind == "dropTable" {
			absent := current.Target
			absent.Create = true
			fresh, err := s.StructureLoad(ctx, absent)
			if err != nil || !tableedit.ValidBaseline(fresh) || !fresh.Target.Create {
				out[len(out)-1].Message = "DROP TABLE was acknowledged, but absence could not be verified. Reconcile before another edit."
			}
			break
		}
		target := tableedit.StepTarget(current.Target, plan.Conditions[i])
		fresh, e := s.StructureLoad(ctx, target)
		verified := e == nil && tableedit.ValidBaseline(fresh) && tableedit.VerifyTransition(current, fresh, plan.Conditions[i], func(c sc.Column, w tableedit.Default) bool { return structureDefaultMatchesFacts(c, w, fresh.Facts) })
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
