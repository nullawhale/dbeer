package tableedit

import (
	"context"
	"testing"
)

func TestAuthoringExpressionSlotsDoNotEvaluateOrEscape(t *testing.T) {
	for _, x := range []struct{ engine, expression string }{
		{"postgresql", "now()::text"}, {"postgresql", "CASE WHEN 1 < 2 THEN 'a;--b' ELSE 'x' END"},
		{"postgresql", "ARRAY[1,2]"}, {"postgresql", "length($body$a;)--$body$)"},
		{"mysql", "concat('a', 'b')"}, {"sqlite", "length('it''s')"},
	} {
		if _, e := ExpressionSlot(x.engine, x.expression); e != nil {
			t.Errorf("valid bounded expression rejected for %s", x.engine)
		}
	}
	for _, x := range []struct{ engine, expression string }{
		{"postgresql", "1); DROP TABLE x; (1"}, {"postgresql", "1, another integer"},
		{"postgresql", "1-- comment"}, {"postgresql", "1/* comment */"}, {"postgresql", "$1"},
		{"postgresql", "now("}, {"postgresql", "1)"}, {"postgresql", "ARRAY[1,2"},
		{"postgresql", "E'\\x'"}, {"mysql", "'a\\' OR 1=1"}, {"mysql", "$$1; DROP TABLE x$$"},
	} {
		if _, e := ExpressionSlot(x.engine, x.expression); e == nil {
			t.Errorf("escaping or unsupported expression accepted for %s", x.engine)
		}
	}
}

func TestAuthoringV2IsExplicitAndIdentityValuesStayExact(t *testing.T) {
	text := "now()"
	d := Draft{Columns: []Column{{Name: "created", Type: DataType{Kind: "text"}, Nullable: true, Default: Default{Kind: "expression", Value: &text}}}}
	if d.Valid() {
		t.Fatal("legacy draft accepted expression intent")
	}
	d.AuthoringVersion = 2
	if !d.Valid() {
		t.Fatal("explicit draft rejected")
	}
	start := "9007199254740993"
	x := Identity{Kind: "byDefault", Start: &start}
	if !x.Valid() || *x.Start != start {
		t.Fatal("exact sequence start lost")
	}
	bad := "01"
	x.Start = &bad
	if x.Valid() {
		t.Fatal("noncanonical sequence number accepted")
	}
}

func TestExpressionDollarQuotesRequireTokenBoundary(t *testing.T) {
	for _, raw := range []string{"name$tag$); DROP TABLE guarded; SELECT ($tag$", "name$$); DROP TABLE guarded; SELECT ($$"} {
		if _, err := ExpressionSlot("postgresql", raw); err == nil {
			t.Fatal("identifier suffix was mistaken for a dollar-quoted literal")
		}
	}
	if _, err := ExpressionSlot("postgresql", "$$); arbitrary text ; ($$"); err != nil {
		t.Fatal("genuine dollar string rejected")
	}
}

func TestSQLiteBracketIdentifiersCannotHideEscapingSQL(t *testing.T) {
	if _, err := ExpressionSlot("sqlite", `[odd";name] + 1`); err != nil {
		t.Fatal("bounded bracket identifier rejected")
	}
	for _, raw := range []string{`["] ); DROP TABLE guarded;--"]`, `["] ), another INTEGER --"]`, `?`, `:value`, `@value`, `$value`} {
		if _, err := ExpressionSlot("sqlite", raw); err == nil {
			t.Fatal("escaping bracket identifier or parameter accepted")
		}
	}
}

func TestAuthoredUserCodeRetainsExplicitPolicyReview(t *testing.T) {
	expression := "probe()"
	for _, c := range []Column{
		{Name: "value", Type: DataType{Kind: "integer"}, Nullable: true, Default: Default{Kind: "expression", Value: &expression}},
		{Name: "value", Type: DataType{Kind: "reference", Reference: &TypeReference{Schema: "public", Name: "domain"}}, Nullable: true, Default: Default{Kind: "none"}},
	} {
		store := &Store{}
		adapter := &authoringPolicyFake{}
		b, err := store.Load(context.Background(), adapter, Target{Schema: "public", Table: "authored", Create: true})
		if err != nil {
			t.Fatal(err)
		}
		p, err := store.Preview(adapter, b.Baseline.ID, Draft{AuthoringVersion: 2, Columns: []Column{c}})
		if err != nil || !p.Plan.Destructive {
			t.Fatal("authored user-code effects bypassed explicit policy review")
		}
		if adapter.calls != 0 {
			t.Fatal("Preview dispatched authored code")
		}
	}
}

type authoringPolicyFake struct{ fake }

func (f *authoringPolicyFake) StructurePrepare(context.Context, Baseline, Draft) (Prepared, error) {
	return Prepared{SQL: []string{"synthetic authored step"}, Risks: []string{"synthetic risk"}}, nil
}
func (f *authoringPolicyFake) StructureApplySteps(context.Context, Baseline, Plan) []Execution {
	return nil
}
