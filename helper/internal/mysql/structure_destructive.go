package mysql

import (
	"context"
	"encoding/json"
	"fmt"
	"regexp"
	"strings"
	"time"

	"dbeer/helper/internal/adapter"
	"dbeer/helper/internal/protocol"
	sc "dbeer/helper/internal/schemacompare"
	"dbeer/helper/internal/syncplan"
	"dbeer/helper/internal/tableedit"
	wire "github.com/go-mysql-org/go-mysql/mysql"
)

var structureCharsetName = regexp.MustCompile(`^[a-zA-Z][a-zA-Z0-9_]{0,63}$`)

func mysqlConversionChange(ctx context.Context, b tableedit.Baseline, change tableedit.ColumnChange, target string) ([]string, error) {
	if change.UsingExpression != nil {
		return nil, fmt.Errorf("MySQL MODIFY COLUMN has no PostgreSQL USING clause. Use a separately reviewed migration for expression-based value conversion.")
	}
	captured, ok := tableedit.FindColumn(b, change.Name)
	if !ok || b.Facts == nil {
		return nil, tableedit.ErrUnsupported
	}
	raw, _ := json.Marshal(captured)
	var c sc.Column
	if json.Unmarshal(raw, &c) != nil || c.Type.Value == nil || c.Type.Value.Modifiers.Value == nil {
		return nil, tableedit.ErrUnsupported
	}
	typ, ok := tableedit.ColumnType(c)
	if !ok {
		return nil, tableedit.ErrUnsupported
	}
	if change.Generated != nil || change.Identity != nil || change.Nullable != nil || change.Default != nil {
		return nil, fmt.Errorf("Review lossy type, signedness, charset and collation conversion separately from generation, identity, defaults and nullability changes.")
	}
	if change.Type != nil {
		typ = *change.Type
	}
	c.Type = sc.Known(tableedit.ExpectedChangedType("mysql", *c.Type.Value, change))
	if change.Unsigned != nil {
		if typ.Kind != "integer" && typ.Kind != "bigint" && typ.Kind != "numeric" {
			return nil, fmt.Errorf("UNSIGNED requires an integer or decimal target type.")
		}
		c.Type.Value.Modifiers.Value.Unsigned = *change.Unsigned
	}
	if typ.Kind == "bigint" && c.Type.Value.Modifiers.Value.Unsigned {
		p := int64(20)
		c.Type.Value.Modifiers.Value.Precision = &p
	}
	if typ.Kind != "text" && typ.Kind != "varchar" {
		if change.Charset != nil || change.Collation != nil {
			return nil, fmt.Errorf("Charset and collation conversion require a text or varchar target type.")
		}
		c.Charset, c.Collation, c.CollationProperties = sc.Absent[string](), sc.Absent[sc.Ref](), nil
	} else {
		if (c.Charset.Value == nil || c.Collation.Value == nil) && (change.Charset == nil || change.Collation == nil) {
			return nil, fmt.Errorf("Converting a non-character column to character data requires an explicit reviewed migration with charset/default preservation proof.")
		}
		if change.Charset != nil {
			if !structureCharsetName.MatchString(*change.Charset) || change.Collation == nil {
				return nil, fmt.Errorf("Charset conversion requires an explicit valid charset and its exact target collation; Preview does not choose an implicit default.")
			}
			c.Charset = sc.Known(*change.Charset)
		}
		if change.Collation != nil {
			if change.Collation.Schema != "" || !structureCharsetName.MatchString(change.Collation.Name) {
				return nil, fmt.Errorf("MySQL collations use an unqualified server collation name.")
			}
			c.Collation = sc.Known(sc.Ref{Kind: "collation", Name: change.Collation.Name})
		}
	}
	if reason := syncplan.SchemaFactsReason(c); reason != "" {
		return nil, fmt.Errorf("MySQL MODIFY cannot preserve every unchanged column attribute: %s", reason)
	}
	renderer := myDefinition{w: &sc.DefinitionWriter{Context: ctx}, engine: sc.Known(b.Facts.EngineContext)}
	renderer.column(c)
	definition, err := renderer.w.Finish()
	if err != nil || definition.Limited {
		return nil, tableedit.ErrUnsupported
	}
	return []string{"ALTER TABLE " + target + " MODIFY COLUMN " + strings.TrimSpace(definition.SQL) + ";"}, nil
}

