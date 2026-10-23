package mysql

import (
	"context"
	"errors"
	"strings"
	"testing"
	"unicode/utf8"

	sc "dbeer/helper/internal/schemacompare"
	"dbeer/helper/internal/textdiff"
)

func myDefinitionCapture() (sc.Capture, sc.Table) {
	ref := sc.Ref{Kind: "table", Schema: "app`db", Name: "orders"}
	table := sc.Table{Ref: ref, Kind: sc.Known("table"), Storage: sc.Known("InnoDB"), Charset: sc.Known("utf8mb4"), Collation: sc.Known(sc.Ref{Kind: "collation", Name: "utf8mb4_bin"}), Options: sc.Complete[sc.Option](nil), Columns: sc.Complete[sc.Column](nil), Constraints: sc.Complete[sc.Constraint](nil), Indexes: sc.Complete[sc.Index](nil), Dependencies: sc.Complete[sc.Dependency](nil)}
	capture := sc.Capture{Context: sc.CaptureContext{Engine: "mysql", EngineContext: sc.Known([]sc.Option{{Name: "sqlMode", Value: "STRICT_TRANS_TABLES"}})}}
	return capture, table
}
func myDefinitionColumn(table sc.Ref, name, typ string) sc.Column {
	return sc.Column{Ref: sc.Ref{Kind: "column", Schema: table.Schema, Table: table.Name, Name: name}, Ordinal: sc.Known(0), Type: sc.Known(sc.TypeUse{Ref: sc.Ref{Kind: "type", Name: typ}, Kind: "builtin", Modifiers: sc.Known(sc.TypeModifiers{}), Labels: sc.Complete[string](nil)}), Nullable: sc.Known(false), Default: sc.Known(sc.Default{Kind: "none"}), Generated: sc.Known(sc.Generated{Kind: "none"}), Identity: sc.Known(sc.Identity{Kind: "none"}), Charset: sc.Absent[string](), Collation: sc.Absent[sc.Ref](), Visible: sc.Known(true), Comment: sc.Known(""), OnUpdate: sc.Absent[sc.Expression]()}
}
func myDefinitionIndex(table sc.Ref, name string) sc.Index {
	return sc.Index{Ref: sc.Ref{Kind: "index", Schema: table.Schema, Table: table.Name, Name: name}, Method: sc.Known("BTREE"), Unique: sc.Known(false), NullsDistinct: sc.Known(true), Keys: sc.Complete[sc.IndexKey](nil), Includes: sc.Complete[sc.Ref](nil), Predicate: sc.Absent[sc.Expression](), Options: sc.Complete[sc.Option](nil), Visible: sc.Known(true), Valid: sc.Known(true), Ready: sc.Known(true), Constraint: sc.Absent[sc.Ref]()}
}
func myDefinitionKey(column sc.Ref) sc.IndexKey {
	return sc.IndexKey{Column: sc.Known(column), Expression: sc.Absent[sc.Expression](), Opclass: sc.Absent[sc.Ref](), Collation: sc.Absent[sc.Ref](), Descending: sc.Known(false), NullsFirst: sc.Known(true), PrefixLength: sc.Absent[int64](), Options: sc.Complete[sc.Option](nil)}
}
func myDefinitionRender(t *testing.T, capture sc.Capture, table sc.Table) sc.Definition {
	t.Helper()
	capture.Tables = []sc.Table{table}
	definition, err := RenderSchemaDefinition(context.Background(), capture, table.Ref)
	if err != nil {
		t.Fatal(err)
	}
	return definition
}
func myDefinitionContains(t *testing.T, sql string, values ...string) {
	t.Helper()
	for _, value := range values {
		if !strings.Contains(sql, value) {
			t.Errorf("missing %q in:\n%s", value, sql)
		}
	}
}
func TestRenderSchemaDefinitionMySQLReadableTable(t *testing.T) {
	capture, table := myDefinitionCapture()
	id := myDefinitionColumn(table.Ref, "id", "bigint")
	id.Identity = sc.Known(sc.Identity{Kind: "autoIncrement"})
	id.Type.Value.Modifiers.Value.Unsigned = true
	amount := myDefinitionColumn(table.Ref, "amount", "decimal")
	precision, scale := int64(65), int64(9)
	amount.Type.Value.Modifiers.Value.Precision = &precision
	amount.Type.Value.Modifiers.Value.Scale = &scale
	exact := "9007199254740993.123456789"
	amount.Default = sc.Known(sc.Default{Kind: "literal", Type: amount.Type.Value, Encoding: "text", Value: &exact})
	name := myDefinitionColumn(table.Ref, "na`me", "varchar")
	length := int64(255)
	name.Type.Value.Modifiers.Value.Length = &length
	name.Nullable = sc.Known(true)
	name.Default = sc.Known(sc.Default{Kind: "sqlNull"})
	name.Comment = sc.Known("owner's \\ note")
	name.Visible = sc.Known(false)
	created := myDefinitionColumn(table.Ref, "created", "timestamp")
	fsp := int64(6)
	created.Type.Value.Modifiers.Value.DatetimePrecision = &fsp
	created.Default = sc.Known(sc.Default{Kind: "expression", Expression: &sc.Expression{Text: "CURRENT_TIMESTAMP(6)", Dependencies: sc.Complete[sc.Ref](nil)}})
	created.OnUpdate = sc.Known(sc.Expression{Text: "CURRENT_TIMESTAMP(6)", Dependencies: sc.Complete[sc.Ref](nil)})
	generated := myDefinitionColumn(table.Ref, "double_amount", "decimal")
	generated.Generated = sc.Known(sc.Generated{Kind: "stored", Expression: &sc.Expression{Text: "(`amount` * 2)", Dependencies: sc.Complete[sc.Ref](nil)}})
	table.Columns.Items = []sc.Column{id, amount, name, created, generated}
	primary := sc.NewConstraint(sc.Ref{Kind: "constraint", Schema: table.Ref.Schema, Table: table.Ref.Name, Name: "PRIMARY"}, "p")
	primary.Columns = sc.Complete([]sc.Ref{id.Ref})
	unique := sc.NewConstraint(sc.Ref{Kind: "constraint", Schema: table.Ref.Schema, Table: table.Ref.Name, Name: "unique_name"}, "u")
	unique.Columns = sc.Complete([]sc.Ref{name.Ref})
	check := sc.NewConstraint(sc.Ref{Kind: "constraint", Schema: table.Ref.Schema, Table: table.Ref.Name, Name: "positive"}, "c")
	check.Check = sc.Known(sc.Expression{Text: "(`amount` >= 0)", Dependencies: sc.Complete[sc.Ref](nil)})
	check.Enforced = sc.Known(false)
	foreign := sc.NewConstraint(sc.Ref{Kind: "constraint", Schema: table.Ref.Schema, Table: table.Ref.Name, Name: "owner"}, "f")
	foreign.Columns = sc.Complete([]sc.Ref{id.Ref})
	foreign.Target = sc.Known(sc.Ref{Kind: "table", Schema: "app`db", Name: "owners"})
	foreign.ForeignKeys = sc.Complete([]sc.ColumnPair{{Source: id.Ref, Target: sc.Ref{Kind: "column", Name: "owner`id"}}})
	foreign.Update = sc.Known("CASCADE")
	foreign.Delete = sc.Known("SET NULL")
	foreign.Match = sc.Known("NONE")
	table.Constraints.Items = []sc.Constraint{primary, unique, check, foreign}
	table.Options.Items = []sc.Option{{Name: "comment", Value: "Orders"}, {Name: "row_format", Value: "dynamic"}}
	definition := myDefinitionRender(t, capture, table)
	if definition.Limited {
		t.Fatalf("complete facts marked limited: %s", definition.SQL)
	}
	myDefinitionContains(t, definition.SQL, "CREATE TABLE `app``db`.`orders` (", "`id` BIGINT UNSIGNED NOT NULL AUTO_INCREMENT", "`amount` DECIMAL(65, 9) NOT NULL DEFAULT "+exact, "`na``me` VARCHAR(255) NULL DEFAULT NULL INVISIBLE COMMENT 'owner''s \\\\ note'", "TIMESTAMP(6) NOT NULL DEFAULT (CURRENT_TIMESTAMP(6)) ON UPDATE CURRENT_TIMESTAMP(6)", "GENERATED ALWAYS AS ((`amount` * 2)) STORED", "CONSTRAINT `PRIMARY` PRIMARY KEY (`id`)", "CONSTRAINT `unique_name` UNIQUE (`na``me`)", "CHECK ((`amount` >= 0)) NOT ENFORCED", "REFERENCES `app``db`.`owners` (`owner``id`) ON UPDATE CASCADE ON DELETE SET NULL", "ENGINE = `InnoDB` DEFAULT CHARACTER SET = `utf8mb4` COLLATE = `utf8mb4_bin` COMMENT = 'Orders' ROW_FORMAT = DYNAMIC;")
}
func TestRenderSchemaDefinitionMySQLIndexDetails(t *testing.T) {
	capture, table := myDefinitionCapture()
	column := myDefinitionColumn(table.Ref, "code", "varchar")
	n := int64(100)
	column.Type.Value.Modifiers.Value.Length = &n
	table.Columns.Items = []sc.Column{column}
	index := myDefinitionIndex(table.Ref, "code_idx")
	key := myDefinitionKey(column.Ref)
	key.PrefixLength = sc.Known(int64(12))
	key.Descending = sc.Known(true)
	index.Keys.Items = []sc.IndexKey{key}
	index.Visible = sc.Known(false)
	index.Options.Items = []sc.Option{{Name: "comment", Value: "lookup"}}
	index.Unique = sc.Known(true)
	expression := myDefinitionIndex(table.Ref, "lower_idx")
	exprKey := myDefinitionKey(column.Ref)
	exprKey.Column = sc.Absent[sc.Ref]()
	exprKey.Expression = sc.Known(sc.Expression{Text: "lower(`code`)", Dependencies: sc.Complete[sc.Ref](nil)})
	expression.Keys.Items = []sc.IndexKey{exprKey}
	constraint := sc.NewConstraint(sc.Ref{Kind: "constraint", Schema: table.Ref.Schema, Table: table.Ref.Name, Name: "code_unique"}, "u")
	constraint.Columns = sc.Complete([]sc.Ref{column.Ref})
	constraint.BackingIndex = sc.Known(index.Ref)
	index.Constraint = sc.Known(constraint.Ref)
	table.Indexes.Items = []sc.Index{index, expression}
	table.Constraints.Items = []sc.Constraint{constraint}
	definition := myDefinitionRender(t, capture, table)
	if definition.Limited {
		t.Fatalf("complete facts marked limited: %s", definition.SQL)
	}
	myDefinitionContains(t, definition.SQL, "CONSTRAINT `code_unique` UNIQUE (`code`(12) DESC) USING BTREE INVISIBLE COMMENT 'lookup'", "KEY `lower_idx` ((lower(`code`)) ASC) USING BTREE")
	if strings.Contains(definition.SQL, "KEY `code_idx`") {
		t.Fatalf("backing index duplicated: %s", definition.SQL)
	}
}
func TestRenderSchemaDefinitionMySQLLiteralEscapingAndBinary(t *testing.T) {
	for _, mode := range []string{"ANSI_QUOTES", "ANSI_QUOTES,NO_BACKSLASH_ESCAPES"} {
		t.Run(mode, func(t *testing.T) {
			capture, table := myDefinitionCapture()
			capture.Context.EngineContext = sc.Known([]sc.Option{{Name: "sqlMode", Value: mode}})
			column := myDefinitionColumn(table.Ref, "value", "text")
			value := "'\\猫"
			column.Default = sc.Known(sc.Default{Kind: "literal", Type: column.Type.Value, Encoding: "text", Value: &value})
			binary := myDefinitionColumn(table.Ref, "binary", "varbinary")
			length := int64(16)
			binary.Type.Value.Modifiers.Value.Length = &length
			encoded := "AAEn/w=="
			binary.Default = sc.Known(sc.Default{Kind: "literal", Type: binary.Type.Value, Encoding: "base64", Value: &encoded})
			table.Columns.Items = []sc.Column{column, binary}
			definition := myDefinitionRender(t, capture, table)
			if definition.Limited {
				t.Fatalf("complete facts marked limited: %s", definition.SQL)
			}
			expected := "DEFAULT '''\\\\猫'"
			if strings.Contains(mode, "NO_BACKSLASH_ESCAPES") {
				expected = "DEFAULT '''\\猫'"
			}
			myDefinitionContains(t, definition.SQL, expected, "DEFAULT X'000127ff'")
		})
	}
}
func TestRenderSchemaDefinitionMySQLUnavailableFacts(t *testing.T) {
	capture, table := myDefinitionCapture()
	column := myDefinitionColumn(table.Ref, "value", "varchar")
	column.Type = sc.Unknown[sc.TypeUse]("type-hidden")
	column.Default = sc.Unknown[sc.Default]("default-hidden")
	table.Columns.Items = []sc.Column{column}
	table.Options.Items = []sc.Option{{Name: "createOptions", Value: "partitioned"}}
	table.Columns.Complete = false
	definition := myDefinitionRender(t, capture, table)
	if !definition.Limited {
		t.Fatal("unknown facts must mark limited")
	}
	myDefinitionContains(t, definition.SQL, "`value` /* type unavailable */", "/* default unavailable */", "-- Unavailable column type", "type-hidden", "default-hidden", "-- Incomplete table columns", "partitioned")
	if strings.Contains(definition.SQL, "TEXT") || strings.Contains(definition.SQL, "DEFAULT NULL") {
		t.Fatalf("unknown facts invented: %s", definition.SQL)
	}
	capture.Context.EngineContext = sc.Unknown[[]sc.Option]("mode-hidden")
	column = myDefinitionColumn(table.Ref, "value", "text")
	value := "quoted'\\value"
	column.Default = sc.Known(sc.Default{Kind: "literal", Type: column.Type.Value, Encoding: "text", Value: &value})
	table.Columns.Items = []sc.Column{column}
	definition = myDefinitionRender(t, capture, table)
	myDefinitionContains(t, definition.SQL, "DEFAULT /* literal unavailable */", "sql_mode")
	if strings.Contains(definition.SQL, value) {
		t.Fatal("literal escaped without known sql_mode")
	}
}
func TestRenderSchemaDefinitionMySQLEnumAndBounds(t *testing.T) {
	capture, table := myDefinitionCapture()
	column := myDefinitionColumn(table.Ref, "state", "enum")
	column.Type.Value.Labels = sc.Complete([]string{"open", "can't"})
	table.Columns.Items = []sc.Column{column}
	definition := myDefinitionRender(t, capture, table)
	if definition.Limited {
		t.Fatal(definition.SQL)
	}
	myDefinitionContains(t, definition.SQL, "ENUM('open', 'can''t')")
	column.Type.Value.Labels = sc.Complete[string](nil)
	table.Columns.Items = []sc.Column{column}
	definition = myDefinitionRender(t, capture, table)
	if !definition.Limited {
		t.Fatal("missing labels not limited")
	}
	myDefinitionContains(t, definition.SQL, "ENUM(/* labels unavailable */)")
	column = myDefinitionColumn(table.Ref, "value", "text")
	column.Comment = sc.Known(strings.Repeat("猫", textdiff.MaxTextBytes))
	table.Columns.Items = []sc.Column{column}
	definition = myDefinitionRender(t, capture, table)
	if !definition.Limited || len(definition.SQL) > textdiff.MaxTextBytes || !utf8.ValidString(definition.SQL) {
		t.Fatalf("output not bounded UTF-8: %d bytes, limited=%v", len(definition.SQL), definition.Limited)
	}
	ctx, cancel := context.WithCancel(context.Background())
	cancel()
	capture.Tables = []sc.Table{table}
	_, err := RenderSchemaDefinition(ctx, capture, table.Ref)
	if !errors.Is(err, context.Canceled) {
		t.Fatalf("got %v", err)
	}
}

