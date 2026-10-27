package protocol

import (
	"bytes"
	"encoding/json"
	"os"
	"path/filepath"
	"testing"

	"dbeer/helper/internal/productidentity"
)

func TestHelloResponseCarriesOnlyValidatedOptionalProductIdentity(t *testing.T) {
	raw, err := os.ReadFile(filepath.Join("..", "..", "..", "protocol", "fixtures", "gpui-build-identity-v1", "valid-linux.json"))
	if err != nil {
		t.Fatal("shared product fixture is unavailable")
	}
	identity, err := productidentity.Parse(raw)
	if err != nil {
		t.Fatal("valid shared identity refused")
	}
	for _, attached := range []*productidentity.Identity{nil, &identity} {
		frame, err := json.Marshal(Response{Type: "hello.ack", RequestID: "fixture", ProtocolVersion: Version, Capabilities: []string{"capturedExportV1"}, BuildIdentity: attached})
		if err != nil {
			t.Fatal("hello product encoding failed")
		}
		parsed, err := productidentity.OptionalFromHelloAck(frame, MaxFrameBytes)
		if err != nil || (parsed == nil) != (attached == nil) || parsed != nil && *parsed != identity {
			t.Fatal("hello product identity differs")
		}
		if bytes.Contains(frame, []byte("buildIdentity")) != (attached != nil) {
			t.Fatal("optional product field differs")
		}
	}
	invalid := productidentity.Identity{}
	if _, err := json.Marshal(Response{Type: "hello.ack", RequestID: "fixture", ProtocolVersion: Version, BuildIdentity: &invalid}); err == nil {
		t.Fatal("invalid product identity reached wire output")
	}
}
