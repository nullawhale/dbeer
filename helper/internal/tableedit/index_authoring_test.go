package tableedit

import (
	sc "dbeer/helper/internal/schemacompare"
	"encoding/json"
	"fmt"
	"strings"
	"testing"
)

func TestAdvancedIndexDraftVersionBoundsAndEffectConfirmation(t *testing.T) {
	expression := "lower(value)"
	definition := IndexDefinition{Method: "btree", Terms: []IndexTerm{{Expression: &expression}}}
	draft := Draft{AuthoringVersion: 3, Columns: []Column{}, Indexes: []IndexEdit{{Action: "add", Name: "computed_idx", Definition: &definition}}}
	if draft.Validate() != nil || !draft.HasAuthoredExpressions() || !draft.RequiresEffectConfirmation() {
		t.Fatal("valid advanced index intent was not admitted as a confirmed effect")
	}
	for _, version := range []int{0, 2, 6} {
		other := draft
		other.AuthoringVersion = version
		if other.Validate() == nil {
			t.Fatal("advanced index bypassed its explicit version")
		}
	}
	for _, change := range []func(*IndexDefinition){
		func(x *IndexDefinition) { x.Terms = nil },
		func(x *IndexDefinition) { v := "value"; x.Terms[0].Column = &v },
		func(x *IndexDefinition) { v := int64(0); x.Terms[0].PrefixLength = &v },
		func(x *IndexDefinition) { v := int64(65536); x.Terms[0].PrefixLength = &v },
		func(x *IndexDefinition) { v := strings.Repeat("x", 4097); x.Terms[0].Expression = &v },
		func(x *IndexDefinition) { x.Includes = []string{"id", "id"} },
		func(x *IndexDefinition) {
			x.Options = []IndexOption{{Name: "fillfactor", Value: "80"}, {Name: "fillfactor", Value: "90"}}
		},
		func(x *IndexDefinition) {
			x.Options = []IndexOption{{Name: "comment", Value: strings.Repeat("x", 1025)}}
		},
	} {
		raw, _ := json.Marshal(definition)
		var changed IndexDefinition
		_ = json.Unmarshal(raw, &changed)
		change(&changed)
		if changed.Valid() {
			t.Fatal("invalid advanced index structure was admitted")
		}
	}
	mixed := draft
	mixed.Indexes = []IndexEdit{{Action: "add", Name: "mixed", Columns: []string{"value"}, Definition: &definition}}
	if mixed.Validate() == nil {
		t.Fatal("mixed legacy and advanced key forms were admitted")
	}
	mixed.Indexes[0].Columns = []string{}
	if mixed.Validate() == nil {
		t.Fatal("explicit empty legacy keys were mixed with an advanced definition")
	}
	column := "value"
	plain := IndexDefinition{Method: "btree", Terms: []IndexTerm{{Column: &column}}}
	draft.Indexes[0].Definition = &plain
	if draft.HasAuthoredExpressions() || !draft.RequiresEffectConfirmation() {
		t.Fatal("advanced comparator effects lost confirmation")
	}
}

func TestCatalogIndexExpressionListKeepsNestedCommasAndLiteralBytes(t *testing.T) {
	raw := `lower(value), concat('a,b', value), ARRAY[1,2], $body$a,b$body$`
	parts, ok := SplitExpressionList("postgresql", raw)
	if !ok || len(parts) != 4 || parts[1] != `concat('a,b', value)` || parts[3] != `$body$a,b$body$` {
		t.Fatal("catalog expression boundaries were changed")
	}
	for _, raw := range []string{`value,`, `value),other`, `value /* comment */`, `E'a\'b',other`, `$broken$unclosed`, `value;other`, `value,$1`} {
		if _, ok := SplitExpressionList("postgresql", raw); ok {
			t.Fatal("uncertain catalog expression list was admitted")
		}
	}
}

func TestIndexVerificationRejectsUnexpectedSelectedDefaultsAndOptions(t *testing.T) {
	expression := "lower(value)"
	wanted := IndexDefinition{Method: "btree", Terms: []IndexTerm{{Expression: &expression}}, Options: []IndexOption{{Name: "fillfactor", Value: "80"}}}
	before := transitionFixture("postgresql")
	after := before
	after.Facts = cloneFacts(before.Facts)
	after.Facts.IndexDefaultOpclasses = map[string][]bool{"idx": {true}}
	after.Facts.IndexDefaultCollations = map[string][]bool{"idx": {true}}
	actual := IndexFacts("postgresql", before.Target, "idx", false, wanted)
	if !IndexDefinitionMatches(before, after, actual, wanted) {
		t.Fatal("matching selected index definition was rejected")
	}
	after.Facts.IndexDefaultCollations["idx"][0] = false
	if IndexDefinitionMatches(before, after, actual, wanted) {
		t.Fatal("unexpected key collation override was accepted as the default")
	}
	after.Facts.IndexDefaultCollations["idx"][0] = true
	after.Facts.IndexDefaultOpclasses["idx"][0] = false
	if IndexDefinitionMatches(before, after, actual, wanted) {
		t.Fatal("unexpected nondefault operator class was accepted")
	}
	after.Facts.IndexDefaultOpclasses["idx"][0] = true
	actual.Options.Items[0].Value = "90"
	if IndexDefinitionMatches(before, after, actual, wanted) {
		t.Fatal("unexpected selected storage option was accepted")
	}
}