func (s *Session) mysqlDestructiveReview(ctx context.Context, b tableedit.Baseline, d tableedit.Draft, out *tableedit.Prepared) error {
	out.DroppedTarget = d.DropTable
	object := QuoteIdentifier(b.Target.Schema) + "." + QuoteIdentifier(b.Target.Table)
	consequence := func(kind, name, message string) {
		out.Consequences = append(out.Consequences, tableedit.Consequence{Kind: kind, Object: name, Message: message})
	}
	if d.NeedsAuthoringV4() {
		for _, x := range d.Indexes {
			if x.Action != "add" {
				consequence("dependency", x.Name, "This explicitly selected index removal is an earlier implicitly committed step. A later conversion or column drop failure does not restore the index.")
			}
		}
		for _, x := range d.Keys {
			if x.Action != "add" {
				consequence("dependency", x.Name, "This explicitly selected constraint and any owned backing index are removed in an earlier implicitly committed step. A later failure does not restore them.")
			}
		}
	}
	if d.DropTable {
		consequence("dataLoss", object, "DROP TABLE permanently removes every stored row, all columns, local constraints, indexes and table triggers. MySQL implicitly commits DDL; Stop and Discard cannot restore the table. External dependents are never removed automatically and foreign-key checks remain enabled.")
		if b.Facts != nil {
			for _, x := range b.Facts.Table.Indexes.Items {
				consequence("dependency", x.Ref.Name, "This local index is removed with its table.")
			}
			for _, x := range b.Facts.Table.Constraints.Items {
				consequence("dependency", x.Ref.Name, "This local constraint is removed with its table.")
			}
		}
		out.ValidationChecks = append(out.ValidationChecks, mysqlUnavailableCheck("dropTable", "Table deletion", "A row scan cannot establish that deleting a table is safe. Review backups, application dependencies and the exact DROP statement."))
	}
	for _, change := range d.Changes {
		name := object + "." + QuoteIdentifier(change.Name)
		if change.Drop {
			consequence("dataLoss", name, "DROP COLUMN permanently removes all values in the column. Explicitly selected dependent keys and indexes are earlier steps; no foreign-key checks are disabled and no dependency is removed implicitly by this plan.")
			out.ValidationChecks = append(out.ValidationChecks, mysqlUnavailableCheck("dropColumn-"+tableedit.Fingerprint(change.Name)[:16], "Column deletion: "+change.Name, "A row scan cannot establish that deleting a column is safe. No values are read during Preview."))
			continue
		}
		if change.Type == nil && change.Unsigned == nil && change.Charset == nil && change.Collation == nil && change.UsingExpression == nil {
			continue
		}
		if change.UsingExpression != nil {
			return fmt.Errorf("MySQL has no PostgreSQL USING clause; use a separately reviewed migration for expression-based conversion.")
		}
		consequence("conversion", name, "MODIFY COLUMN converts existing values and can rebuild the table. Narrowing, signedness or encoding changes can reject, round, truncate or replace values according to the captured SQL mode. Preview does not read values or test conversions; unchanged attributes are rendered from complete captured facts.")
		if change.Collation != nil {
			consequence("comparison", name, "Changing collation changes ordering and equality, including future uniqueness semantics. A passing value check does not prove equivalent application behavior.")
		}
		if change.Charset != nil || change.Collation != nil {
			if err := s.mysqlConversionCharset(ctx, b, change); err != nil {
				return err
			}
		}
		out.ValidationChecks = append(out.ValidationChecks, mysqlConversionChecks(b, change)...)
	}
	return nil
}

func (s *Session) mysqlConversionCharset(ctx context.Context, b tableedit.Baseline, change tableedit.ColumnChange) error {
	old, ok := tableedit.FindColumn(b, change.Name)
	if !ok || (old.Charset.Value == nil || old.Collation.Value == nil) && (change.Charset == nil || change.Collation == nil) {
		return tableedit.ErrUnsupported
	}
	charset, collation := "", ""
	if old.Charset.Value != nil && old.Collation.Value != nil {
		charset, collation = *old.Charset.Value, old.Collation.Value.Name
	}
	if change.Charset != nil {
		if change.Collation == nil {
			return fmt.Errorf("Choose an explicit collation together with the target charset.")
		}
		charset = *change.Charset
	}
	if change.Collation != nil {
		if change.Collation.Schema != "" {
			return fmt.Errorf("MySQL collations use an unqualified server collation name.")
		}
		collation = change.Collation.Name
	}
	if !structureCharsetName.MatchString(charset) || !structureCharsetName.MatchString(collation) {
		return tableedit.ErrInvalid
	}
	var lookup error
	response := s.executeWith(ctx, protocol.Command{}, func(_ *collector, _ *wire.Result) error {
		result, err := s.work.client.Execute(`SELECT CHARACTER_SET_NAME,COLLATION_NAME FROM information_schema.COLLATIONS WHERE BINARY CHARACTER_SET_NAME=BINARY ? AND BINARY COLLATION_NAME=BINARY ?`, charset, collation)
		if err != nil {
			lookup = tableedit.ErrUnsupported
			return err
		}
		defer result.Close()
		if result.RowNumber() != 1 {
			lookup = fmt.Errorf("The exact target collation is unavailable for the selected charset.")
			return nil
		}
		actualCharset, e1 := ownedStructureString(result, 0, 0)
		actualCollation, e2 := ownedStructureString(result, 0, 1)
		if result.RowNumber() != 1 || e1 != nil || e2 != nil || actualCharset != charset || actualCollation != collation {
			lookup = fmt.Errorf("The exact target collation is unavailable for the selected charset.")
		}
		return nil
	})
	if lookup != nil {
		return lookup
	}
	if response.Type == "error" {
		return tableedit.ErrUnsupported
	}
	return nil
}

