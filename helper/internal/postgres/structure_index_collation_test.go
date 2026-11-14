package postgres

import "testing"

func TestIndexExpressionRootCollationIgnoresNestedChildren(t *testing.T) {
	raw := `({FUNCEXPR :funcid 1 :funccollid 100 :inputcollid 950 :args ({VAR :varcollid 950})} {COLLATEEXPR :arg {FUNCEXPR :funccollid 100 :args <>} :collOid 950} {CASEEXPR :casecollid 100 :arg <> :args ({CASEWHEN :expr {CONST :constcollid 950} :result {VAR :varcollid 950}})})`
	values, ok := catalogIndexExpressionCollations(raw)
	if !ok || len(values) != 3 {
		t.Fatal("valid raw catalog node list rejected")
	}
	for i, want := range []string{"100", "950", "100"} {
		if !values[i].known || values[i].oid != want {
			t.Fatal("nested collation replaced the root result collation")
		}
	}
	values, ok = catalogIndexExpressionCollations(`({FUTUREEXPR :args ({VAR :varcollid 950})})`)
	if !ok || len(values) != 1 || values[0].known {
		t.Fatal("unknown future root was assigned a child's collation")
	}
	for _, raw := range []string{`({FUNCEXPR :funccollid 100 :funccollid 950})`, `({FUNCEXPR :funccollid 100`, `({FUNCEXPR :funccollid 100 :args (})`} {
		if _, ok := catalogIndexExpressionCollations(raw); ok {
			t.Fatal("malformed raw catalog proof was admitted")
		}
	}
}
