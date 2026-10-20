// Package productidentity implements the optional GPUI product metadata contract.
// It performs no process, environment, database, credential or transport setup.
package productidentity

import (
	"bytes"
	"encoding/json"
	"errors"
	"io"
	"runtime"
	"strconv"
	"unicode/utf8"
)

const (
	ProductID          = "app.dbeer.DBeer"
	ProtocolVersion    = 3
	ContractRevision   = "gpui-v3-captured-export-v1"
	RequiredCapability = "capturedExportV1"
	MaxIdentityBytes   = 4096
	MaxInfoBytes       = MaxIdentityBytes + 64
)

// ErrInvalid deliberately contains no caller-supplied metadata.
var ErrInvalid = errors.New("The DBeer application and helper build identities do not match. Extract a complete matching package.")

type NativeTarget string

const (
	WindowsX64 NativeTarget = "windows-x86_64-msvc"
	LinuxX64   NativeTarget = "linux-x86_64-gnu"
)

// NormalizeNativeTarget is a pure toolchain-label codec, not runtime validation.
func NormalizeNativeTarget(os, architecture, abi string) (NativeTarget, error) {
	if architecture != "x86_64" && architecture != "amd64" {
		return "", ErrInvalid
	}
	switch {
	case os == "windows" && abi == "msvc":
		return WindowsX64, nil
	case os == "linux" && abi == "gnu":
		return LinuxX64, nil
	default:
		return "", ErrInvalid
	}
}

// Identity has no exported mutable fields or slices. Construct it with Parse.
// The source digest identifies packaging source inputs, not executable bytes.
type Identity struct {
	version, buildNumber string
	target               NativeTarget
	sourceSHA256         string
}

func (v Identity) Version() string        { return v.version }
func (v Identity) BuildNumber() string    { return v.buildNumber }
func (v Identity) Target() NativeTarget   { return v.target }
func (v Identity) SourceSHA256() string   { return v.sourceSHA256 }
func (v Identity) Capabilities() []string { return []string{RequiredCapability} }

func digits(value string) bool {
	if value == "" {
		return false
	}
	for i := range len(value) {
		if value[i] < '0' || value[i] > '9' {
			return false
		}
	}
	return true
}
func (v Identity) valid() bool {
	parts := bytes.Split([]byte(v.version), []byte("."))
	if len(parts) != 3 || len(v.version) > 32 || !digits(v.buildNumber) || len(v.buildNumber) > 20 || v.buildNumber[0] == '0' {
		return false
	}
	for _, part := range parts {
		if !digits(string(part)) {
			return false
		}
	}
	if v.target != WindowsX64 && v.target != LinuxX64 || len(v.sourceSHA256) != 64 {
		return false
	}
	for i := range len(v.sourceSHA256) {
		c := v.sourceSHA256[i]
		if !(c >= '0' && c <= '9' || c >= 'a' && c <= 'f') {
			return false
		}
	}
	return true
}

// Parse rejects duplicate (including escaped), unknown, missing and mistyped
// fields before any map decoder can discard their original representation.
func Parse(data []byte) (Identity, error) {
	fields, err := object(data, MaxIdentityBytes, []string{"schemaVersion", "productId", "version", "buildNumber", "target", "protocolVersion", "contractRevision", "sourceSha256", "capabilities"})
	if err != nil {
		return Identity{}, ErrInvalid
	}
	stringField := func(name string) (string, bool) { value, err := strictString(fields[name]); return value, err == nil }
	var schema, protocol uint32
	if json.Unmarshal(fields["schemaVersion"], &schema) != nil || schema != 1 || json.Unmarshal(fields["protocolVersion"], &protocol) != nil || protocol != ProtocolVersion {
		return Identity{}, ErrInvalid
	}
	product, ok := stringField("productId")
	if !ok || product != ProductID {
		return Identity{}, ErrInvalid
	}
	contract, ok := stringField("contractRevision")
	if !ok || contract != ContractRevision {
		return Identity{}, ErrInvalid
	}
	version, ok := stringField("version")
	if !ok {
		return Identity{}, ErrInvalid
	}
	build, ok := stringField("buildNumber")
	if !ok {
		return Identity{}, ErrInvalid
	}
	target, ok := stringField("target")
	if !ok {
		return Identity{}, ErrInvalid
	}
	source, ok := stringField("sourceSha256")
	if !ok {
		return Identity{}, ErrInvalid
	}
	var capabilities []json.RawMessage
	if json.Unmarshal(fields["capabilities"], &capabilities) != nil || len(capabilities) != 1 {
		return Identity{}, ErrInvalid
	}
	capability, err := strictString(capabilities[0])
	if err != nil || capability != RequiredCapability {
		return Identity{}, ErrInvalid
	}
	value := Identity{version, build, NativeTarget(target), source}
	if !value.valid() {
		return Identity{}, ErrInvalid
	}
	return value, nil
}

