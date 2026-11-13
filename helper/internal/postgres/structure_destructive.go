package postgres

import (
	"context"
	"errors"
	"fmt"
	"strings"
	"time"

	"dbeer/helper/internal/tableedit"
	"github.com/jackc/pgx/v5"
)

func pgConversionChange(b tableedit.Baseline, change tableedit.ColumnChange, target string) (string, error) {
	if change.Unsigned != nil || change.Charset != nil {
		return "", fmt.Errorf("PostgreSQL has no unsigned integer attribute; table and database encoding cannot be changed by ALTER COLUMN. Use a separately reviewed database migration for encoding changes.")
	}
	old, ok := tableedit.FindColumn(b, change.Name)
	if !ok {
		return "", tableedit.ErrUnsupported
	}
	typ, ok := tableedit.ColumnType(old)
	if !ok {
		return "", tableedit.ErrUnsupported
	}
	if err := pgConversionStorageProof(b, change.Name, typ); err != nil {
		return "", err
	}
	if change.Type != nil {
		typ = *change.Type
	}
	definition, err := structureColumn(tableedit.Column{Name: change.Name, Type: typ, Nullable: true, Default: tableedit.Default{Kind: "none"}})
	if err != nil {
		return "", err
	}
	quote := pgx.Identifier{change.Name}.Sanitize()
	sql := "ALTER TABLE " + target + " ALTER COLUMN " + quote + " TYPE " + strings.TrimPrefix(definition, quote+" ")
	if typ.Kind == "text" || typ.Kind == "varchar" {
		collation := tableedit.TypeReference{Schema: "pg_catalog", Name: "default"}
		if old.Collation.Value != nil {
			collation = tableedit.TypeReference{Schema: old.Collation.Value.Schema, Name: old.Collation.Value.Name}
		}
		if change.Collation != nil {
			collation = *change.Collation
		}
		if !collation.Valid() {
			return "", tableedit.ErrInvalid
		}
		sql += " COLLATE " + pgx.Identifier{collation.Schema, collation.Name}.Sanitize()
	} else if change.Collation != nil {
		return "", fmt.Errorf("A PostgreSQL column collation requires a text or varchar target type.")
	}
	if change.UsingExpression != nil {
		if change.Type == nil {
			return "", fmt.Errorf("USING requires an explicit target type.")
		}
		expression, err := tableedit.ExpressionSlot("postgresql", *change.UsingExpression)
		if err != nil {
			return "", err
		}
		sql += " USING " + expression
	}
	return sql + ";", nil
}

func pgConversionStorageProof(b tableedit.Baseline, name string, source tableedit.DataType) error {
	attributes := b.Attributes[name]
	if attributes == nil {
		return nil
	}
	storage, ok := attributes["attstorage"].(string)
	if b.Facts == nil || !ok || b.Facts.TypeStorage[source.Kind] == "" || storage != b.Facts.TypeStorage[source.Kind] {
		return fmt.Errorf("Column %s has custom or unproven storage settings. ALTER TYPE, including COLLATE changes, resets them; preserve that policy in an explicit reviewed migration.", name)
	}
	compression, ok := attributes["attcompression"].(string)
	if !ok || compression != "" && compression != "\x00" {
		return fmt.Errorf("Column %s has explicit or unproven compression settings. ALTER TYPE, including COLLATE changes, resets compression; use an explicit reviewed migration to preserve it.", name)
	}
	return nil
}

