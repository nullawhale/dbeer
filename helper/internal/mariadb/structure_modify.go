package mariadb

import (
	"context"
	sc "dbeer/helper/internal/schemacompare"
	"dbeer/helper/internal/tableedit"
	"encoding/json"
	"errors"
	"strings"
)

// MODIFY reproduces the full captured native column. Operation selection and
// postconditions remain separate from this pure, non-evaluating formatter.
func mariaDBModifyColumn(ctx context.Context, b tableedit.Baseline, change tableedit.ColumnChange) (string, error) {
	captured, ok := tableedit.FindColumn(b, change.Name)
	if !ok || b.Facts == nil || captured.Type.Value == nil || captured.Nullable.Value == nil || captured.Default.Value == nil {
		return "", tableedit.ErrUnsupported
	}
	if change.Generated != nil || change.Identity != nil {
		return mariaDBGenerationColumn(ctx, b, change)
	}
	if change.Unsigned != nil || change.Charset != nil || change.Collation != nil {
		return "", errors.New("This selected value-generating or conversion operation requires its native data preservation proof.")
	}
	if change.Type != nil && !tableedit.CanWiden(captured, *change.Type) {
		return "", tableedit.ErrUnsupported
	}
	if change.Nullable != nil && !*change.Nullable {
		strict := false
		for _, m := range strings.Split(mariaDBStructureMode(b), ",") {
			strict = strict || m == "STRICT_ALL_TABLES" || m == "STRICT_TRANS_TABLES"
		}
		if !strict {
			return "", errors.New("Requiring values needs an already active strict native SQL mode; no mode or stored value is changed implicitly.")
		}
	}
	raw, e := json.Marshal(captured)
	if e != nil {
		return "", e
	}
	var column sc.Column
	if json.Unmarshal(raw, &column) != nil {
		return "", tableedit.ErrUnsupported
	}
	if change.Type != nil {
		column.Type = sc.Known(tableedit.ExpectedChangedType("mariadb", *captured.Type.Value, change))
	}
	if change.Nullable != nil {
		column.Nullable = sc.Known(*change.Nullable)
		if !*change.Nullable && column.Default.Value.Kind == "sqlNull" {
			column.Default = sc.Known(sc.Default{Kind: "none"})
		}
	}
	if change.Default != nil {
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
			value.Encoding = "text"
			value.Type = column.Type.Value
		}
		column.Default = sc.Known(value)
	}
	definition, manual, e := RenderStructureColumnWithOptions(ctx, column, sc.Known(b.Facts.EngineContext), b.Facts.Table.Options)
	if e != nil {
		return "", e
	}
	if manual != "" {
		return "", errors.New(manual)
	}
	return "ALTER TABLE " + QuoteIdentifier(b.Target.Schema) + "." + QuoteIdentifier(b.Target.Table) + " MODIFY COLUMN " + strings.TrimSpace(definition) + ";", nil
}
