package productidentity

import (
	"bytes"
	"encoding/json"
	"os"
	"path/filepath"
	"runtime"
	"testing"
)

type fixtureCase struct {
	Name, File string
	Valid      bool
	Canonical  string
}
type nativeCase struct {
	OS, Architecture, ABI string
	Target                *NativeTarget
}
type fixtures struct {
	SchemaVersion                        int
	IdentityCases, InfoCases, HelloCases []fixtureCase
	NativeCases                          []nativeCase
}

func shared(t *testing.T) (string, fixtures) {
	t.Helper()
	root := "../../../protocol/fixtures/gpui-build-identity-v1"
	data, err := os.ReadFile(filepath.Join(root, "cases.json"))
	if err != nil {
		t.Fatal("cannot read shared identity fixture index")
	}
	var cases fixtures
	if json.Unmarshal(data, &cases) != nil || cases.SchemaVersion != 1 {
		t.Fatal("invalid shared identity fixture index")
	}
	return root, cases
}
func read(t *testing.T, root, name string) []byte {
	t.Helper()
	data, err := os.ReadFile(filepath.Join(root, name))
	if err != nil {
		t.Fatal("cannot read shared identity fixture")
	}
	return data
}
func TestSharedIdentityCodec(t *testing.T) {
	root, cases := shared(t)
	for _, entry := range cases.IdentityCases {
		t.Run(entry.Name, func(t *testing.T) {
			identity, err := Parse(read(t, root, entry.File))
			if (err == nil) != entry.Valid {
				t.Fatal("shared identity acceptance differs")
			}
			if !entry.Valid {
				return
			}
			canonical, err := identity.CanonicalJSON()
			if err != nil || !bytes.Equal(canonical, read(t, root, entry.Canonical)) {
				t.Fatal("canonical identity bytes differ")
			}
			encoded, err := json.Marshal(identity)
			if err != nil || !bytes.Equal(encoded, bytes.TrimSuffix(canonical, []byte{'\n'})) {
				t.Fatal("embedded identity bytes differ")
			}
			var decoded Identity
			if json.Unmarshal(encoded, &decoded) != nil || decoded != identity {
				t.Fatal("identity roundtrip differs")
			}
			capabilities := identity.Capabilities()
			capabilities[0] = "mutated"
			if identity.Capabilities()[0] != RequiredCapability {
				t.Fatal("identity exposes mutable capabilities")
			}
		})
	}
}
func TestSharedBuildInfoCodec(t *testing.T) {
	root, cases := shared(t)
	for _, entry := range cases.InfoCases {
		t.Run(entry.Name, func(t *testing.T) {
			info, err := ParseInfo(read(t, root, entry.File))
			if (err == nil) != entry.Valid {
				t.Fatal("shared build info acceptance differs")
			}
			if !entry.Valid {
				return
			}
			encoded, err := json.Marshal(info)
			if err != nil || !bytes.Equal(append(encoded, '\n'), read(t, root, entry.Canonical)) {
				t.Fatal("canonical build info bytes differ")
			}
		})
	}
}
func TestSharedNativeNormalization(t *testing.T) {
	_, cases := shared(t)
	for _, entry := range cases.NativeCases {
		target, err := NormalizeNativeTarget(entry.OS, entry.Architecture, entry.ABI)
		if entry.Target == nil {
			if err == nil {
				t.Fatal("unsupported target accepted")
			}
			continue
		}
		if err != nil || target != *entry.Target {
			t.Fatal("native target normalization differs")
		}
	}
}
func TestCompiledAuthorityAndUnmarkedCompatibility(t *testing.T) {
	root, _ := shared(t)
	if identity, err := OptionalCompiled("", "", ""); err != nil || identity != nil {
		t.Fatal("unmarked development helper refused")
	}
	if _, err := HelperJSON("", "", ""); err == nil {
		t.Fatal("unmarked helper claims product build info")
	}
	for _, name := range []string{"valid-linux.json", "valid-windows.json"} {
		raw := read(t, root, name)
		identity, err := Parse(raw)
		if err != nil {
			t.Fatal("valid fixture refused")
		}
		expectedNative := runtime.GOARCH == "amd64" && (runtime.GOOS == "linux" && identity.Target() == LinuxX64 || runtime.GOOS == "windows" && identity.Target() == WindowsX64)
		if (identity.ValidateNative(identity.Version(), identity.BuildNumber()) == nil) != expectedNative {
			t.Fatal("actual native runtime validation differs")
		}
		// No environment override may turn a foreign product into this host.
		t.Setenv("GOOS", "windows")
		t.Setenv("GOARCH", "amd64")
		t.Setenv("DBEER_PRODUCT_BUILD_IDENTITY", string(raw))
		if (identity.ValidateNative(identity.Version(), identity.BuildNumber()) == nil) != expectedNative {
			t.Fatal("environment changes product authority")
		}
		if identity.ValidateNative("9.9.9", identity.BuildNumber()) == nil || identity.ValidateNative(identity.Version(), "999") == nil {
			t.Fatal("compiled release mismatch accepted")
		}
		output, err := HelperJSON(string(raw), identity.Version(), identity.BuildNumber())
		if (err == nil) != expectedNative {
			t.Fatal("build info ignores native validation")
		}
		if expectedNative {
			info, err := ParseInfo(output)
			if err != nil || info.Component() != "helper" || info.Identity() != identity {
				t.Fatal("helper build info differs")
			}
		}
	}
}
func TestExactHelperMatchBeforeProductWork(t *testing.T) {
	root, _ := shared(t)
	identity, err := Parse(read(t, root, "valid-linux.json"))
	if err != nil {
		t.Fatal("valid fixture refused")
	}
	caps := []string{RequiredCapability}
	if identity.RequireMatching(&identity, 3, caps) != nil || identity.RequireMatching(nil, 3, caps) == nil || identity.RequireMatching(&identity, 2, caps) == nil || identity.RequireMatching(&identity, 3, nil) == nil {
		t.Fatal("product handshake validation differs")
	}
	for _, field := range []string{"version", "build", "target", "source"} {
		other := identity
		switch field {
		case "version":
			other.version = "0.2.1"
		case "build":
			other.buildNumber = "2"
		case "target":
			other.target = WindowsX64
		case "source":
			other.sourceSHA256 = string(bytes.Repeat([]byte{'b'}, 64))
		}
		if identity.RequireMatching(&other, 3, caps) == nil {
			t.Fatal("different product identity accepted")
		}
	}
}

func TestOptionalSharedHelloMetadata(t *testing.T) {
	root, cases := shared(t)
	for _, entry := range cases.HelloCases {
		t.Run(entry.Name, func(t *testing.T) {
			identity, err := OptionalFromHelloAck(read(t, root, entry.File), 16*1024*1024)
			if (err == nil) != entry.Valid {
				t.Fatal("shared optional hello metadata acceptance differs")
			}
			if !entry.Valid {
				return
			}
			if entry.Canonical == "" {
				if identity != nil {
					t.Fatal("absent identity became required")
				}
				return
			}
			if identity == nil {
				t.Fatal("present identity lost")
			}
			canonical, err := identity.CanonicalJSON()
			if err != nil || !bytes.Equal(canonical, read(t, root, entry.Canonical)) {
				t.Fatal("optional identity differs")
			}
		})
	}
}