func (s *Session) pgDestructiveReview(ctx context.Context, b tableedit.Baseline, d tableedit.Draft, out *tableedit.Prepared) error {
	out.DroppedTarget = d.DropTable
	object := pgx.Identifier{b.Target.Schema, b.Target.Table}.Sanitize()
	consequence := func(kind, name, message string) {
		out.Consequences = append(out.Consequences, tableedit.Consequence{Kind: kind, Object: name, Message: message})
	}
	if d.NeedsAuthoringV4() {
		for _, x := range d.Indexes {
			if x.Action != "add" {
				consequence("dependency", x.Name, "This explicitly selected index removal is an earlier independent DDL step. Its removal remains acknowledged if a later conversion or column drop fails.")
			}
		}
		for _, x := range d.Keys {
			if x.Action != "add" {
				consequence("dependency", x.Name, "This explicitly selected constraint and any owned backing index are removed in an earlier independent step. Their removal is not undone by a later failure.")
			}
		}
	}
	if d.DropTable {
		consequence("dataLoss", object, "DROP TABLE removes every stored row, all columns, local constraints, indexes and owned identity/serial sequences. Discard cannot restore an acknowledged drop. RESTRICT is used; external dependents are never removed automatically.")
		if b.Facts != nil {
			for _, x := range b.Facts.Table.Indexes.Items {
				consequence("dependency", x.Ref.Name, "This local index is removed with its table.")
			}
			for _, x := range b.Facts.Table.Constraints.Items {
				consequence("dependency", x.Ref.Name, "This local constraint is removed with its table.")
			}
			for _, x := range b.Facts.Sequences {
				consequence("dependency", pgx.Identifier{x.Ref.Schema, x.Ref.Name}.Sanitize(), "This table-owned sequence is removed with its table; its current counter is not restored by Discard.")
			}
		}
		out.ValidationChecks = append(out.ValidationChecks, pgUnavailableCheck("dropTable", "Table deletion", "A row scan cannot establish that deleting a table is safe. Review backups, application dependencies and the exact DROP statement."))
	}
	for _, change := range d.Changes {
		name := object + "." + pgx.Identifier{change.Name}.Sanitize()
		if change.Drop {
			consequence("dataLoss", name, "DROP COLUMN permanently removes all values in this column. Explicitly selected dependent keys and indexes are earlier steps; RESTRICT prevents automatic external dependency removal.")
			if b.Facts != nil {
				for _, sequence := range b.Facts.Sequences {
					if sequence.Owner.Value != nil && sequence.Owner.Value.Name == change.Name {
						consequence("dependency", pgx.Identifier{sequence.Ref.Schema, sequence.Ref.Name}.Sanitize(), "This column-owned sequence is removed with the column; its current counter is not restored by Discard.")
					}
				}
			}
			out.ValidationChecks = append(out.ValidationChecks, pgUnavailableCheck("dropColumn-"+tableedit.Fingerprint(change.Name)[:16], "Column deletion: "+change.Name, "A row scan cannot establish that deleting a column is safe. No values are read during Preview."))
			continue
		}
		if change.Type == nil && change.UsingExpression == nil && change.Collation == nil && change.Unsigned == nil && change.Charset == nil {
			continue
		}
		if change.Unsigned != nil || change.Charset != nil {
			return fmt.Errorf("PostgreSQL unsignedness and column encoding changes are unavailable: integer types are signed and database encoding is fixed. Use an explicit reviewed migration.")
		}
		if change.Type != nil || change.UsingExpression != nil {
			consequence("conversion", name, "Existing values are converted by PostgreSQL. Narrowing may reject values; numeric casts may round; varchar casts or USING may truncate or replace values. DDL can scan/rewrite the table, resets column statistics and uses target-type default storage/compression. Preview does not evaluate expressions or read rows.")
			out.ValidationChecks = append(out.ValidationChecks, pgConversionCheck(b, change))
		}
		old, ok := tableedit.FindColumn(b, change.Name)
		if !ok {
			return tableedit.ErrUnsupported
		}
		typ, ok := tableedit.ColumnType(old)
		if change.Type != nil {
			typ = *change.Type
		}
		if !ok {
			return tableedit.ErrUnsupported
		}
		if change.Collation != nil {
			consequence("comparison", name, "Changing collation changes ordering, equality and future constraint/index semantics. A value scan cannot prove application-level equivalence or future uniqueness.")
			out.ValidationChecks = append(out.ValidationChecks, pgUnavailableCheck("collation-"+tableedit.Fingerprint(change.Name)[:16], "Collation semantics: "+change.Name, "Collation changes affect comparison semantics. No finite row check proves future equality, uniqueness or application behavior."))
		}
		if typ.Kind == "text" || typ.Kind == "varchar" {
			ref := tableedit.TypeReference{Schema: "pg_catalog", Name: "default"}
			if old.Collation.Value != nil {
				ref = tableedit.TypeReference{Schema: old.Collation.Value.Schema, Name: old.Collation.Value.Name}
			}
			if change.Collation != nil {
				ref = *change.Collation
			}
			guard, err := resolveIndexGuard(ctx, s.conn, "collation", ref, "")
			if err != nil {
				return err
			}
			out.IndexGuards = append(out.IndexGuards, guard)
		}
	}
	return nil
}

