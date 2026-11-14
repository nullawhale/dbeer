package postgres

import (
	"reflect"
	"strings"
	"testing"
)

const pgCopyFormatFixture = `{FUNCEXPR :funcid 1740 :funcresulttype 1700 :funcretset false :funcvariadic false :funcformat 2 :funccollid 0 :inputcollid 0 :args ({CONST :consttype 23 :consttypmod -1 :constcollid 0 :constlen 4 :constbyval true :constisnull false :constvalue 4 [ 0 0 0 0 ]}) :location -1}`

func TestAdvancedCopyIndexNodeDisplayFormatOnly(t *testing.T) {
	want := strings.Replace(pgCopyFormatFixture, ":funcformat 2", ":funcformat 0", 1)
	for _, enum := range []string{"0", "1", "2", "3"} {
		got, err := pgAdvancedCopyIndexNodeFormats(strings.Replace(pgCopyFormatFixture, ":funcformat 2", ":funcformat "+enum, 1))
		if err != nil || got != want {
			t.Fatal("a valid native display annotation changed semantic fields")
		}
	}
	for _, change := range []struct{ old, next string }{
		{":funcid 1740", ":funcid 1741"}, {":funcresulttype 1700", ":funcresulttype 23"},
		{":funccollid 0", ":funccollid 100"}, {":inputcollid 0", ":inputcollid 100"},
		{":funcretset false", ":funcretset true"}, {":funcvariadic false", ":funcvariadic true"},
		{":consttype 23", ":consttype 20"}, {"[ 0 0 0 0 ]", "[ 1 0 0 0 ]"},
		{":args (", ":unknown_semantic 1 :args ("},
	} {
		got, err := pgAdvancedCopyIndexNodeFormats(strings.Replace(pgCopyFormatFixture, change.old, change.next, 1))
		if err != nil || got == want {
			t.Fatal("a changed function/type/collation/argument/unknown field was normalized")
		}
	}
}

func TestAdvancedCopyIndexNodeDisplayQuotedAndNestedTokens(t *testing.T) {
	label := ` :label "quoted \":funcformat 3\" and \\ braces { }" :other (\:funcformat 3) :unknown {MYSTERY :funcformat 1}`
	before := strings.Replace(pgCopyFormatFixture, " :location", label+" :location", 1)
	got, err := pgAdvancedCopyIndexNodeFormats(before)
	if err != nil || got != strings.Replace(before, ":funcformat 2", ":funcformat 0", 1) || !strings.Contains(got.(string), label) {
		t.Fatal("quoted, escaped, unknown-node or nonfield tokens were rewritten")
	}
	nested := strings.Replace(pgCopyFormatFixture, ":args (", ":args ("+pgCopyFormatFixture+" ", 1)
	got, err = pgAdvancedCopyIndexNodeFormats(nested)
	if err != nil || got != strings.ReplaceAll(nested, ":funcformat 2", ":funcformat 0") {
		t.Fatal("nested function nodes were not separately bounded")
	}
	for _, value := range []any{nil, `{VAR :varno 1 :varattno 2}`, `{RELABELTYPE :relabelformat 2}`, `{MYSTERY :funcformat 3}`} {
		got, err := pgAdvancedCopyIndexNodeFormats(value)
		if err != nil || !reflect.DeepEqual(got, value) {
			t.Fatal("a different node/field was normalized by analogy")
		}
	}
}

func TestAdvancedCopyIndexNodeMalformedDisplayFailsClosed(t *testing.T) {
	for _, value := range []string{"-1", "4", "99", "01", "1.0", "NaN", `"2"`, "2suffix", "", ":funcformat 2", "2 :funcformat 3"} {
		if _, err := pgAdvancedCopyIndexNodeFormats(strings.Replace(pgCopyFormatFixture, ":funcformat 2", ":funcformat "+value, 1)); err == nil {
			t.Fatal("a missing/duplicate/malformed native display annotation was accepted")
		}
	}
	for _, value := range []any{
		strings.Replace(pgCopyFormatFixture, ":funcformat 2 ", "", 1), pgCopyFormatFixture[:len(pgCopyFormatFixture)-1],
		`{FUNCEXPR :funcformat 2 :label "unfinished}`, `{FUNCEXPR :funcformat 2 :args (}`, `{FUNCEXPR :funcformat 2 :value [}`, `{FUNCEXPR :funcformat 2 :value ([)]}`, `{FUNCEXPR :funcformat 2 :value ([})]}`, `\`, map[string]any{},
	} {
		if _, err := pgAdvancedCopyIndexNodeFormats(value); err == nil {
			t.Fatal("an incomplete native node representation was accepted")
		}
	}
}

func TestAdvancedCopyIndexNodeFormatRequiresProvenReplacement(t *testing.T) {
	row := func() map[string]any {
		return map[string]any{"indexrelid": "200", "indrelid": "20", "indexprs": pgCopyFormatFixture, "indpred": nil}
	}
	retained := row()
	m := &pgAdvancedCopyMap{indexLayout: map[string]bool{}}
	m.normalize(retained, "index")
	if retained["indexprs"] != pgPhysicalNodePositions(pgCopyFormatFixture) {
		t.Fatal("an unproved/retained index acquired semantic normalization")
	}
	replaced := row()
	m.indexLayout["200"] = true
	m.normalize(replaced, "index")
	want := pgPhysicalNodePositions(strings.Replace(pgCopyFormatFixture, ":funcformat 2", ":funcformat 0", 1))
	if replaced["indexprs"] != want {
		t.Fatal("proved replaced index did not use the bounded display comparison")
	}
	if retained["indexprs"] == replaced["indexprs"] {
		t.Fatal("replacement scope was silently globalized")
	}
}
