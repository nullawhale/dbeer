package session

import (
	"context"
	"testing"

	"dbeer/helper/internal/protocol"
	"dbeer/helper/internal/tableedit"
)

type structureStatusSession struct {
	isolatedStructureFake
	status string
}

func (s *structureStatusSession) TransactionStatus() string { return s.status }

func TestStructureStatusRetainsAcknowledgementWhenPhysicalStateIsUnknown(t *testing.T) {
	owner := &owner{id: "original-session"}
	apply := structurePlan(t, owner)
	retained, err := owner.structure.Apply(context.Background(), structureFake{}, apply)
	if err != nil || retained.Outcome == nil || retained.Outcome.State != "applied" {
		t.Fatal("fixture did not retain an acknowledged execution")
	}
	physical := &structureStatusSession{status: "unknown"}
	command := protocol.Command{Type: "structure.status", Structure: &tableedit.Request{}}
	response := owner.runStructure(context.Background(), physical, command)
	if response.Type != "structure.status.result" || response.Structure == nil || response.Structure.Outcome == nil {
		t.Fatal("retained execution status was unavailable after connection loss")
	}
	got := response.Structure.Outcome
	if got.ExecutionID != apply.ExecutionID || got.PlanID != apply.PlanID || got.State != "applied" || len(got.Steps) != 1 || got.Steps[0].State != "applied" {
		t.Fatal("status changed the retained execution evidence")
	}
	if response.Connected || response.TransactionStatus != "unknown" || physical.loads != 0 || physical.sqlCalls != 0 {
		t.Fatal("local status read touched the database or claimed a usable connection")
	}
	load := owner.runStructure(context.Background(), physical, protocol.Command{Type: "structure.load", Structure: &tableedit.Request{Target: &tableedit.Target{Schema: "public", Table: "samples"}}})
	if load.Type != "error" || physical.loads != 0 {
		t.Fatal("unknown physical state admitted a new database observation")
	}
}

func TestStructureStatusRequiresOriginalDedicatedOwnerAndPreservesMissingEvidence(t *testing.T) {
	physical := &structureStatusSession{status: "idle"}
	command := protocol.Command{Type: "structure.status", Structure: &tableedit.Request{}}
	ordinary := &owner{id: "ordinary"}
	if response := ordinary.runStructure(context.Background(), physical, command); response.Type != "error" {
		t.Fatal("ordinary owner read structure status")
	}
	dedicated := &owner{id: "new-structure-owner", structureOnly: true}
	response := dedicated.runStructure(context.Background(), physical, command)
	if response.Type != "structure.status.result" || response.Structure == nil || response.Structure.Outcome != nil {
		t.Fatal("an owner without an execution invented an outcome")
	}
	if physical.loads != 0 || physical.sqlCalls != 0 {
		t.Fatal("status lookup ran database work")
	}
}
