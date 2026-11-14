package adapter

import (
	"dbeer/helper/internal/protocol"
	"strings"
	"testing"
)

func TestExplainBoundReviewAndGenericVersionGate(t *testing.T) {
	value := "9007199254740993.125"
	nullText := "NULL ' ; DELETE FROM evidence; --"
	parameters := []protocol.QueryParameter{{Name: "n", Type: "decimal", Value: &value}, {Name: "text", Type: "text", Value: &nullText}}
	for _, engine := range []string{"postgresql", "mysql"} {
		support := ExplainSupport(engine, map[string]string{"postgresql": "17.6", "mysql": "8.4.6"}[engine])
		p, err := PrepareExplain(support, protocol.ExplainRequest{SQL: "SELECT :n, :text, :n", Mode: "plan", Parameters: parameters})
		if err != nil || strings.Contains(p.Preview.SQL, value) || strings.Contains(p.Preview.SQL, nullText) || strings.Contains(p.Preview.SQL, ":n") || len(p.Bound.Parameters) < 2 {
			t.Fatal("review did not use typed driver bindings")
		}
		if p.Bound.Parameters[0].Value == nil || *p.Bound.Parameters[0].Value != value {
			t.Fatal("numeric precision changed")
		}
	}
	r := protocol.ExplainRequest{SQL: "SELECT :n, :text, :n", Mode: "plan", Parameters: parameters, PlanKind: "generic"}
	for _, version := range []string{"14.0", "15.10", "16.0", "17.6"} {
		p, err := PrepareExplain(ExplainSupport("postgresql", version), r)
		if strings.HasPrefix(version, "14.") || strings.HasPrefix(version, "15.") {
			if err == nil {
				t.Fatal("old server advertised generic Explain")
			}
			continue
		}
		if err != nil || !strings.Contains(p.Preview.SQL, "GENERIC_PLAN TRUE") || strings.Count(p.Preview.SQL, "$1::pg_catalog.numeric") != 2 || strings.Contains(p.Preview.SQL, value) {
			t.Fatal("generic plan lost typed placeholder")
		}
	}
	r.Mode = "analyze"
	if _, err := PrepareExplain(ExplainSupport("postgresql", "17.6"), r); err == nil {
		t.Fatal("generic Analyze accepted")
	}
	for _, sql := range []string{"SELECT :n; DELETE FROM evidence", "SELECT fixture_unknown(:n) FOR UPDATE", "SELECT nextval(:n)"} {
		r.SQL = sql
		r.Mode = "plan"
		r.PlanKind = ""
		if _, err := PrepareExplain(ExplainSupport("postgresql", "17.6"), r); err == nil {
			t.Fatal("unsafe parameterized target accepted")
		}
	}
}
