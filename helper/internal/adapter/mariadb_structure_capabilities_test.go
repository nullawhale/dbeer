package adapter

import (
	"dbeer/helper/internal/protocol"
	"slices"
	"testing"
)

func TestMariaDBStructureCapabilitiesRetainUnfinishedWorkflowGates(t *testing.T) {
	caps := Capabilities("mariadb")
	for _, cap := range []string{"tableStructureEditorV1", protocol.StructureAuthoringCapability, protocol.StructureIndexAuthoringCapability} {
		if !slices.Contains(caps, cap) {
			t.Fatal("proven ordinary native structure workflow is not admitted")
		}
	}
	for _, cap := range []string{"resultSourceV1", protocol.StructureReconstructionCapability, protocol.StructureDestructiveCapability, protocol.StructureMigrationsCapability, protocol.StructurePhysicalCapability, protocol.StructureAdvancedKindsCapability} {
		if slices.Contains(caps, cap) {
			t.Fatal("unfinished native workflow was advertised")
		}
	}
}