// CanonicalJSON matches package.py json_bytes: ASCII, sorted keys, compact,
// exactly one trailing LF. All accepted values use only unescaped ASCII.
func (v Identity) CanonicalJSON() ([]byte, error) {
	if !v.valid() {
		return nil, ErrInvalid
	}
	return []byte(`{"buildNumber":"` + v.buildNumber + `","capabilities":["capturedExportV1"],"contractRevision":"gpui-v3-captured-export-v1","productId":"app.dbeer.DBeer","protocolVersion":3,"schemaVersion":1,"sourceSha256":"` + v.sourceSHA256 + `","target":"` + string(v.target) + `","version":"` + v.version + `"}` + "\n"), nil
}
func (v Identity) MarshalJSON() ([]byte, error) {
	data, err := v.CanonicalJSON()
	if err != nil {
		return nil, err
	}
	return data[:len(data)-1], nil
}
func (v *Identity) UnmarshalJSON(data []byte) error {
	value, err := Parse(data)
	if err != nil {
		return err
	}
	*v = value
	return nil
}

// ValidateNative uses actual compiled Go runtime constants, never GOOS/GOARCH
// environment overrides. Packaging separately verifies native GUI ABI/glibc.
func (v Identity) ValidateNative(compiledVersion, compiledBuild string) error {
	if !v.valid() || v.version != compiledVersion || v.buildNumber != compiledBuild || runtime.GOARCH != "amd64" {
		return ErrInvalid
	}
	if runtime.GOOS == "windows" && v.target == WindowsX64 || runtime.GOOS == "linux" && v.target == LinuxX64 {
		return nil
	}
	return ErrInvalid
}

// OptionalCompiled preserves ordinary unmarked Mac/helper development builds.
// Nonempty raw metadata must match the actual native product and compiled values.
func OptionalCompiled(raw, compiledVersion, compiledBuild string) (*Identity, error) {
	if raw == "" {
		return nil, nil
	}
	value, err := Parse([]byte(raw))
	if err != nil {
		return nil, err
	}
	if err := value.ValidateNative(compiledVersion, compiledBuild); err != nil {
		return nil, err
	}
	return &value, nil
}

// RequireMatching is suitable for a product's common handshake, before work.
func (v Identity) RequireMatching(remote *Identity, protocol uint32, capabilities []string) error {
	if !v.valid() || remote == nil || !remote.valid() || v != *remote || protocol != ProtocolVersion {
		return ErrInvalid
	}
	for _, value := range capabilities {
		if value == RequiredCapability {
			return nil
		}
	}
	return ErrInvalid
}

// Info is the bounded --build-info JSON envelope. It contains no runtime state.
type Info struct {
	component string
	identity  Identity
}

func (v Info) Component() string  { return v.component }
func (v Info) Identity() Identity { return v.identity }
func ParseInfo(data []byte) (Info, error) {
	fields, err := object(data, MaxInfoBytes, []string{"component", "identity"})
	if err != nil {
		return Info{}, ErrInvalid
	}
	component, err := strictString(fields["component"])
	if err != nil || component != "gui" && component != "helper" {
		return Info{}, ErrInvalid
	}
	identity, err := Parse(fields["identity"])
	if err != nil {
		return Info{}, err
	}
	return Info{component, identity}, nil
}
func (v Info) MarshalJSON() ([]byte, error) {
	if v.component != "gui" && v.component != "helper" {
		return nil, ErrInvalid
	}
	identity, err := v.identity.MarshalJSON()
	if err != nil {
		return nil, err
	}
	return append(append([]byte(`{"component":"`+v.component+`","identity":`), identity...), '}'), nil
}
func (v *Info) UnmarshalJSON(data []byte) error {
	value, err := ParseInfo(data)
	if err != nil {
		return err
	}
	*v = value
	return nil
}