func pgUnavailableCheck(id, summary, reason string) tableedit.ValidationCheck {
	return tableedit.ValidationCheck{ID: id, Summary: summary, Risks: []string{}, UnavailableReason: &reason}
}

func pgConversionCheck(b tableedit.Baseline, change tableedit.ColumnChange) tableedit.ValidationCheck {
	id := "conversion-" + tableedit.Fingerprint(change.Name)[:16]
	summary := "Existing-value representability: " + change.Name
	unavailable := func(reason string) tableedit.ValidationCheck { return pgUnavailableCheck(id, summary, reason) }
	if change.UsingExpression != nil {
		return unavailable("Arbitrary USING expressions may execute user code, change values or have side effects. Validation never evaluates them; use a separately reviewed migration and dedicated validation SQL.")
	}
	old, found := tableedit.FindColumn(b, change.Name)
	if !found || old.Type.Value == nil || old.Type.Value.Kind != "builtin" || old.Type.Value.Ref.Schema != "pg_catalog" || change.Type == nil {
		return unavailable("Only captured built-in scalar conversion checks are available; custom types and support routines are never invoked by validation.")
	}
	if !tableedit.PostgresBuiltinIdentity(old, b.Attributes[change.Name]) {
		return unavailable("The captured PostgreSQL source type identity differs from the trusted built-in type; no validation SQL is prepared.")
	}

	source, ok := tableedit.ColumnType(old)
	if !ok {
		return unavailable("The captured source type has no supported scalar validation rule.")
	}
	column := pgx.Identifier{change.Name}.Sanitize()
	var predicate string
	want := *change.Type
	numeric := source.Kind == "integer" || source.Kind == "bigint" || source.Kind == "numeric"
	switch {
	case want.Kind == "varchar" && (source.Kind == "varchar" || source.Kind == "text"):
		predicate = fmt.Sprintf("pg_catalog.char_length(%s) OPERATOR(pg_catalog.>) %d", column, want.Length)
	case numeric && (want.Kind == "integer" || want.Kind == "bigint"):
		minimum, maximum := "-2147483648", "2147483647"
		if want.Kind == "bigint" {
			minimum, maximum = "-9223372036854775808", "9223372036854775807"
		}
		value := column + "::pg_catalog.numeric"
		predicate = value + " OPERATOR(pg_catalog.<) '" + minimum + "'::pg_catalog.numeric OR " + value + " OPERATOR(pg_catalog.>) '" + maximum + "'::pg_catalog.numeric OR " + value + " OPERATOR(pg_catalog.<>) pg_catalog.trunc(" + value + ")"
	case numeric && want.Kind == "numeric":
		value := column + "::pg_catalog.numeric"
		bound := "1" + strings.Repeat("0", want.Precision-want.Scale)
		predicate = fmt.Sprintf("pg_catalog.abs(%s) OPERATOR(pg_catalog.>=) '%s'::pg_catalog.numeric OR %s OPERATOR(pg_catalog.<>) pg_catalog.round(%s,%d)", value, bound, value, value, want.Scale)
	case want.Kind == "text" && (source.Kind == "text" || source.Kind == "varchar"):
		predicate = "false"
	default:
		return unavailable("This conversion may fail or change meaning in a type-specific way. No safe built-in representability check is provided; validation does not attempt casts that could abort or invoke custom code.")
	}
	sql := "SELECT pg_catalog.count(*)::pg_catalog.text FROM " + pgx.Identifier{b.Target.Schema, b.Target.Table}.Sanitize() + " WHERE " + column + " IS NOT NULL AND (" + predicate + ");"
	return tableedit.ValidationCheck{ID: id, Summary: summary, SQL: &sql, Risks: []string{"Scans existing values in a read-only repeatable-read transaction with a 30-second statement/operation limit and a 5-second lock wait. Returns only an exact invalid-row count. A passing check is a snapshot observation, does not authorize Apply, and does not prove future values or complete DDL success."}}
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
	tx, err := s.conn.BeginTx(ctx, pgx.TxOptions{IsoLevel: pgx.RepeatableRead, AccessMode: pgx.ReadOnly})
	if err != nil {
		return pgValidationStopped(ctx, out)
	}
	defer func() {
		cleanup, stop := context.WithTimeout(context.Background(), 3*time.Second)
		defer stop()
		if err := tx.Rollback(cleanup); err != nil && !errors.Is(err, pgx.ErrTxClosed) {
			closeConnection(s.conn)
		}
	}()
	for _, statement := range []string{"SET LOCAL lock_timeout = '5s'", "SET LOCAL statement_timeout = '30s'", "LOCK TABLE " + pgx.Identifier{b.Target.Schema, b.Target.Table}.Sanitize() + " IN ACCESS SHARE MODE"} {
		if _, err = tx.Exec(ctx, statement); err != nil {
			return pgValidationStopped(ctx, out)
		}
	}
	fresh, err := readStructure(ctx, tx, b.Target)
	if err != nil || fresh.Fingerprint != b.Fingerprint || !verifyIndexGuards(ctx, tx, plan.IndexGuards) {
		for i := range out {
			if out[i].State == "notStarted" {
				out[i].Message = "The retained metadata changed. Prepare a fresh preview before validation."
			}
		}
		return pgValidationStopped(ctx, out)
	}
	for i, check := range plan.ValidationChecks {
		if out[i].State != "notStarted" {
			continue
		}
		if ctx.Err() != nil {
			return pgValidationStopped(ctx, out)
		}
		var count string
		if err = tx.QueryRow(ctx, *check.SQL).Scan(&count); err != nil {
			out[i].State, out[i].Message = "failed", "The read-only validation query did not complete. No DDL was sent."
			if ctx.Err() != nil {
				out[i].State, out[i].Message = "cancelled", "Validation was cancelled. No DDL was sent."
			}
			return pgValidationStopped(ctx, out)
		}
		if count == "" || strings.Trim(count, "0123456789") != "" {
			out[i].State, out[i].Message = "failed", "The validation count could not be confirmed. No DDL was sent."
			return out
		}
		out[i].State, out[i].InvalidRows = "passed", &count
		out[i].Message = "No existing non-NULL values failed this snapshot check; Apply is not authorized."
		if count != "0" {
			out[i].State, out[i].Message = "failed", "Existing non-NULL values may be rejected, rounded or truncated by this conversion. No DDL was sent."
		}
	}
	return out
}

func pgValidationStopped(ctx context.Context, out []tableedit.ValidationResult) []tableedit.ValidationResult {
	if ctx.Err() != nil {
		for i := range out {
			if out[i].State == "notStarted" {
				out[i].State, out[i].Message = "cancelled", "Validation was cancelled before this check. No DDL was sent."
			}
		}
	}
	return out
}
