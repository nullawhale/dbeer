package postgres

import (
	"context"
	sc "dbeer/helper/internal/schemacompare"
	"strings"
	"testing"
)

func TestCustomTypeModifiersDoNotUseBuiltinName(t *testing.T) {
	for _, name := range []string{"numeric", "varchar", "time", "interval"} {
		u := sc.TypeUse{Ref: sc.Ref{Kind: "type", Schema: "custom", Name: name}, Kind: "b"}
		got := pgModifiers(u, 31, 0)
		m := got.Modifiers.Value
		if m == nil || m.Raw == nil || *m.Raw != 31 || m.Length != nil || m.Precision != nil || m.DatetimePrecision != nil {
			t.Fatalf("custom %s decoded as builtin", name)
		}
	}
}

func TestSchemaDefinitionRangeMultirangeAndBase(t *testing.T) {
	typ := definitionBuiltin("numeric", sc.TypeModifiers{})
	ref := sc.Ref{Kind: "type", Schema: "custom", Name: "span"}
	multi := sc.Ref{Kind: "type", Schema: "custom", Name: "spans"}
	rng := sc.TypeDefinition{Ref: ref, Kind: sc.Known("r"), Range: &sc.TypeRange{Subtype: typ, Multirange: multi, OperatorClass: sc.Ref{Kind: "opclass", Schema: "pg_catalog", Name: "numeric_ops"}, Difference: &sc.TypeFunction{Ref: sc.Ref{Kind: "routine", Schema: "pg_catalog", Name: "numeric_subtype_diff"}}}}
	m := sc.TypeDefinition{Ref: multi, Kind: sc.Known("m"), Base: sc.Known(sc.TypeUse{Ref: ref, Kind: "r", Modifiers: sc.Known(sc.TypeModifiers{})})}
	capture := sc.Capture{Types: []sc.TypeDefinition{rng, m}}
	for _, wanted := range []sc.Ref{ref, multi} {
		got, e := RenderSchemaDefinition(context.Background(), capture, wanted)
		if e != nil || got.Limited || !strings.Contains(got.SQL, "SUBTYPE = numeric") || !strings.Contains(got.SQL, `MULTIRANGE_TYPE_NAME = "custom"."spans"`) || !strings.Contains(got.SQL, `SUBTYPE_DIFF = "pg_catalog"."numeric_subtype_diff"`) {
			t.Fatalf("range definition: %#v %v", got, e)
		}
	}
	b := sc.TypeDefinition{Ref: sc.Ref{Kind: "type", Schema: "custom", Name: "number"}, Kind: sc.Known("b"), BaseType: &sc.TypeBase{Options: sc.Complete([]sc.Option{{Name: "internalLength", Value: "4"}, {Name: "passedByValue", Value: "true"}, {Name: "alignment", Value: "i"}, {Name: "storage", Value: "p"}, {Name: "category", Value: "N"}, {Name: "preferred", Value: "false"}, {Name: "delimiter", Value: ","}}), Functions: []sc.TypeFunction{{Role: "input", Ref: sc.Ref{Schema: "custom", Name: "number_in"}}, {Role: "output", Ref: sc.Ref{Schema: "custom", Name: "number_out"}}}}}
	got, e := RenderSchemaDefinition(context.Background(), sc.Capture{Types: []sc.TypeDefinition{b}}, b.Ref)
	if e != nil || got.Limited || !strings.Contains(got.SQL, `INPUT = "custom"."number_in"`) || !strings.Contains(got.SQL, "PASSEDBYVALUE") || !strings.Contains(got.SQL, "ALIGNMENT = int4") {
		t.Fatalf("base definition: %#v %v", got, e)
	}
}

func TestSchemaDefinitionCustomModifierSQL(t *testing.T) {
	mod, sql := int64(42), "(Point,4326)"
	u := sc.TypeUse{Ref: sc.Ref{Kind: "type", Schema: "extension", Name: "geometry"}, Kind: "b", Modifiers: sc.Known(sc.TypeModifiers{Raw: &mod, SQL: &sql})}
	table := definitionTable(definitionColumn("position", u))
	got, e := RenderSchemaDefinition(context.Background(), sc.Capture{Tables: []sc.Table{table}}, table.Ref)
	if e != nil || got.Limited || !strings.Contains(got.SQL, `"extension"."geometry"(Point,4326)`) {
		t.Fatalf("custom modifier: %#v %v", got, e)
	}
}

func TestDomainOverArrayIsNeitherScalarBinaryNorNumeric(t *testing.T) {
	for _, name := range []string{"bytea", "numeric"} {
		element := definitionBuiltin(name, sc.TypeModifiers{})
		array := sc.TypeUse{Ref: element.Ref, Kind: "array", Element: &element, Modifiers: sc.Known(sc.TypeModifiers{})}
		domain := sc.TypeUse{Ref: sc.Ref{Kind: "type", Schema: "custom", Name: "values"}, Kind: "d", Modifiers: sc.Known(sc.TypeModifiers{})}
		defs := []sc.TypeDefinition{{Ref: domain.Ref, Kind: sc.Known("d"), Base: sc.Known(array)}}
		if got := postgresDataBase(domain, defs); got != "array" {
			t.Fatalf("domain over %s[] classified as %s", name, got)
		}
	}
}
