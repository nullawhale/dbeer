package adapter

import (
	"slices"
	"testing"
)

func TestEngineCapabilitiesDescribeActualGuarantees(t *testing.T) {
	cassandra := Capabilities("cassandra")
	for _, unsupported := range []string{"transactions", "serverReadOnly"} {
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
		for _, supported := range []string{"transactions", "gridEditing", "serverReadOnly"} {
			if !slices.Contains(Capabilities(engine), supported) {
				t.Fatalf("%s lacks %s", engine, supported)
			}
		}
	}
	if Capabilities("unknown") != nil {
		t.Fatal("unknown engine advertises features")
	}
}
