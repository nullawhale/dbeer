package postgres

import (
	"strings"
	"testing"

	"dbeer/helper/internal/protocol"
)

func TestPostgresTypePreviewQuotesLabelsAndRestrictsOperations(t *testing.T) {
	metadata := TypeMetadata{Schema: `odd"schema`, Name: `enum \猫`, Kind: "enum", MembersComplete: true,
		EnumValues: []TypeEnumValue{{Label: ""}, {Label: `old'\Ω`, Position: 2, SortOrder: "1.5"}}}
	for _, test := range []struct {
		change protocol.TypeChange
		want   string
	}{
		{protocol.TypeChange{Operation: "renameType", NewName: typeCell(`new"\Ω`)}, `ALTER TYPE "odd""schema"."enum \猫" RENAME TO "new""\Ω";`},
		{protocol.TypeChange{Operation: "addEnumValue", Value: typeCell(`quote'\Ω`)}, `ALTER TYPE "odd""schema"."enum \猫" ADD VALUE E'quote''\\Ω';`},
		{protocol.TypeChange{Operation: "renameEnumValue", OldValue: typeCell(""), Value: typeCell(`quote'\Ω`)}, `ALTER TYPE "odd""schema"."enum \猫" RENAME VALUE E'' TO E'quote''\\Ω';`},
	} {
		sql, warnings, ok := typeChangeSQL(metadata, test.change)
		if !ok || sql != test.want || !strings.Contains(warnings, "no changes have been executed") || !strings.Contains(warnings, "not bound to this local OID") {
			t.Fatal("type preview lost exact SQL quoting or execution limitations")
		}
	}
	for _, change := range []protocol.TypeChange{
		{Operation: "addEnumValue", Value: typeCell("")},
		{Operation: "renameEnumValue", OldValue: typeCell("missing"), Value: typeCell("new")},
		{Operation: "renameEnumValue", OldValue: typeCell(""), Value: typeCell(`old'\Ω`)},
		{Operation: "removeEnumValue", OldValue: typeCell("")},
	} {
		if _, _, ok := typeChangeSQL(metadata, change); ok {
			t.Fatal("invalid, duplicate or unsupported enum operation was generated")
		}
	}
	for _, kind := range []string{"domain", "composite", "range", "base", "multirange"} {
		m := metadata
		m.Kind = kind
		_, _, ok := typeChangeSQL(m, protocol.TypeChange{Operation: "renameType", NewName: typeCell("renamed")})
		if ok != (kind != "multirange") {
			t.Fatal("type rename support did not respect generated multiranges")
		}
		if kind == "domain" {
			sql, _, _ := typeChangeSQL(m, protocol.TypeChange{Operation: "renameType", NewName: typeCell("renamed")})
			if !strings.HasPrefix(sql, "ALTER DOMAIN ") {
				t.Fatal("domain rename did not use ALTER DOMAIN")
			}
		}
		if _, _, ok = typeChangeSQL(m, protocol.TypeChange{Operation: "addEnumValue", Value: typeCell("new")}); ok {
			t.Fatal("non-enum type accepted enum DDL")
		}
	}
	metadata.Extension = "synthetic_extension"
	if _, _, ok := typeChangeSQL(metadata, protocol.TypeChange{Operation: "renameType", NewName: typeCell("renamed")}); ok {
		t.Fatal("extension-managed type accepted generated changes")
	}
	metadata.Extension, metadata.MembersComplete = "", false
	if _, _, ok := typeChangeSQL(metadata, protocol.TypeChange{Operation: "addEnumValue", Value: typeCell("new")}); ok {
		t.Fatal("incomplete labels were used to validate a duplicate-sensitive preview")
	}
}

func TestPostgresTypeDefinitionsDiscloseIncompleteReconstruction(t *testing.T) {
	enum := TypeMetadata{Schema: "public", Name: "empty", Kind: "enum", MembersComplete: true}
	definition, status, _, _ := typeDefinition(enum)
	if definition == nil || *definition != `CREATE TYPE "public"."empty" AS ENUM ();` || status != "complete" {
		t.Fatal("empty unused enum definition was unavailable")
	}
	enum.EnumValues = []TypeEnumValue{{Label: "z"}, {Label: ""}, {Label: "a"}}
	definition, _, _, _ = typeDefinition(enum)
	if *definition != `CREATE TYPE "public"."empty" AS ENUM (E'z', E'', E'a');` {
		t.Fatal("enum definition reordered labels or dropped empty strings")
	}
	for _, kind := range []string{"domain", "composite", "range", "multirange", "base"} {
		m := TypeMetadata{Schema: "public", Name: "typed", Kind: kind, BaseType: "numeric(12,4)", MembersComplete: true}
		definition, status, limitations, details := typeDefinition(m)
		if status == "complete" || limitations == "" || details == "" || (kind == "domain" || kind == "composite") && (definition == nil || !strings.Contains(limitations, "search_path")) {
			t.Fatal("unsupported or context-dependent reconstruction claimed completeness")
		}
	}
	enum.MembersComplete = false
	definition, status, _, _ = typeDefinition(enum)
	if definition != nil || status != "partial" {
		t.Fatal("a truncated label prefix became executable complete CREATE SQL")
	}
	if typeResultFits(protocol.Response{Type: "query.result", Columns: []protocol.Column{{Index: 0, Name: "definition"}}, Rows: [][]*string{{typeCell(strings.Repeat("<", MaxResultBytes/6))}}}) {
		t.Fatal("JSON escaping exceeded the bounded single-row response budget")
	}
}

func TestPostgresTypeCatalogQueriesUseCatalogIdentityOrderAndFullAddresses(t *testing.T) {
	query, values, _ := catalogSQL(protocol.CatalogRequest{Kind: "objects", Schema: `odd'"schema`, ObjectKind: "enum"})
	if strings.Contains(query, `odd'"schema`) || len(values) != 2 || !strings.Contains(query, "element.typarray=t.oid") || !strings.Contains(query, "rowtype.relkind='c'") || !strings.Contains(query, "has_type_privilege") {
		t.Fatal("type listing lost parameterization, access checks or derived-type filtering")
	}
	for _, query := range []string{typeHeaderSQL, enumValuesSQL, typeDependenciesSQL} {
		if strings.Contains(query, "SELECT * FROM ") || strings.Contains(query, "information_schema.columns") {
			t.Fatal("type metadata depends on using table rows")
		}
	}
	if !strings.Contains(enumValuesSQL, "ORDER BY e.enumsortorder") || strings.Contains(enumValuesSQL, "ORDER BY e.oid") {
		t.Fatal("enum values lost PostgreSQL ordering")
	}
	for _, fragment := range []string{"d.classid", "d.objid", "d.objsubid", "d.refclassid", "d.refobjid", "d.refobjsubid", "pg_identify_object(l.otherclass,l.otherid,l.othersubid)", "'incoming'", "'outgoing'"} {
		if !strings.Contains(typeDependenciesSQL, fragment) {
			t.Fatal("dependency query omitted a complete catalog address or direction")
		}
	}
}
