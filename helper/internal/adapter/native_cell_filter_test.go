package adapter

import (
	"slices"
	"testing"

	"dbeer/helper/internal/protocol"
)

func TestNativeCellFilterCapabilitiesAreOnlyAdvertisedByImplementedEngines(t *testing.T) {
	for _, engine := range []string{"postgresql", "mysql", "sqlite", "cassandra", "mongodb", "unknown"} {
		got := slices.Contains(Capabilities(engine), protocol.NativeCellFilterCapability)
		want := engine == "postgresql" || engine == "mysql" || engine == "sqlite"
		if got != want {
			t.Fatal("engine advertises an unsupported native cell filter capability")
		}
	}
}