// HelperJSON requires explicit build-time values; main must dispatch it before
// flag registration, stdin, transport, LSP, profiles, credentials or DB setup.
func HelperJSON(raw, compiledVersion, compiledBuild string) ([]byte, error) {
	identity, err := OptionalCompiled(raw, compiledVersion, compiledBuild)
	if err != nil || identity == nil {
		return nil, ErrInvalid
	}
	data, err := (Info{"helper", *identity}).MarshalJSON()
	if err != nil {
		return nil, err
	}
	return append(data, '\n'), nil
}

// OptionalFromHelloAck inspects original frame bytes, retaining duplicate keys.
// Absent/null identity remains compatible with ordinary unmarked Mac helpers.
// The caller supplies its existing transport frame limit before decoding.
func OptionalFromHelloAck(data []byte, maximumFrameBytes int) (*Identity, error) {
	fields, err := object(data, maximumFrameBytes, nil)
	if err != nil {
		return nil, err
	}
	kind, err := strictString(fields["type"])
	if err != nil || kind != "hello.ack" {
		return nil, ErrInvalid
	}
	raw, present := fields["buildIdentity"]
	if !present || bytes.Equal(bytes.TrimSpace(raw), []byte("null")) {
		return nil, nil
	}
	identity, err := Parse(raw)
	if err != nil {
		return nil, err
	}
	return &identity, nil
}

func object(data []byte, limit int, allowed []string) (map[string]json.RawMessage, error) {
	if limit < 0 || len(data) > limit || !utf8.Valid(data) {
		return nil, ErrInvalid
	}
	decoder := json.NewDecoder(bytes.NewReader(data))
	token, err := decoder.Token()
	if err != nil || token != json.Delim('{') {
		return nil, ErrInvalid
	}
	fields := make(map[string]json.RawMessage, len(allowed))
	for decoder.More() {
		token, err := decoder.Token()
		key, stringKey := token.(string)
		if err != nil || !stringKey {
			return nil, ErrInvalid
		}
		// Every allowed key is ASCII. Invalid surrogate replacement therefore
		// cannot alias an allowed key; escaped ASCII duplicates are retained.
		permitted := allowed == nil
		for _, name := range allowed {
			if key == name {
				permitted = true
				break
			}
		}
		if !permitted {
			return nil, ErrInvalid
		}
		if _, exists := fields[key]; exists {
			return nil, ErrInvalid
		}
		var value json.RawMessage
		if decoder.Decode(&value) != nil {
			return nil, ErrInvalid
		}
		fields[key] = value
	}
	token, err = decoder.Token()
	if err != nil || token != json.Delim('}') || allowed != nil && len(fields) != len(allowed) {
		return nil, ErrInvalid
	}
	if err := decoder.Decode(new(any)); err != io.EOF {
		return nil, ErrInvalid
	}
	return fields, nil
}

// encoding/json permits lone escaped UTF-16 surrogates; serde does not.
func strictString(raw []byte) (string, error) {
	raw = bytes.TrimSpace(raw)
	if len(raw) < 2 || raw[0] != '"' || raw[len(raw)-1] != '"' || !utf8.Valid(raw) {
		return "", ErrInvalid
	}
	for i := 1; i < len(raw)-1; i++ {
		if raw[i] != '\\' {
			continue
		}
		i++
		if i >= len(raw)-1 {
			return "", ErrInvalid
		}
		if raw[i] != 'u' {
			continue
		}
		if i+4 >= len(raw)-1 {
			return "", ErrInvalid
		}
		code, err := strconv.ParseUint(string(raw[i+1:i+5]), 16, 16)
		if err != nil {
			return "", ErrInvalid
		}
		i += 4
		if code >= 0xdc00 && code <= 0xdfff {
			return "", ErrInvalid
		}
		if code >= 0xd800 && code <= 0xdbff {
			if i+6 >= len(raw)-1 || raw[i+1] != '\\' || raw[i+2] != 'u' {
				return "", ErrInvalid
			}
			low, err := strconv.ParseUint(string(raw[i+3:i+7]), 16, 16)
			if err != nil || low < 0xdc00 || low > 0xdfff {
				return "", ErrInvalid
			}
			i += 6
		}
	}
	var value string
	if json.Unmarshal(raw, &value) != nil {
		return "", ErrInvalid
	}
	return value, nil
}
