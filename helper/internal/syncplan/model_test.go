package syncplan

import (
	"errors"
	"strings"
	"testing"
)

func TestPlanRequiresOrderedSupportedDependenciesAndSafeDefaults(t *testing.T) {
	valid := func() Plan {
		p := New("schema", "postgresql", strings.Repeat("a", 64))
		p.Steps = []Step{{ID: "table", Title: "Create table", SQL: "CREATE TABLE t(id int);", DependsOn: []string{}, Selected: true},
			{ID: "column", Title: "Add column", SQL: "ALTER TABLE t ADD COLUMN n int;", DependsOn: []string{"table"}, Selected: true}}
		return p
	}
	if valid().Validate() != nil {
		t.Fatal("valid dependency plan rejected")
	}
	for _, mutate := range []func(*Plan){
		func(p *Plan) { p.Steps[0].DependsOn = []string{"column"} },
		func(p *Plan) { p.Steps[0].Destructive = true },
		func(p *Plan) { p.Steps[0].Selected = false },
		func(p *Plan) { p.Steps[1].DependsOn = []string{"table", "table"} },
		func(p *Plan) {
			p.Steps[0].Manual = true
			p.Steps[0].Selected = false
			p.Steps[0].SQL = ""
			p.Steps[0].Reason = "Unsupported"
			p.Steps[1].Selected = false
		},
		func(p *Plan) { p.Steps[0].SQL = "" },
		func(p *Plan) { p.Steps[1].ID = "table" },
		func(p *Plan) { p.Steps[0].Title = "invalid\x00title" },
	} {
		p := valid()
		mutate(&p)
		if p.Validate() == nil {
			t.Fatal("unsafe plan admitted")
		}
	}
	p := valid()
	p.Steps[0].SQL = strings.Repeat("x", MaxBytes)
	if !errors.Is(p.Validate(), ErrLimit) {
		t.Fatal("encoded envelope budget not enforced")
	}
}
