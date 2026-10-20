package sqlcomplete

import (
	"strings"
	"testing"
	"unicode/utf8"
)

func signatureAt(t *testing.T, sql string, context Context) *SignatureHelp {
	t.Helper()
	offset := strings.Index(sql, "|")
	if offset < 0 {
		t.Fatal("missing cursor marker")
	}
	return Signatures(strings.Replace(sql, "|", "", 1), offset, context)
}

func TestSignatureHelpNestedCallsAndArgumentDelimiters(t *testing.T) {
	for _, engine := range []string{"postgresql", "mysql"} {
		for _, check := range []struct {
			sql, name string
			active    int
		}{
			{"SELECT COALESCE(|)", "COALESCE", 0},
			{"SELECT NULLIF(1, |)", "NULLIF", 1},
			{"SELECT NULLIF('x,y', |)", "NULLIF", 1},
			{"SELECT NULLIF(ROUND(1.5, 0), |)", "NULLIF", 1},
			{"SELECT NULLIF(ROUND(1.5, |), 0)", "ROUND", 1},
			{"SELECT NULLIF((1 + 2), |)", "NULLIF", 1},
			{"SELECT COALESCE(true AND (true OR |false), false)", "COALESCE", 0},
			{"SELECT COALESCE(NOT (|false), true)", "COALESCE", 0},
			{"SELECT NULLIF(ARRAY[1,2], |)", "NULLIF", 1},
			{"SELECT NULLIF((SELECT id,total FROM orders), |)", "NULLIF", 1},
			{"SELECT NULLIF(/* a,b */ 1, |)", "NULLIF", 1},
			{"SELECT NULLIF(1, 'a|,b')", "NULLIF", 1},
			{"SELECT COALESCE(1,2,3, |)", "COALESCE", 0},
			{"SELECT SUBSTRING('hello' FROM |)", "SUBSTRING", 1},
			{"SELECT SUBSTRING('hello' FROM 1 FOR |)", "SUBSTRING", 2},
		} {
			t.Run(engine+"/"+check.sql, func(t *testing.T) {
				help := signatureAt(t, check.sql, Context{Engine: engine})
				if help == nil {
					t.Fatal("missing signature")
				}
				value := help.Signatures[help.ActiveSignature]
				if !strings.HasPrefix(value.Label, check.name+"(") || value.ActiveParameter != check.active {
					t.Fatalf("wrong active function or parameter: %+v", value)
				}
				if !strings.Contains(value.Label, " → ") {
					t.Fatal("missing return type")
				}
				span := value.Parameters[value.ActiveParameter]
				if span.Start < 0 || span.End > len(value.Label) || span.End <= span.Start || !utf8.ValidString(value.Label[span.Start:span.End]) {
					t.Fatal("invalid parameter span")
				}
			})
		}
		for _, sql := range []string{"SELECT |", "SELECT 'NULLIF(1, |'", "-- NULLIF(|", "SELECT NULLIF(1,2)|", "SELECT NULLIF(1,2); SELECT |", "SELECT NULLIF(/* | */ 1,2)", "SELECT unknown(|"} {
			if help := signatureAt(t, sql, Context{Engine: engine}); help != nil {
				t.Fatal("signature escaped its function call")
			}
		}
	}
	for _, sql := range []string{"SELECT NULLIF($tag$a,b$tag$, |)", `SELECT NULLIF(E'a\'b,c', |)`} {
		help := signatureAt(t, sql, Context{Engine: "postgresql"})
		if help == nil || help.Signatures[help.ActiveSignature].ActiveParameter != 1 {
			t.Fatal("dialect literal changed the active parameter")
		}
	}
}