func TestRenderSchemaDefinitionMySQLRequiredFactsAndEmptyDefaults(t *testing.T) {
	capture, table := myDefinitionCapture()
	column := myDefinitionColumn(table.Ref, "empty", "text")
	empty := ""
	column.Default = sc.Known(sc.Default{Kind: "literal", Type: column.Type.Value, Encoding: "text", Value: &empty})
	table.Columns.Items = []sc.Column{column}
	definition := myDefinitionRender(t, capture, table)
	if definition.Limited {
		t.Fatal(definition.SQL)
	}
	myDefinitionContains(t, definition.SQL, "`empty` TEXT NOT NULL DEFAULT ''")
	column.Type = sc.Absent[sc.TypeUse]()
	column.Default = sc.Absent[sc.Default]()
	table.Columns.Items = []sc.Column{column}
	definition = myDefinitionRender(t, capture, table)
	if !definition.Limited {
		t.Fatal("known nil required facts were presented as a complete definition")
	}
	myDefinitionContains(t, definition.SQL, "/* type unavailable */", "/* default unavailable */", "-- Unavailable column type.", "-- Unavailable column default.")
	column = myDefinitionColumn(table.Ref, "amount", "decimal")
	invalid := "1); SELECT 42; --"
	column.Default = sc.Known(sc.Default{Kind: "literal", Type: column.Type.Value, Encoding: "text", Value: &invalid})
	table.Columns.Items = []sc.Column{column}
	definition = myDefinitionRender(t, capture, table)
	if !definition.Limited || strings.Contains(definition.SQL, "SELECT 42") {
		t.Fatal("invalid numeric default was rendered as SQL")
	}
}

func TestRenderSchemaDefinitionMySQLExpressionDependencies(t *testing.T) {
	capture, table := myDefinitionCapture()
	column := myDefinitionColumn(table.Ref, "double_amount", "decimal")
	column.Generated = sc.Known(sc.Generated{Kind: "stored", Expression: &sc.Expression{Text: "(1 + 1)", Dependencies: sc.Collection[sc.Ref]{State: "unavailable", Code: "expressionDependencies"}}})
	table.Columns.Items = []sc.Column{column}
	definition := myDefinitionRender(t, capture, table)
	if !definition.Limited {
		t.Fatal("unavailable dependencies were not marked limited")
	}
	myDefinitionContains(t, definition.SQL, "DECIMAL GENERATED ALWAYS AS ((1 + 1)) STORED NOT NULL", "-- Incomplete generated column dependencies", "expressionDependencies")
	column.Generated.Value.Expression.Dependencies = sc.Complete[sc.Ref](nil)
	table.Columns.Items = []sc.Column{column}
	definition = myDefinitionRender(t, capture, table)
	if definition.Limited {
		t.Fatal("known empty dependencies marked limited")
	}
}
