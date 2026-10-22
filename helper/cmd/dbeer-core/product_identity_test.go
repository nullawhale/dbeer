package main

import (
	"bytes"
	"context"
	"encoding/json"
	"os"
	"path/filepath"
	"runtime"
	"strings"
	"testing"

	"dbeer/helper/internal/adapter"
	"dbeer/helper/internal/productidentity"
	"dbeer/helper/internal/protocol"
)

type forbiddenProductInput struct{ t *testing.T }

func (input forbiddenProductInput) Read([]byte) (int, error) {
	input.t.Fatal("metadata dispatch must not read helper or language-server input")
	return 0, nil
}

func productFixture(t *testing.T, name string) []byte {
	t.Helper()
	data, err := os.ReadFile(filepath.Join("..", "..", "..", "protocol", "fixtures", "gpui-build-identity-v1", name))
	if err != nil {
		t.Fatal("shared product fixture is unavailable")
	}
	return data
}

func TestBuildInfoDispatchPrecedesInputLanguageAndDatabaseEnvironment(t *testing.T) {
	t.Setenv("PGDATABASE", "synthetic-dispatch-marker")
	for _, args := range [][]string{
		{"--build-info"}, {"--build-info", "--language-server"},
		{"--language-server", "--build-info"}, {"--build-info=helper"}, {"--build-info-unknown"},
	} {
		var output bytes.Buffer
		if runCommand(args, forbiddenProductInput{t}, &output, "", "", "") != productidentity.ErrInvalid {
			t.Fatal("unmarked or mixed metadata dispatch must refuse structurally")
		}
		if output.Len() != 0 || os.Getenv("PGDATABASE") != "synthetic-dispatch-marker" {
			t.Fatal("metadata dispatch initialized ordinary helper work")
		}
	}
	for _, name := range []string{"valid-linux.json", "valid-windows.json"} {
		raw := productFixture(t, name)
		identity, err := productidentity.Parse(raw)
		if err != nil {
			t.Fatal("valid shared identity refused")
		}
		var output bytes.Buffer
		err = runCommand([]string{"--build-info"}, forbiddenProductInput{t}, &output, string(bytes.TrimSuffix(raw, []byte{'\n'})), identity.Version(), identity.BuildNumber())
		native := runtime.GOARCH == "amd64" && (runtime.GOOS == "linux" && identity.Target() == productidentity.LinuxX64 || runtime.GOOS == "windows" && identity.Target() == productidentity.WindowsX64)
		if (err == nil) != native {
			t.Fatal("build info must validate actual native target")
		}
		if native {
			info, parseErr := productidentity.ParseInfo(output.Bytes())
			if parseErr != nil || info.Component() != "helper" || info.Identity() != identity || output.Bytes()[output.Len()-1] != '\n' {
				t.Fatal("metadata dispatch did not emit exact helper information")
			}
		} else if output.Len() != 0 {
			t.Fatal("foreign metadata emitted build information")
		}
		if os.Getenv("PGDATABASE") != "synthetic-dispatch-marker" {
			t.Fatal("build info prepared database environment")
		}
	}
	for _, args := range [][]string{nil, {"--language-server"}} {
		var output bytes.Buffer
		if runCommand(args, forbiddenProductInput{t}, &output, "invalid-metadata", "", "") != productidentity.ErrInvalid || output.Len() != 0 {
			t.Fatal("invalid compiled marker fell through to ordinary startup")
		}
	}
}

func TestOptionalProductHelloDoesNoDatabaseWorkAndPreservesLegacyOutput(t *testing.T) {
	identity, err := productidentity.Parse(productFixture(t, "valid-linux.json"))
	if err != nil {
		t.Fatal("valid shared identity refused")
	}
	for _, attached := range []*productidentity.Identity{nil, &identity} {
		var output bytes.Buffer
		input := strings.NewReader("{\"type\":\"hello\",\"requestId\":\"hello\",\"protocolVersion\":5}\n{\"type\":\"shutdown\",\"requestId\":\"shutdown\"}\n")
		if err := runWithFactoryAndIdentity(input, &output, func(context.Context, protocol.Connection) (adapter.Session, error) {
			t.Fatal("hello must not open a database")
			return nil, nil
		}, attached); err != nil {
			t.Fatal("optional hello transport failed")
		}
		frame := bytes.Split(output.Bytes(), []byte{'\n'})[0]
		decoded, err := productidentity.OptionalFromHelloAck(frame, protocol.MaxFrameBytes)
		if err != nil || (decoded == nil) != (attached == nil) || decoded != nil && *decoded != identity {
			t.Fatal("optional product metadata did not survive actual hello output")
		}
		var fields map[string]json.RawMessage
		if json.Unmarshal(frame, &fields) != nil {
			t.Fatal("hello is not JSON")
		}
		if _, present := fields["buildIdentity"]; present != (attached != nil) {
			t.Fatal("unmarked helper emitted product identity")
		}
	}
}
