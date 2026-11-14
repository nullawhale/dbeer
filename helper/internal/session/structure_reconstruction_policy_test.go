package session

import (
	"context"
	"dbeer/helper/internal/protocol"
	"dbeer/helper/internal/tableedit"
	"testing"
)

type reconstructionPolicyAdapter struct{ structureFake }

func (reconstructionPolicyAdapter) StructurePrepare(context.Context, tableedit.Baseline, tableedit.Draft) (tableedit.Prepared, error) {
	return tableedit.Prepared{SQL: []string{"synthetic reviewed reconstruction"}}, nil
}
func (reconstructionPolicyAdapter) StructureApplySteps(context.Context, tableedit.Baseline, tableedit.Plan) []tableedit.Execution {
	return nil
}
func TestStructureReconstructionRequiresExactDestructiveGrantInDevelopment(t *testing.T) {
	o := &owner{id: "reconstruction-owner", structureOnly: true}
	a := reconstructionPolicyAdapter{}
	b, e := o.structure.Load(context.Background(), a, tableedit.Target{Schema: "fixture", Table: "samples"})
	if e != nil {
		t.Fatal(e)
	}
	p, e := o.structure.Preview(a, b.Baseline.ID, tableedit.Draft{AuthoringVersion: 5, Columns: []tableedit.Column{}, Reconstruct: true, AllowDestructive: true})
	if e != nil || !p.Plan.Destructive {
		t.Fatal("physical plan lost confirmation severity")
	}
	apply := tableedit.Apply{PlanID: p.Plan.ID, Digest: p.Plan.Digest, ExecutionID: "rebuild"}
	policy := protocol.ExecutionPolicy{Environment: "development"}
	command := protocol.Command{Type: "structure.apply", Structure: &tableedit.Request{Apply: &apply}}
	if o.authorize(command, "postgresql", policy) {
		t.Fatal("unconfirmed reconstruction admitted")
	}
	assessment := o.assess(protocol.Command{Operations: []protocol.OperationRequest{{Type: "structure.apply", Structure: &apply}}}, "postgresql", policy)
	if assessment.Assessment == nil || assessment.Assessment.Decision != "confirm" || assessment.Assessment.Operations[0].Kind != "destructive" {
		t.Fatal("reconstruction bypassed development confirmation")
	}
	command.Authorization = assessment.Assessment.Authorization
	if !o.authorize(command, "postgresql", policy) || o.authorize(command, "postgresql", policy) {
		t.Fatal("grant was not exact and single-use")
	}
}