func mysqlUnavailableCheck(id, summary, reason string) tableedit.ValidationCheck {
	return tableedit.ValidationCheck{ID: id, Summary: summary, Risks: []string{}, UnavailableReason: &reason}
}

func mysqlConversionChecks(b tableedit.Baseline, change tableedit.ColumnChange) []tableedit.ValidationCheck {
	id := "conversion-" + tableedit.Fingerprint(change.Name)[:16]
	summary := "Existing-value representability: " + change.Name
	unavailable := func(reason string) []tableedit.ValidationCheck {
		return []tableedit.ValidationCheck{mysqlUnavailableCheck(id, summary, reason)}
	}
	old, found := tableedit.FindColumn(b, change.Name)
	if !found || old.Type.Value == nil || old.Type.Value.Kind != "builtin" || old.Type.Value.Modifiers.Value == nil {
		return unavailable("Only captured built-in scalar checks are supported. Validation never evaluates authored expressions or custom routines.")
	}
	source, ok := tableedit.ColumnType(old)
	if !ok {
		return unavailable("The captured source type has no supported scalar validation rule.")
	}
	want := source
	if change.Type != nil {
		want = *change.Type
	}
	unsigned := old.Type.Value.Modifiers.Value.Unsigned
	if change.Unsigned != nil {
		unsigned = *change.Unsigned
	}
	column := QuoteIdentifier(change.Name)
	predicates := []string{}
	numeric := source.Kind == "integer" || source.Kind == "bigint" || source.Kind == "numeric"
	if change.Type != nil || change.Unsigned != nil {
		switch {
		case want.Kind == "varchar" && (source.Kind == "varchar" || source.Kind == "text"):
			predicates = append(predicates, fmt.Sprintf("CHAR_LENGTH(%s) > %d", column, want.Length))
		case numeric && (want.Kind == "integer" || want.Kind == "bigint"):
			minimum, maximum := "-2147483648", "2147483647"
			if unsigned {
				minimum, maximum = "0", "4294967295"
			}
			if want.Kind == "bigint" {
				minimum, maximum = "-9223372036854775808", "9223372036854775807"
				if unsigned {
					minimum, maximum = "0", "18446744073709551615"
				}
			}
			predicates = append(predicates, column+" < "+minimum+" OR "+column+" > "+maximum+" OR "+column+" <> TRUNCATE("+column+",0)")
		case numeric && want.Kind == "numeric":
			bound := "1" + strings.Repeat("0", want.Precision-want.Scale)
			predicates = append(predicates, fmt.Sprintf("%s <= -%s OR %s >= %s OR %s <> ROUND(%s,%d)", column, bound, column, bound, column, column, want.Scale))
			if unsigned {
				predicates = append(predicates, column+" < 0")
			}
		case want.Kind == "text" && (source.Kind == "text" || source.Kind == "varchar"):
			// TEXT has a byte limit, unlike VARCHAR's character limit.
			predicates = append(predicates, "OCTET_LENGTH("+column+") > 65535")
		default:
			return unavailable("This conversion may fail or change meaning in a type-specific way. No safe built-in representability check is provided; validation does not attempt arbitrary casts.")
		}
	}
	if change.Charset != nil {
		if old.Charset.Value == nil || !structureCharsetName.MatchString(*old.Charset.Value) || !structureCharsetName.MatchString(*change.Charset) {
			return unavailable("The source and target charset are not both captured supported server identifiers.")
		}
		converted := "CONVERT(" + column + " USING " + QuoteIdentifier(*change.Charset) + ")"
		predicates = append(predicates, "BINARY CONVERT("+converted+" USING "+QuoteIdentifier(*old.Charset.Value)+") <> BINARY "+column)
		if want.Kind == "text" {
			predicates = append(predicates, "OCTET_LENGTH("+converted+") > 65535")
		}
	}
	checks := []tableedit.ValidationCheck{}
	if len(predicates) > 0 {
		sql := "SELECT /*+ MAX_EXECUTION_TIME(30000) */ CAST(COUNT(*) AS CHAR CHARACTER SET ascii) FROM " + QuoteIdentifier(b.Target.Schema) + "." + QuoteIdentifier(b.Target.Table) + " WHERE " + column + " IS NOT NULL AND ((" + strings.Join(predicates, ") OR (") + "));"
		checks = append(checks, tableedit.ValidationCheck{ID: id, Summary: summary, SQL: &sql, Risks: []string{"Scans existing values in a read-only consistent snapshot with a 30-second operation/query limit and a 5-second metadata lock wait. Returns only an exact invalid-row count; charset round trips can produce server warnings. A passing check is a snapshot observation, does not authorize Apply, and cannot prove future values or complete DDL success."}})
	}
	if change.Collation != nil {
		checks = append(checks, mysqlUnavailableCheck("collation-"+tableedit.Fingerprint(change.Name)[:16], "Collation semantics: "+change.Name, "Collation changes affect ordering and equality. A finite row check cannot prove future uniqueness or equivalent application behavior."))
	}
	return checks
}