func TestSignatureMetadataOverloadsNamedDefaultAndVariadicArguments(t *testing.T) {
	context := Context{Engine: "postgresql", Catalog: []Relation{{Schema: "public", Name: "calculate", Kind: "function", Signatures: []FunctionSignature{
		{Parameters: []FunctionParameter{{Name: "value", Type: "integer"}}, ReturnType: "integer"},
		{Parameters: []FunctionParameter{{Name: "scale", Type: "integer", Position: 2, Optional: true}, {Name: "value", Type: "numeric", Position: 1}}, ReturnType: "numeric"},
	}}}}
	for _, sql := range []string{"SELECT public.calculate(1, |)", "SELECT public.calculate(scale => |, value => 1)", "SELECT public.calculate(scale := |)", "SELECT public.calculate(value => 1, scale => |)"} {
		help := signatureAt(t, sql, context)
		if help == nil || help.ActiveSignature != 1 {
			t.Fatal("wrong overload for arity/named arguments")
		}
		selected := help.Signatures[help.ActiveSignature]
		if selected.ActiveParameter != 1 || !strings.Contains(selected.Label, "scale: integer = DEFAULT") || !strings.HasSuffix(selected.Label, " → numeric") {
			t.Fatal("missing ordered/default parameter or return type")
		}
	}
	context.Catalog[0].Signatures = append(context.Catalog[0].Signatures, FunctionSignature{ReturnType: "text", Parameters: []FunctionParameter{{Name: "values", Type: "text[]", Variadic: true}}})
	help := signatureAt(t, "SELECT public.calculate('a','b','c',|)", context)
	if help == nil || help.ActiveSignature != 2 || help.Signatures[2].ActiveParameter != 0 {
		t.Fatal("variadic parameter did not absorb repeated arguments")
	}
	help = signatureAt(t, "SELECT public.calculate(1,2,3,4,5,6,7,8,9,10,11,12,|)", context)
	if help == nil || help.Signatures[help.ActiveSignature].ActiveParameter != 0 {
		t.Fatal("variadic parameter lost its highlight")
	}
}

func TestSignatureDialectQualifiedNamesAndNoArgumentCalls(t *testing.T) {
	pg := signatureAt(t, "SELECT NOW(|)", Context{Engine: "postgresql"})
	mysql := signatureAt(t, "SELECT NOW(|)", Context{Engine: "mysql"})
	if pg == nil || mysql == nil || len(pg.Signatures[0].Parameters) != 0 || len(mysql.Signatures[0].Parameters) != 1 || !strings.HasSuffix(pg.Signatures[0].Label, "time zone") || !strings.HasSuffix(mysql.Signatures[0].Label, "datetime") {
		t.Fatal("dialect-specific signature missing")
	}
	if signatureAt(t, "SELECT private.LOWER(|)", Context{Engine: "postgresql"}) != nil {
		t.Fatal("qualified user function inherited a built-in signature")
	}
	if signatureAt(t, "SELECT pg_catalog.lower(|)", Context{Engine: "postgresql"}) == nil {
		t.Fatal("explicit pg_catalog built-in missing")
	}
	if signatureAt(t, `SELECT "LOWER"(|)`, Context{Engine: "postgresql"}) != nil {
		t.Fatal("quoted mixed-case name acquired a lowercase built-in")
	}
	context := Context{Engine: "postgresql", Catalog: []Relation{{Schema: "Sales", Name: "Function 😀", Kind: "function", Signatures: []FunctionSignature{{ReturnType: "text", Parameters: []FunctionParameter{{Name: "first 😀", Type: "text"}, {Name: "second", Type: "integer"}}}}}}}
	help := signatureAt(t, `SELECT "Sales"."Function 😀"('x', |)`, context)
	if help == nil {
		t.Fatal("quoted Unicode function missing")
	}
	value := help.Signatures[0]
	if value.ActiveParameter != 1 || value.Label[value.Parameters[1].Start:value.Parameters[1].End] != "second: integer" {
		t.Fatal("Unicode label offsets are invalid")
	}
	for _, offset := range []int{-1, 999, 1} {
		if offset == 1 {
			if Signatures("😀", offset, context) != nil {
				t.Fatal("accepted split UTF-8 offset")
			}
		} else if Signatures("SELECT", offset, context) != nil {
			t.Fatal("accepted invalid offset")
		}
	}
}
