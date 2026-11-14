package mariadb

import (
	"context"
	"dbeer/helper/internal/adapter"
	"dbeer/helper/internal/protocol"
	sc "dbeer/helper/internal/schemacompare"
	"dbeer/helper/internal/tableedit"
	"errors"
	wire "github.com/go-mysql-org/go-mysql/mysql"
	"math/big"
	"strings"
)

const mariaDBDDLPrefix = "SET STATEMENT lock_wait_timeout=5 FOR\n"
const mariaDBDDLRisk = "MariaDB DDL implicitly commits. Each displayed statement is an independent reviewed step with statement-scoped lock_wait_timeout=5; it may lock, scan or rebuild the native table. Earlier acknowledged changes survive a later failure or Stop. No automatic retry, reconnect or rollback of acknowledged DDL is performed. Concurrent DDL can race metadata observations."

func mariaDBQuotedColumns(names []string) string {
	out := make([]string, len(names))
	for i, n := range names {
		out[i] = QuoteIdentifier(n)
	}
	return strings.Join(out, ", ")
}
func (s *Session) StructureRender(b tableedit.Baseline, d tableedit.Draft) ([]string, []string, error) {
	if b.Engine != "mariadb" || !b.Target.Valid() || d.ValidateForEngine("mariadb") != nil {
		return nil, nil, tableedit.ErrInvalid
	}
	parts := []string{}
	seen := map[string]bool{}
	for _, c := range d.Columns {
		key := strings.ToLower(c.Name)
		if seen[key] {
			return nil, nil, tableedit.ErrInvalid
		}
		seen[key] = true
		for _, old := range b.Columns {
			if strings.EqualFold(old.Name, c.Name) {
				return nil, nil, tableedit.ErrInvalid
			}
		}
		if c.Identity != nil && c.Identity.Kind != "none" {
			return nil, nil, errors.New("AUTO_INCREMENT requires its explicit supporting-key and native counter proof before authoring.")
		}
		x, e := mariaDBStructureColumn(c)
		if e != nil {
			return nil, nil, e
		}
		parts = append(parts, x)
	}
	q := QuoteIdentifier(b.Target.Schema) + "." + QuoteIdentifier(b.Target.Table)
	sql := "CREATE TABLE " + q + " (" + strings.Join(parts, ", ") + ") ENGINE=InnoDB;"
	if !b.Target.Create {
		if len(parts) != 1 || !d.Columns[0].Nullable {
			return nil, nil, tableedit.ErrInvalid
		}
		sql = "ALTER TABLE " + q + " ADD COLUMN " + parts[0] + ";"
	}
	return []string{mariaDBDDLPrefix + sql}, []string{mariaDBDDLRisk}, nil
}
func (s *Session) StructurePrepare(ctx context.Context, b tableedit.Baseline, d tableedit.Draft) (tableedit.Prepared, error) {
	return s.prepareMariaDBStructure(ctx, b, d, func(t tableedit.Target) (tableedit.Baseline, error) { return s.StructureLoad(ctx, t) }, false)
}
func (s *Session) StructurePrepareMigration(ctx context.Context, b tableedit.Baseline, d tableedit.Draft, load func(tableedit.Target) (tableedit.Baseline, error)) (tableedit.Prepared, error) {
	return tableedit.Prepared{}, errors.New("Guarded MariaDB multi-table migrations are deferred in this partial implementation. Use separately reviewed native SQL; no repair is generated.")
}
func (s *Session) prepareMariaDBStructure(ctx context.Context, b tableedit.Baseline, d tableedit.Draft, load func(tableedit.Target) (tableedit.Baseline, error), migration bool) (tableedit.Prepared, error) {
	out := tableedit.Prepared{Risks: []string{mariaDBDDLRisk, "Preview reads catalog metadata and validates expression boundaries; authored defaults and generated expressions execute only during Apply or subsequent native writes."}, ResultTarget: tableedit.ResultTarget(b.Target, d), DroppedTarget: d.DropTable}
	if b.Engine != "mariadb" || !tableedit.ValidBaseline(b) || d.ValidateForEngine("mariadb") != nil {
		return out, tableedit.ErrInvalid
	}
	if d.NeedsAuthoringV4() {
		return out, errors.New("Destructive column/table removal and type/encoding conversion are deferred for MariaDB. Use separately reviewed native SQL.")
	}
	for _, mode := range strings.Split(mariaDBStructureMode(b), ",") {
		if mode == "EMPTY_STRING_IS_NULL" || mode == "ORACLE" {
			return out, errors.New("This dedicated structure workflow cannot preserve its literal and parameter contract in EMPTY_STRING_IS_NULL or ORACLE mode. Use an explicitly reviewed compatible native SQL context; no mode is changed implicitly.")
		}
	}
	if d.NeedsAuthoringV5() {
		return out, errors.New("Backfill and physical reordering/reconstruction are deferred for MariaDB in this partial implementation; use separately reviewed native SQL.")
	}
	for _, column := range d.Columns {
		if column.Generated != nil && column.Generated.Storage != "none" || column.Identity != nil && column.Identity.Kind != "none" {
			return out, errors.New("Generated-column and AUTO_INCREMENT authoring are deferred in this partial MariaDB workflow; existing generated/identity metadata and table-grid behavior remain supported.")
		}
	}
	for _, change := range d.Changes {
		if change.Generated != nil || change.Identity != nil {
			return out, errors.New("Generated-column and AUTO_INCREMENT authoring are deferred in this partial MariaDB workflow; use separately reviewed native SQL.")
		}
	}
	if b.Advanced != nil {
		return out, errors.New("This native storage, partition or history kind needs its operation-specific preservation proof before this planner can prepare changes.")
	}
	if !b.Target.Create {
		if _, ok := mariaDBNativeStructure(b.NativeDefinition, mariaDBStructureMode(b), b.Target.Table); !ok {
			return out, errors.New("The complete native table definition has unmodeled clauses; use an explicitly reviewed native migration.")
		}
	}
	for _, change := range d.Changes {
		if change.Generated != nil {
			out.Consequences = append(out.Consequences, tableedit.Consequence{Kind: "valueGeneration", Object: b.Target.Table + "." + change.Name, Message: "The exact native generated expression is evaluated only during Apply or later writes. Its selected values may change; every other retained value and native counter must remain equal."})
		}
		if change.Identity != nil {
			out.Consequences = append(out.Consequences, tableedit.Consequence{Kind: "valueGeneration", Object: b.Target.Table + "." + change.Name, Message: "AUTO_INCREMENT creation/removal changes native future allocation and may reset its next counter. Existing IDs and current-session LAST_INSERT_ID remain exact; gaps are permitted, and no sequence value is advanced during Preview."})
		}
	}
	d, identityEnable, err := mariaDBIdentityDraft(b, d)
	if err != nil {
		return out, err
	}
	planner := tableedit.PlanOperations
	if migration {
		planner = tableedit.PlanMigrationOperations
	}
	ops, refs, e := planner(b, d, "mariadb", load)
	if e != nil {
		return out, e
	}
	ops = mariaDBIdentityOperations(ops, identityEnable)
	for _, edit := range d.Keys {
		if edit.Kind != "foreign" || edit.Action == "add" || b.Facts == nil {
			continue
		}
		for _, key := range b.Facts.Table.Constraints.Items {
			if key.Ref.Name != edit.Name || key.Target.Value == nil {
				continue
			}
			ref := tableedit.Target{Schema: key.Target.Value.Schema, Table: key.Target.Value.Name}
			if ref.Schema == b.Target.Schema && ref.Table == b.Target.Table {
				continue
			}
			found := false
			for _, prior := range refs {
				found = found || prior.Target.Schema == ref.Schema && prior.Target.Table == ref.Table
			}
			if !found {
				if len(refs) >= 16 {
					return out, tableedit.ErrUnsupported
				}
				observed, err := load(ref)
				if err != nil {
					return out, err
				}
				refs = append(refs, observed)
			}
		}
	}
	out.References = refs
	q := QuoteIdentifier(b.Target.Schema) + "." + QuoteIdentifier(b.Target.Table)
	for _, op := range ops {
		if e := ctx.Err(); e != nil {
			return out, e
		}
		sql := ""
		switch op.Kind {
		case "create":
			v, _, e := s.StructureRender(b, tableedit.Draft{AuthoringVersion: d.AuthoringVersion, Columns: d.Columns})
			if e != nil {
				return out, e
			}
			sql = strings.TrimPrefix(v[0], mariaDBDDLPrefix)
		case "addColumn":
			v, e := mariaDBStructureColumn(*op.Column)
			if e != nil {
				return out, e
			}
			sql = "ALTER TABLE " + q + " ADD COLUMN " + v + ";"
		case "dropColumn":
			sql = "ALTER TABLE " + q + " DROP COLUMN " + QuoteIdentifier(op.Change.Name) + ";"
			out.Consequences = append(out.Consequences, tableedit.Consequence{Kind: "dataLoss", Object: b.Target.Table + "." + op.Change.Name, Message: "The selected column and all of its stored values are permanently removed after native acknowledgement."})
		case "dropTable":
			sql = "DROP TABLE " + q + ";"
			out.Consequences = append(out.Consequences, tableedit.Consequence{Kind: "dataLoss", Object: b.Target.Table, Message: "The complete target table and its rows are permanently removed after native acknowledgement."})
		case "renameColumn":
			sql = "ALTER TABLE " + q + " RENAME COLUMN " + QuoteIdentifier(op.Change.Name) + " TO " + QuoteIdentifier(*op.Change.RenameTo) + ";"
		case "renameTable":
			sql = "RENAME TABLE " + q + " TO " + QuoteIdentifier(b.Target.Schema) + "." + QuoteIdentifier(*op.Name) + ";"
		case "changeColumn":
			change := op.Change
			if change.Type != nil || change.Nullable != nil || change.Generated != nil || change.Identity != nil || change.Unsigned != nil || change.Charset != nil || change.Collation != nil {
				var err error
				if _, exists := tableedit.FindColumn(b, change.Name); !exists && change.Identity != nil {
					for _, column := range d.Columns {
						if column.Name == change.Name {
							column.Identity = change.Identity
							var definition string
							definition, err = mariaDBStructureColumn(column)
							sql = "ALTER TABLE " + q + " MODIFY COLUMN " + definition + ";"
						}
					}
					if sql == "" {
						return out, tableedit.ErrUnsupported
					}
				} else {
					sql, err = mariaDBModifyColumn(ctx, b, *change)
				}
				if err != nil {
					return out, err
				}
				break
			}
			if change.Default == nil {
				return out, tableedit.ErrUnsupported
			}
			sql = "ALTER TABLE " + q + " ALTER COLUMN " + QuoteIdentifier(change.Name)
			if change.Default.Kind == "none" {
				sql += " DROP DEFAULT;"
			} else {
				old, ok := tableedit.FindColumn(b, change.Name)
				if !ok {
					return out, tableedit.ErrUnsupported
				}
				typ, ok := tableedit.ColumnType(old, "mariadb")
				if !ok || old.Nullable.Value == nil {
					return out, tableedit.ErrUnsupported
				}
				col := tableedit.Column{Name: change.Name, Type: typ, Nullable: *old.Nullable.Value, Default: *change.Default}
				rendered, e := mariaDBStructureColumn(col)
				if e != nil {
					return out, e
				}
				col.Default = tableedit.Default{Kind: "none"}
				prefix, e := mariaDBStructureColumn(col)
				if e != nil || !strings.HasPrefix(rendered, prefix+" DEFAULT ") {
					return out, tableedit.ErrUnsupported
				}
				sql += " SET DEFAULT " + strings.TrimPrefix(rendered, prefix+" DEFAULT ") + ";"
			}
		case "dropIndex":
			sql = "ALTER TABLE " + q + " DROP INDEX " + QuoteIdentifier(op.Index.Name) + ";"
		case "addIndex":
			if op.Index.Definition != nil {
				var err error
				sql, err = mariaDBRichIndex(tableedit.PlanningSource(b, d, "mariadb"), *op.Index)
				if err != nil {
					return out, err
				}
				break
			}
			sql = "CREATE INDEX " + QuoteIdentifier(op.Index.Name) + " USING BTREE ON " + q + " (" + mariaDBQuotedColumns(op.Index.Columns) + ");"
		case "dropKey":
			drop := "DROP INDEX " + QuoteIdentifier(op.Key.Name)
			if op.Key.Kind == "primary" {
				drop = "DROP PRIMARY KEY"
			}
			if op.Key.Kind == "foreign" {
				drop = "DROP FOREIGN KEY " + QuoteIdentifier(op.Key.Name)
			}
			sql = "ALTER TABLE " + q + " " + drop + ";"
		case "addKey":
			k := op.Key
			definition := "CONSTRAINT " + QuoteIdentifier(k.Name) + " "
			switch k.Kind {
			case "primary":
				definition = "PRIMARY KEY (" + mariaDBQuotedColumns(k.Columns) + ")"
			case "unique":
				definition += "UNIQUE (" + mariaDBQuotedColumns(k.Columns) + ")"
			case "foreign":
				enabled := false
				for _, o := range b.Facts.EngineContext {
					enabled = enabled || o.Name == "foreignKeyChecks" && o.Value == "1"
				}
				if !enabled {
					return out, errors.New("Foreign-key authoring requires foreign_key_checks=1 already active; no check is enabled or disabled implicitly.")
				}
				definition += "FOREIGN KEY (" + mariaDBQuotedColumns(k.Columns) + ") REFERENCES " + QuoteIdentifier(k.Reference.Schema) + "." + QuoteIdentifier(k.Reference.Table) + " (" + mariaDBQuotedColumns(k.ReferenceColumns) + ") ON UPDATE " + k.OnUpdate + " ON DELETE " + k.OnDelete
			default:
				return out, tableedit.ErrUnsupported
			}
			sql = "ALTER TABLE " + q + " ADD " + definition + ";"
		default:
			return out, tableedit.ErrUnsupported
		}
		if len(sql) == 0 {
			return out, tableedit.ErrInvalid
		}
		out.SQL = append(out.SQL, mariaDBDDLPrefix+sql)
		condition := tableedit.Condition{Operation: op}
		if op.Kind == "create" {
			condition.Columns = d.Columns
		}
		out.Conditions = append(out.Conditions, condition)
	}
	return out, nil
}
func mariaDBDefaultMatches(c sc.Column, want tableedit.Default, facts *tableedit.Facts) bool {
	if c.Default.Value == nil {
		return false
	}
	d := c.Default.Value
	switch want.Kind {
	case "none":
		return d.Kind == "none" || c.Nullable.Value != nil && *c.Nullable.Value && d.Kind == "sqlNull"
	case "null":
		return d.Kind == "sqlNull"
	case "text":
		return d.Kind == "literal" && d.Encoding == "text" && d.Value != nil && want.Value != nil && *d.Value == *want.Value
	case "numeric":
		if d.Kind != "literal" || d.Value == nil || want.Value == nil {
			return false
		}
		a, ok := new(big.Rat).SetString(*d.Value)
		b, other := new(big.Rat).SetString(*want.Value)
		return ok && other && a.Cmp(b) == 0
	case "boolean":
		return d.Kind == "literal" && d.Value != nil && want.Value != nil && (*want.Value == "true" && *d.Value == "1" || *want.Value == "false" && *d.Value == "0")
	case "expression":
		return d.Kind == "expression" && d.Expression != nil && want.Value != nil && tableedit.SameCatalogExpression("mariadb", d.Expression.Text, *want.Value, facts)
	}
	return false
}
func (s *Session) StructureApply(ctx context.Context, b tableedit.Baseline, sql []string) tableedit.Execution {
	return s.applyMariaDBStructureStep(ctx, b, sql, nil)
}
func (s *Session) applyMariaDBStructureStep(ctx context.Context, b tableedit.Baseline, sql []string, refs []tableedit.Baseline, conditions ...tableedit.Condition) tableedit.Execution {
	return s.applyMariaDBStructureUnit(ctx, b, sql, refs, false, conditions...)
}
func (s *Session) applyMariaDBStructureUnit(ctx context.Context, b tableedit.Baseline, sql []string, refs []tableedit.Baseline, preserve bool, conditions ...tableedit.Condition) tableedit.Execution {
	dispatched, applied := false, false
	proofMessage := ""
	response := s.executeWith(ctx, protocol.Command{Type: "structure.apply"}, func(_ *collector, _ *wire.Result) error {
		if len(sql) != 1 || !strings.HasPrefix(sql[0], mariaDBDDLPrefix) {
			return &adapter.ConnectionError{Category: "validation", Message: "The retained native DDL unit is invalid."}
		}
		for _, ref := range append(append([]tableedit.Baseline(nil), refs...), b) {
			fresh, e := s.readMariaDBStructure(ref.Target, s.readStructureFacts)
			if e != nil {
				return e
			}
			if fresh.Fingerprint != ref.Fingerprint {
				return &adapter.ConnectionError{Category: "conflict", Message: tableedit.ErrStale.Error()}
			}
		}
		var retained *mariaDBStructureRows
		excluded := []string{}
		if len(conditions) == 1 && conditions[0].Operation.Kind == "backfill" {
			if conditions[0].Operation.Name == nil {
				return tableedit.ErrUnsupported
			}
			excluded = append(excluded, *conditions[0].Operation.Name)
		}
		generation := len(conditions) == 1 && conditions[0].Operation.Change != nil && (conditions[0].Operation.Change.Generated != nil || conditions[0].Operation.Change.Identity != nil)
		if generation && conditions[0].Operation.Change.Generated != nil && conditions[0].Operation.Change.Generated.Storage != "none" {
			excluded = append(excluded, conditions[0].Operation.Change.Name)
		}
		if preserve || generation || len(conditions) == 1 && conditions[0].Operation.Kind == "reorder" {
			var e error
			retained, e = s.captureMariaDBStructureRows(b, excluded...)
			if e != nil {
				return e
			}
		}
		if ctx.Err() != nil {
			return &adapter.ConnectionError{Category: "cancelled", Message: "Cancelled before native DDL dispatch."}
		}
		dispatched = true
		execute := func() error {
			r, e := s.work.client.Execute(sql[0])
			if r != nil {
				r.Close()
			}
			return e
		}
		var err error
		if s.structureExecuteOverride != nil {
			err = s.structureExecuteOverride(execute)
		} else {
			err = execute()
		}
		if err != nil {
			return err
		}
		applied = true
		if retained != nil {
			after, e := s.captureMariaDBStructureRows(b, excluded...)
			if e != nil || !mariaDBStructureDataPreserved(b, retained, after, conditions) {
				proofMessage = "Native DDL was acknowledged, but exact retained rows, AUTO_INCREMENT or current-session LAST_INSERT_ID preservation could not be verified. Reconcile without rollback or retry assumptions."
				if e != nil {
					return e
				}
			}
		}
		return nil
	})
	if applied {
		return tableedit.Execution{State: "applied", Message: proofMessage}
	}
	if !dispatched {
		return tableedit.Execution{State: "notStarted", Message: "No native DDL was sent (" + response.Category + "). Reconcile and prepare a new preview."}
	}
	if response.OutcomeUnknown || !response.Connected {
		return tableedit.Execution{State: "unknown", Message: "Native DDL acknowledgement was lost; the change may have been applied. Reconcile without retrying."}
	}
	return tableedit.Execution{State: "failed", Message: "MariaDB rejected this DDL unit (SQLSTATE " + response.SQLState + "). Earlier acknowledged units are not rolled back; no retry was attempted."}
}
func (s *Session) StructureApplySteps(ctx context.Context, b tableedit.Baseline, p tableedit.Plan) []tableedit.Execution {
	if len(p.Conditions) != len(p.SQL) {
		return []tableedit.Execution{{State: "notStarted", Message: "The retained native preservation conditions are invalid."}}
	}
	current := b
	refs := append([]tableedit.Baseline(nil), p.References...)
	out := []tableedit.Execution{}
	for i, sql := range p.SQL {
		if ctx.Err() != nil {
			return append(out, tableedit.Execution{State: "notStarted", Message: "Cancelled before the next native DDL unit."})
		}
		preserve := p.Reconstruction != nil && p.Reconstruction.Method == "mariadb-native-backfill"
		x := s.applyMariaDBStructureUnit(ctx, current, []string{sql}, refs, preserve, p.Conditions[i])
		out = append(out, x)
		if x.State != "applied" || x.Message != "" {
			break
		}
		condition := p.Conditions[i]
		if condition.Operation.Kind == "dropTable" {
			target := current.Target
			target.Create = true
			fresh, e := s.StructureLoad(ctx, target)
			if e != nil || !fresh.Target.Create {
				out[i].Message = "DROP TABLE was acknowledged but absence could not be verified."
			}
			break
		}
		fresh, e := s.StructureLoad(ctx, tableedit.StepTarget(current.Target, condition))
		verified := e == nil && tableedit.ValidBaseline(fresh) && mariaDBTypedStructurePreserved(current, fresh, condition)
		if !current.Target.Create {
			verified = verified && mariaDBNativeStructurePreserved(current, fresh, condition)
		}
		if !verified {
			reason := "complete native definition preservation"
			if e != nil {
				reason = "native metadata observation"
			} else if !tableedit.ValidBaseline(fresh) {
				reason = "native metadata bounds"
			} else if !mariaDBTypedStructurePreserved(current, fresh, condition) {
				reason = "typed native transition"
			}
			out[i].Message = "DDL was acknowledged but " + reason + " did not match. Reconcile before further work; no rollback or retry is claimed."
			break
		}
		for j, ref := range refs {
			if ref.Target.Create && condition.Operation.Kind == "renameTable" && condition.Operation.Name != nil && ref.Target.Schema == current.Target.Schema && ref.Target.Table == *condition.Operation.Name {
				refs[j] = fresh
				continue
			}
			observed, err := s.StructureLoad(ctx, ref.Target)
			if err != nil || !mariaDBReferencePreserved(ref, observed, current, condition) {
				out[i].Message = "DDL was acknowledged but referenced native metadata changed unexpectedly."
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

var _ tableedit.Adapter = (*Session)(nil)
var _ tableedit.AdvancedAdapter = (*Session)(nil)
