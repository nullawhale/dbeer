package mysql

import (
	"context"
	"strings"
	"testing"

	sc "dbeer/helper/internal/schemacompare"
	"dbeer/helper/internal/syncplan"
)

func TestSynchronizationMySQLCreatesAndTargetLiteralMode(t *testing.T) {
	capture, table := myDefinitionCapture()
	column := myDefinitionColumn(table.Ref, "value", "text")
	column.Comment = sc.Known("quote' plain")
	table.Columns = sc.Complete([]sc.Column{column})
	capture.Tables = []sc.Table{table}
	target := capture
	target.Context.EngineContext = sc.Known([]sc.Option{{Name: "sqlMode", Value: "NO_BACKSLASH_ESCAPES"}})
	sql, reason, err := RenderSynchronizationSchema(context.Background(), syncplan.SchemaOperation{Action: "create", Ref: table.Ref, Source: capture, Target: target})
	if err != nil || reason != "" || !strings.Contains(sql, "CREATE TABLE `app``db`.`orders`") || !strings.Contains(sql, `COMMENT 'quote'' plain'`) {
		t.Fatal("typed create/target mode", sql, reason, err)
	}
	added := myDefinitionColumn(table.Ref, "new", "int")
	added.Ordinal = sc.Known(1)
	table.Columns = sc.Complete([]sc.Column{column, added})
	desired := capture
	desired.Tables = []sc.Table{table}
	sql, reason, err = RenderSynchronizationSchema(context.Background(), syncplan.SchemaOperation{Action: "create", Ref: added.Ref, Source: desired, Target: target})
	if err != nil || reason != "" || !strings.Contains(sql, "ADD COLUMN `new` INT") || !strings.Contains(sql, "AFTER `value`;") {
		t.Fatal("ordinal add", sql, reason, err)
	}
	added.Ordinal = sc.Known(0)
	table.Columns = sc.Complete([]sc.Column{added})
	desired.Tables = []sc.Table{table}
	sql, reason, err = RenderSynchronizationSchema(context.Background(), syncplan.SchemaOperation{Action: "create", Ref: added.Ref, Source: desired, Target: target})
	if err != nil || reason != "" || !strings.Contains(sql, " FIRST;") {
		t.Fatal("zero-based first ordinal", sql, reason, err)
	}
}

func TestSynchronizationMySQLUnsupportedNeverReturnsPartialSQL(t *testing.T) {
	capture, table := myDefinitionCapture()
	column := myDefinitionColumn(table.Ref, "value", "int")
	column.Identity = sc.Known(sc.Identity{Kind: "autoIncrement"})
	table.Columns = sc.Complete([]sc.Column{column})
	capture.Tables = []sc.Table{table}
	for _, action := range []string{"create", "drop", "alter"} {
		sql, reason, err := RenderSynchronizationSchema(context.Background(), syncplan.SchemaOperation{Action: action, Ref: table.Ref, Source: capture, Target: capture})
		if err != nil || reason == "" || sql != "" {
			t.Fatal("unsupported returned SQL", action, sql, reason, err)
		}
	}
	column.Identity = sc.Known(sc.Identity{Kind: "none"})
	expression := sc.Expression{Text: "current_timestamp()", Dependencies: sc.Complete[sc.Ref](nil)}
	column.Default = sc.Known(sc.Default{Kind: "expression", Expression: &expression})
	table.Columns = sc.Complete([]sc.Column{column})
	capture.Tables = []sc.Table{table}
	sql, reason, err := RenderSynchronizationSchema(context.Background(), syncplan.SchemaOperation{Action: "create", Ref: table.Ref, Source: capture, Target: capture})
	if err != nil || reason == "" || sql != "" {
		t.Fatal("expression returned SQL", sql, reason, err)
	}
}

func TestSynchronizationMySQLSavedDDLRejectsModeDependentLiterals(t *testing.T) {
	for _, comment := range []string{`slash\tail`, "line\nfeed", "nul\x00tail"} {
		capture, table := myDefinitionCapture()
		column := myDefinitionColumn(table.Ref, "value", "text")
		column.Comment = sc.Known(comment)
		table.Columns = sc.Complete([]sc.Column{column})
		capture.Tables = []sc.Table{table}
		for _, mode := range []string{"STRICT_TRANS_TABLES", "NO_BACKSLASH_ESCAPES"} {
			target := capture
			target.Context.EngineContext = sc.Known([]sc.Option{{Name: "sqlMode", Value: mode}})
			sql, reason, err := RenderSynchronizationSchema(context.Background(), syncplan.SchemaOperation{Action: "create", Ref: table.Ref, Source: capture, Target: target})
			if err != nil || reason == "" || sql != "" {
				t.Fatal("mode-dependent DDL became executable", mode, sql, reason, err)
			}
		}
	}
}
