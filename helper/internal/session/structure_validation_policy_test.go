package session

import (
	"dbeer/helper/internal/protocol"
	"dbeer/helper/internal/tableedit"
	"testing"
)

func TestStructureValidationRequiresSeparateExactSingleUseReadGrant(t *testing.T) {
	for _, readonly := range []bool{false, true} {
		o := &owner{id: "structure-owner"}
		a := structurePlan(t, o)
		policy := protocol.ExecutionPolicy{Environment: "development", ReadOnly: readonly}
		request := protocol.Command{Type: "structure.validate", Structure: &tableedit.Request{Validation: &a}}
		if o.authorize(request, "postgresql", policy) {
			t.Fatal("validation read without explicit authorization")
		}
		response := o.assess(protocol.Command{Operations: []protocol.OperationRequest{{Type: "structure.validate", Structure: &a}}}, "postgresql", policy)
		if response.Assessment == nil || response.Assessment.Decision != "confirm" || response.Assessment.Operations[0].Kind != "read" {
			t.Fatal("separate read confirmation was not required")
		}
		request.Authorization = response.Assessment.Authorization
		apply := protocol.Command{Type: "structure.apply", Structure: &tableedit.Request{Apply: &a}, Authorization: request.Authorization}
		if o.authorize(apply, "postgresql", policy) {
			t.Fatal("validation grant authorized Apply")
		}
		response = o.assess(protocol.Command{Operations: []protocol.OperationRequest{{Type: "structure.validate", Structure: &a}}}, "postgresql", policy)
		request.Authorization = response.Assessment.Authorization
		if !o.authorize(request, "postgresql", policy) || o.authorize(request, "postgresql", policy) {
			t.Fatal("validation grant was not exact and single-use")
		}
	}
	o := &owner{id: "ordinary"}
	a := tableedit.Apply{PlanID: "p", Digest: tableedit.Fingerprint("p"), ExecutionID: "v"}
	response := o.assess(protocol.Command{Operations: []protocol.OperationRequest{{Type: "structure.validate", Structure: &a}}}, "postgresql", protocol.ExecutionPolicy{Environment: "development"})
	if response.Type != "error" {
		t.Fatal("ordinary session obtained structure validation grant")
	}
}
