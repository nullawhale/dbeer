package mariadb

import (
	"context"
	sc "dbeer/helper/internal/schemacompare"
	"encoding/base64"
	"strings"
	"testing"
)

func definitionNativeColumn(name, kind string) sc.Column {
	typ := mariaSchemaType(kind, kind, "", "", "", "", "")
	return sc.Column{Ref: sc.Ref{Kind: "column", Schema: "native_schema", Table: "native_table", Name: name}, Ordinal: sc.Known(0), Type: sc.Known(typ), Nullable: sc.Known(true), Default: sc.Known(sc.Default{Kind: "none"}), Generated: sc.Known(sc.Generated{Kind: "none"}), Identity: sc.Known(sc.Identity{Kind: "none"}), Charset: sc.Absent[string](), Collation: sc.Absent[sc.Ref](), Visible: sc.Known(true), Comment: sc.Known(""), OnUpdate: sc.Absent[sc.Expression]()}
}
func definitionNativeMode(mode string) sc.Fact[[]sc.Option] {
	return sc.Known([]sc.Option{{Name: "sqlMode", Value: mode}})
}
func TestMariaDBDefinitionNativeColumnProperties(t *testing.T) {
	c := definitionNativeColumn("n", "decimal")
	typ := mariaSchemaType("decimal", "decimal(65,38)", "", "", "65", "38", "")
	c.Type = sc.Known(typ)
	value := "9007199254741105.12345678901234567890123456789012345678"
	c.Default = sc.Known(sc.Default{Kind: "literal", Type: &typ, Encoding: "text", Value: &value})
	sql, manual, e := RenderStructureColumn(context.Background(), c, definitionNativeMode(""))
	if e != nil || manual != "" || (!strings.Contains(sql, "DECIMAL(65, 38)") || !strings.Contains(sql, "DEFAULT "+value)) {
		t.Fatal("native65/38 literal did not render exactly")
	}
	b := definitionNativeColumn("b", "varbinary")
	btyp := mariaSchemaType("varbinary", "varbinary(8)", "", "8", "", "", "")
	b.Type = sc.Known(btyp)
	binary := base64.StdEncoding.EncodeToString([]byte{0, 255, 92, 39})
	b.Default = sc.Known(sc.Default{Kind: "literal", Type: &btyp, Encoding: "base64", Value: &binary})
	sql, manual, e = RenderStructureColumn(context.Background(), b, definitionNativeMode("NO_BACKSLASH_ESCAPES"))
	if e != nil || manual != "" || !strings.Contains(sql, "DEFAULT X'00ff5c27'") {
		t.Fatal("native binary literal did not retain exact bytes")
	}
	c.Generated = sc.Known(sc.Generated{Kind: "stored", Expression: &sc.Expression{Text: "(`n`+1)", Dependencies: sc.Collection[sc.Ref]{State: "unavailable", Code: "expressionDependencies"}}})
	c.Default = sc.Known(sc.Default{Kind: "none"})
	sql, manual, e = RenderStructureColumn(context.Background(), c, definitionNativeMode(""))
	if e != nil || manual != "" || !strings.Contains(sql, "GENERATED ALWAYS AS ((`n`+1)) STORED") {
		t.Fatal("known native generation was evaluated or rejected solely for unproven dependency ownership")
	}
	c.Nullable = sc.Known(false)
	if _, manual, _ := RenderStructureColumn(context.Background(), c, definitionNativeMode("")); manual == "" {
		t.Fatal("computed-column intrinsic nullability became unsupported native NOT NULL syntax")
	}
	c.Nullable = sc.Known(true)
	c.Generated.Value.Expression.Text = "1); DROP TABLE `outside`; (1"
	if sql, manual, e = RenderStructureColumn(context.Background(), c, definitionNativeMode("")); e != nil || manual == "" || sql != "" {
		t.Fatal("native expression escaped its reviewed column slot")
	}
}
func TestMariaDBDefinitionNativeModesAndOptions(t *testing.T) {
	c := definitionNativeColumn("v", "varchar")
	typ := mariaSchemaType("varchar", "varchar(32)", "utf8mb4", "32", "", "", "")
	c.Type = sc.Known(typ)
	value := "😀q's\\tail"
	c.Default = sc.Known(sc.Default{Kind: "literal", Type: &typ, Encoding: "text", Value: &value})
	c.Charset = sc.Known("utf8mb4")
	c.Collation = sc.Known(sc.Ref{Kind: "collation", Name: "utf8mb4_bin"})
	c.Visible = sc.Known(false)
	for _, mode := range []string{"", "NO_BACKSLASH_ESCAPES"} {
		sql, manual, e := RenderStructureColumnWithOptions(context.Background(), c, definitionNativeMode(mode), sc.Complete([]sc.Option{{Name: "columnSystemVersioning:v", Value: "without"}, {Name: "nativePartitionDefinition", Value: "opaque unrelated table property"}}))
		if e != nil || manual != "" || !strings.Contains(sql, "INVISIBLE") || !strings.Contains(sql, "WITHOUT SYSTEM VERSIONING") || !strings.Contains(sql, "😀q''s") {
			t.Fatal("native mode/visibility/versioning property changed")
		}
	}
	if sql, manual, e := RenderStructureColumnWithOptions(context.Background(), c, definitionNativeMode(""), sc.Complete([]sc.Option{{Name: "columnExtra:v", Value: "unknown"}})); e != nil || manual == "" || sql != "" {
		t.Fatal("selected unmodeled column extra disappeared")
	}
	if _, manual, _ := RenderStructureColumn(context.Background(), c, sc.Unknown[[]sc.Option]("missing")); manual == "" {
		t.Fatal("missing literal mode became an implicit mode change")
	}
	if sql, manual, e := RenderStructureColumnWithOptions(context.Background(), c, definitionNativeMode(""), sc.Collection[sc.Option]{State: "unavailable", Code: "nativeColumnProperties"}); e != nil || manual == "" || sql != "" {
		t.Fatal("incomplete options falsely proved absence of a selected native policy")
	}

}
