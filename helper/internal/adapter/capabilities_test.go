package adapter

import (
	"dbeer/helper/internal/protocol"
	"slices"
	"testing"
)

func TestEngineCapabilitiesDescribeActualGuarantees(t *testing.T) {
	cassandra := Capabilities("cassandra")
	for _, unsupported := range []string{"transactions", "serverReadOnly", protocol.QueryParametersCapability, protocol.TableImportCapability} {
		if slices.Contains(cassandra, unsupported) {
			t.Fatalf("Cassandra advertises unsupported %s", unsupported)
		}
	}
	for _, supported := range []string{"execute", "localReadOnly", "cursorPagination", "gridEditing"} {
		if !slices.Contains(cassandra, supported) {
			t.Fatalf("Cassandra lacks %s", supported)
		}
	}
	for _, engine := range []string{"postgresql", "mysql"} {
		for _, supported := range []string{"transactions", "gridEditing", "serverReadOnly", protocol.QueryParametersCapability, protocol.TableImportCapability} {
			if !slices.Contains(Capabilities(engine), supported) {
				t.Fatalf("%s lacks %s", engine, supported)
			}
		}
	}
	if Capabilities("unknown") != nil {
		t.Fatal("unknown engine advertises features")
	}
	for _, engine := range []string{"postgresql", "mysql", "sqlite", "cassandra", "mongodb"} {
		seen := make(map[string]bool)
		for _, capability := range Capabilities(engine) {
			if seen[capability] {
				t.Fatalf("%s repeats a capability", engine)
			}
			seen[capability] = true
		}
		authoring := engine == "postgresql" || engine == "mysql" || engine == "sqlite"
		if slices.Contains(Capabilities(engine), protocol.StructureAuthoringCapability) != authoring {
			t.Fatalf("%s has an invalid structure authoring capability", engine)
		}
		if slices.Contains(Capabilities(engine), protocol.StructureReconstructionCapability) != authoring {
			t.Fatalf("%s has an invalid reconstruction capability", engine)
		}
		if slices.Contains(Capabilities(engine), protocol.StructureDestructiveCapability) != authoring {
			t.Fatalf("%s has an invalid destructive structure capability", engine)
		}
		if slices.Contains(Capabilities(engine), protocol.StructureIndexAuthoringCapability) != (engine == "postgresql" || engine == "mysql") {
			t.Fatal("advanced index capability escaped its completed adapters")
		}
		if !slices.Contains(Capabilities(engine), protocol.NativeResultValuesCapability) {
			t.Fatalf("%s lacks its completed native result contract", engine)
		}
		if slices.Contains(Capabilities(engine), protocol.SessionMonitorCapability) != (engine == "postgresql" || engine == "mysql") {
			t.Fatalf("%s has an invalid session monitor capability", engine)
		}
	}
}
