package session

import (
	"context"
	"dbeer/helper/internal/protocol"
	"dbeer/helper/internal/tableedit"
	"testing"
)

type identityEffectPolicyAdapter struct{ structureFake }

func (identityEffectPolicyAdapter) StructurePrepare(context.Context, tableedit.Baseline, tableedit.Draft) (tableedit.Prepared, error) {
	return tableedit.Prepared{SQL: []string{"synthetic identity enable"}, Risks: []string{"existing zero values may be generated"}}, nil
}
func (identityEffectPolicyAdapter) StructureApplySteps(context.Context, tableedit.Baseline, tableedit.Plan) []tableedit.Execution {
	return nil
}

func TestStructureIdentityValueEffectsRequireExactConfirmedGrantInDevelopment(t *testing.T) {
	o := &owner{id: "original-owner", structureOnly: true}
	a := identityEffectPolicyAdapter{}
	b, err := o.structure.Load(context.Background(), a, tableedit.Target{Schema: "fixture", Table: "samples"})
	if err != nil {
		t.Fatal(err)
	}
	p, err := o.structure.Preview(a, b.Baseline.ID, tableedit.Draft{AuthoringVersion: 2, Columns: []tableedit.Column{}, Changes: []tableedit.ColumnChange{{Name: "id", Identity: &tableedit.Identity{Kind: "autoIncrement"}}}})
	if err != nil || !p.Plan.Destructive {
		t.Fatal("identity effect did not retain confirmation severity")
	}
	apply := tableedit.Apply{PlanID: p.Plan.ID, Digest: p.Plan.Digest, ExecutionID: "identity-effect"}
	op := protocol.OperationRequest{Type: "structure.apply", Structure: &apply}
	policy := protocol.ExecutionPolicy{Environment: "development"}
	command := protocol.Command{Type: "structure.apply", Structure: &tableedit.Request{Apply: &apply}}
	if o.authorize(command, "mysql", policy) {
		t.Fatal("identity effect dispatched without exact grant")
	}
	assessed := o.assess(protocol.Command{Operations: []protocol.OperationRequest{op}}, "mysql", policy)
	if assessed.Assessment == nil || assessed.Assessment.Decision != "confirm" || assessed.Assessment.Operations[0].Kind != "destructive" {
		t.Fatal("development identity effect bypassed confirmation")
	}
	command.Authorization = assessed.Assessment.Authorization
	if !o.authorize(command, "mysql", policy) || o.authorize(command, "mysql", policy) {
		t.Fatal("identity effect grant was not exact and single-use")
	}
}