func (s *Session) StructureValidate(ctx context.Context, b tableedit.Baseline, plan tableedit.Plan) []tableedit.ValidationResult {
	ctx, cancel := context.WithTimeout(ctx, 30*time.Second)
	defer cancel()
	out := make([]tableedit.ValidationResult, len(plan.ValidationChecks))
	active := false
	for i, check := range plan.ValidationChecks {
		out[i] = tableedit.ValidationResult{ID: check.ID, State: "notStarted", Message: "Validation was not started."}
		if check.UnavailableReason != nil || check.SQL == nil {
			out[i].State = "unavailable"
			if check.UnavailableReason != nil {
				out[i].Message = *check.UnavailableReason
			}
		} else {
			active = true
		}
	}
	if !active {
		return out
	}
	if s.TransactionStatus() != "idle" {
		return out
	}
	_ = s.executeWith(ctx, protocol.Command{Type: "structure.validate"}, func(_ *collector, _ *wire.Result) error {
		for _, statement := range []string{"SET SESSION lock_wait_timeout=5", "SET SESSION TRANSACTION ISOLATION LEVEL REPEATABLE READ", "START TRANSACTION WITH CONSISTENT SNAPSHOT, READ ONLY", "SELECT 1 FROM " + QuoteIdentifier(b.Target.Schema) + "." + QuoteIdentifier(b.Target.Table) + " LIMIT 0"} {
			result, err := s.work.client.Execute(statement)
			if err != nil {
				return err
			}
			result.Close()
			if strings.HasPrefix(statement, "START TRANSACTION") {
				defer s.dataRollback()
			}
		}
		fresh, err := s.readStructure(b.Target)
		if err != nil || fresh.Fingerprint != b.Fingerprint {
			for i := range out {
				if out[i].State == "notStarted" {
					out[i].Message = "The retained metadata changed. Prepare a fresh preview before validation."
				}
			}
			return &adapter.ConnectionError{Category: "conflict", Message: tableedit.ErrStale.Error()}
		}
		for i, check := range plan.ValidationChecks {
			if out[i].State != "notStarted" {
				continue
			}
			if ctx.Err() != nil {
				return &adapter.ConnectionError{Category: "cancelled", Message: "Validation was cancelled before this check."}
			}
			result, err := s.work.client.Execute(*check.SQL)
			if err != nil {
				out[i].State, out[i].Message = "failed", "The read-only validation query did not complete. No DDL was sent."
				if ctx.Err() != nil {
					out[i].State, out[i].Message = "cancelled", "Validation was cancelled. No DDL was sent."
				}
				return err
			}
			count, e := ownedStructureString(result, 0, 0)
			rows := result.RowNumber()
			result.Close()
			if e != nil || rows != 1 || count == "" || strings.Trim(count, "0123456789") != "" {
				out[i].State, out[i].Message = "failed", "The validation count could not be confirmed. No DDL was sent."
				return &adapter.ConnectionError{Category: "validation", Message: out[i].Message}
			}
			out[i].State, out[i].InvalidRows, out[i].Message = "passed", &count, "No existing non-NULL values failed this snapshot check; Apply is not authorized."
			if count != "0" {
				out[i].State, out[i].Message = "failed", "Existing non-NULL values may be rejected, rounded, truncated or replaced by this conversion. No DDL was sent."
			}
		}
		return nil
	})
	if ctx.Err() != nil {
		for i := range out {
			if out[i].State == "notStarted" {
				out[i].State, out[i].Message = "cancelled", "Validation was cancelled before this check. No DDL was sent."
			}
		}
	}
	return out
}