func TestRichIndexEditDoesNotBecomeForeignOrIdentitySupport(t *testing.T) {
	column, expression := "id", "id*2"
	definition := IndexDefinition{Method: "btree", Terms: []IndexTerm{{Column: &column}}}
	index := Index{Name: "idx", Supported: true, Definition: &definition}
	if !SupportingIndex(index, []string{"id"}) {
		t.Fatal("plain explicitly structured key lost support")
	}
	prefix := int64(4)
	definition.Terms[0].PrefixLength = &prefix
	if SupportingIndex(index, []string{"id"}) {
		t.Fatal("prefix key became full-column support")
	}
	definition.Terms[0].PrefixLength = nil
	definition.Terms[0].Column = nil
	definition.Terms[0].Expression = &expression
	if SupportingIndex(index, []string{"id"}) {
		t.Fatal("expression key became column support")
	}
}

func TestBuiltinVarcharIndexComparisonRequiresExactCatalogProof(t *testing.T) {
	b := transitionFixture("postgresql")
	b.Facts.Table.Columns.Items[0].Type = sc.Known(ExpectedNewType("postgresql", DataType{Kind: "varchar", Length: 40}))
	b.Facts.ExpressionKeywords = []string{}
	b.Facts.IndexBuiltinFunctions = map[string][]string{"idx": {"lower"}}
	if !builtinIndexExpressionMatches(b, "lower((value)::text)", "lower(value)", "idx", 0) {
		t.Fatal("proven builtin binary relabel rejected")
	}
	for _, pair := range [][2]string{{"upper((value)::text)", "lower(value)"}, {"public.lower((value)::text)", "lower(value)"}, {"lower((other)::text)", "lower(value)"}, {"lower((value)::text) || ''", "lower(value)"}, {"lower((value)::text)", "public.lower(value)"}, {"lower((value)::text)", "lower('value')"}} {
		if builtinIndexExpressionMatches(b, pair[0], pair[1], "idx", 0) {
			t.Fatal("unproven function, source or expression was conflated")
		}
	}
	b.Facts.IndexBuiltinFunctions = nil
	if builtinIndexExpressionMatches(b, "lower((value)::text)", "lower(value)", "idx", 0) {
		t.Fatal("missing root identity proof accepted")
	}
	b.Facts.IndexBuiltinFunctions = map[string][]string{"idx": {"lower"}}
	b.Facts.Table.Columns.Items[0].Type.Value.Ref.Schema = "custom"
	if builtinIndexExpressionMatches(b, "lower((value)::text)", "lower(value)", "idx", 0) {
		t.Fatal("custom same-named type accepted as binary VARCHAR")
	}
}

func TestIndexAttributeSummaryDoesNotPoisonLargeValidBaseline(t *testing.T) {
	for _, existingCount := range []int{2, 64} {
		b := transitionFixture("postgresql")
		b.Limitations = make([]string, existingCount)
		for i := range b.Limitations {
			b.Limitations[i] = "existing limitation"
		}
		b.Facts.IndexAttributes = map[string]map[string]string{}
		for i := 0; i < 63; i++ {
			name := fmt.Sprintf("protected_%d", i)
			column := "value"
			x := IndexFacts("postgresql", b.Target, name, false, IndexDefinition{Method: "btree", Terms: []IndexTerm{{Column: &column}}})
			x.Options.Complete = false
			x.Options.State = "unavailable"
			x.Options.Code = "unmodeledIndexProperties"
			b.Facts.Table.Indexes.Items = append(b.Facts.Table.Indexes.Items, x)
			b.Facts.IndexAttributes[name] = map[string]string{"reason": "comment", "comment": "kept"}
		}
		Summarize(&b)
		Summarize(&b)
		if !ValidBaseline(b) || len(b.Limitations) > 64 || len(b.Facts.IndexAttributes) != 63 {
			t.Fatal("bounded readonly summary invalidated a supported baseline or lost evidence")
		}
		for _, index := range b.Indexes {
			if index.Supported {
				t.Fatal("unmodeled attribute index became independently editable")
			}
		}
		column := "value"
		draft := Draft{AuthoringVersion: 3, Columns: []Column{}, Indexes: []IndexEdit{{Action: "add", Name: "safe_new", Definition: &IndexDefinition{Method: "btree", Terms: []IndexTerm{{Column: &column}}}}}}
		operations, _, err := PlanOperations(b, draft, "postgresql", func(Target) (Baseline, error) { t.Fatal("unexpected reference load"); return Baseline{}, nil })
		if err != nil || len(operations) != 1 || operations[0].Kind != "addIndex" {
			t.Fatal("unrelated safe additive index was blocked by readonly neighbors")
		}
		if err := CheckRemoval(b, Draft{}, "protected_0", false); err == nil || !strings.Contains(err.Error(), "comment") {
			t.Fatal("selected index did not retain its concrete unavailable reason")
		}
	}
}
