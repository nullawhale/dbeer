# GPUI shared build identity codec core

Task 31 remains OPEN. This additive core prepares codecs and shared cases only.
It does not wire hello.ack, main, GUI startup, native build flags, CI, packaging
execution or installed acceptance. Ordinary macOS remains SwiftUI/AppKit with
its existing Apple Development build/sign/release route. No tests were executed.

## Contract and exact bytes

The authoritative schema is the existing `src/product_identity.rs` BuildIdentity,
paired with `packaging/package.py`. There are exactly nine required fields:

- schemaVersion: integer 1.
- productId: string app.dbeer.DBeer.
- version: three nonempty ASCII digit components separated by periods, at most
  32 bytes; component leading zeroes remain accepted by the existing contract.
- buildNumber: nonzero ASCII decimal string, no leading zero, at most 20 bytes.
- target: windows-x86_64-msvc or linux-x86_64-gnu.
- protocolVersion: integer 3.
- contractRevision: gpui-v3-captured-export-v1.
- sourceSha256: exactly 64 lowercase ASCII hexadecimal characters.
- capabilities: exactly the one-element array [capturedExportV1].

Unknown, missing, duplicate (including escaped aliases), mistyped, future and
oversized identity JSON is refused. Original identity bytes are bounded to 4096
before normalization. Integer tokens containing decimal/exponent notation are
refused. Accepted strings normalize to ASCII because each field has constrained
ASCII semantics. Error messages do not include input metadata.

`package.py json_bytes` serializes ASCII, lexicographically sorted keys, no
insignificant spaces, plus exactly one terminal LF. The exact key order is:
buildNumber, capabilities, contractRevision, productId, protocolVersion,
schemaVersion, sourceSha256, target, version. The embedded executable marker is
those same compact bytes with the terminal LF omitted (`json_bytes(...).strip()`
in the existing packager). Rust's existing declaration-order `Serialize` output
is valid JSON but is NOT the canonical embedded marker. Go `CanonicalJSON` and
Swift `canonicalJSON` return the file form with LF. Go `MarshalJSON` returns the
embedded form without LF. Neither parser requires canonical input ordering.

BuildInfo is exactly {component, identity}, where component is gui or helper.
Its canonical order is component then identity; the identity remains sorted as
above. Go/Swift Info parsers cap the envelope at 4160 bytes and independently
bound the original nested identity to 4096. The existing packager allows an
8192-byte process report; our smaller bounded output fits that existing limit.

The source digest is NOT a GUI/helper executable checksum. Existing source_digest
sorts the packager's source-file set by repository-relative POSIX path. For each
file it feeds SHA256: eight-byte big-endian path byte length, UTF-8 path bytes,
eight-byte big-endian exact content length, then exact content bytes. Its current
source roots include GPUI src/vendor/assets/packaging, helper and protocol plus
specified version/build/changelog/icon/Cargo lock/native script files. Builds,
.git, ignored docs and caches are excluded. Do not reimplement or replace that
file list here. Generate metadata after all source edits, including these files,
and before both product builds. Executable checksums are computed separately by
the existing packaging manifest after the binaries are built.

## Go API and explicit authority

New stdlib-only package: `helper/internal/productidentity/identity.go`.
Tests: `helper/internal/productidentity/identity_test.go`.

- `Parse([]byte) (Identity, error)` validates original raw identity bytes.
- `Identity.CanonicalJSON`, `MarshalJSON`, `UnmarshalJSON` preserve the schema;
  fields are private, getters return values, and Capabilities returns a copy.
- `NormalizeNativeTarget(os, architecture, abi)` is a pure label normalizer;
  Rust x86_64 and Go amd64 map to the same two targets. ARM, Mac, Linux musl and
  Windows GNU labels refuse. This function is not runtime proof.
- `Identity.ValidateNative(compiledVersion, compiledBuild)` compares exact
  explicit build-time release values with the identity and actual runtime.GOOS /
  runtime.GOARCH. Only windows/amd64 and linux/amd64 product pairs pass. It reads
  no environment override. Packaging separately verifies native GUI ABI/glibc;
  Go's runtime labels do not establish the Rust MSVC/glibc baseline.
- `OptionalCompiled(raw, compiledVersion, compiledBuild)` returns nil for exactly
  empty unmarked metadata, preserving ordinary development/Mac helpers. Every
  nonempty identity must pass native validation before it can be attached.
- `HelperJSON(raw, compiledVersion, compiledBuild)` refuses absent identity and
  emits only the helper BuildInfo JSON followed by LF. Main must supply compiled
  values, never mutable process environment. No global flag registration exists.
- `ParseInfo` and immutable Info getters decode reports without runtime effects.
- `OptionalFromHelloAck(originalFrame, existingMaximumFrameBytes)` rejects
  duplicate top-level keys and validates original optional nested bytes. Absent
  or null identity returns nil; this does not make product pairing optional.
- `Identity.RequireMatching(remote, protocol, capabilities)` requires an exact
  identity, protocol 3 and the existing capturedExportV1 capability before work.

The package has no main/protocol/session/adapter dependency and performs no stdin,
helper launch, environment read, profile, DB or credential setup.

## Swift API and raw hello integration

New Foundation-only Swift 6 Sendable/Codable type:
`macos/Sources/DBeer/GPUIProductBuildIdentity.swift`.
Tests: `macos/Tests/DBeerTests/GPUIProductBuildIdentityTests.swift`.

`parse(Data)`, `canonicalJSON()`, `Info.parse`, `Info.canonicalJSON`,
`NativeTarget.normalized` and `requireMatchingHelper` provide equivalent pure
metadata behavior. Properties are immutable. No AppKit/native runtime claim,
helper launch or normal SwiftUI behavior change is introduced.

Foundation Decoder discards duplicate keys before init(from:) runs and also
accepts integer-shaped floats. Therefore Codable alone is NOT a raw-validation
boundary. `parse` uses a private original-byte preflight before JSONDecoder.
`optionalFromHelloAck(frame, maximumFrameBytes:)` is prepared specifically for the
original hello.ack bytes: byte/depth bounds, structural validity, duplicate keys,
then original nested identity validation. It accepts absent/null metadata.

The later Protocol.swift raw receive integration must call that method on the
original `frame` before `JSONDecoder().decode(BackendMessage.self, from: frame)`
(the current decode is NDJSONFramer.decode in Protocol.swift).
Call only for the hello.ack branch or retain the raw bytes until its type is
known; the API intentionally refuses other message types. Never decode to
[String: Any], reserialize and then preflight: duplicate evidence is already
lost. An additive BackendMessage `buildIdentity: GPUIProductBuildIdentity?`
can hold the validated value. Its regular Codable decode does not replace raw
preflight. Ordinary unmarked Mac helpers remain accepted; SwiftUI must not call
requireMatchingHelper to impose a Windows/Linux product requirement.

## Shared fixtures and undeclared Rust consumer

`protocol/fixtures/gpui-build-identity-v1/cases.json` indexes valid Windows/Linux,
reordered, exact-boundary and numeric-string cases plus duplicate, escaped key,
unknown/missing, invalid UTF-8/surrogate, oversize, integer-token, version/build,
capability, target, source, BuildInfo, optional hello and native-normalization
cases. Its README explains intentionally malformed files and synthetic values.
No frozen baseline or previous fixture was rewritten.

`src/product_identity/contract_fixtures.rs` is new and intentionally undeclared.
The later sole writer adds inside product_identity.rs:

```rust
#[cfg(test)]
#[path = "product_identity/contract_fixtures.rs"]
mod contract_fixtures;
```

It reuses BuildIdentity::parse/validate, BuildInfo and NativeTarget::from_native.
Its canonical fixture comparison sorts every object independently of Cargo's
serde_json preserve_order feature unification. The local hello test type checks
existing serde duplicate/type/field semantics and calls identity.validate.
The future production Rust raw decode must also bound the original nested
identity; serde alone cannot establish that raw bound. The existing BuildInfo
has no strict raw parser; the consumer validates its nested semantic value and
bounded prepared cases, not a new production BuildInfo API.

## Remaining full Task 31 integration obligations

1. Add explicit compiled identity/version/build variables to helper main (Go -X
   targets owned by main). Trim root file newlines while preparing exact flags;
   do not hardcode fixture release values or read process env as authority. Call
   OptionalCompiled once before normal helper work. Invalid nonempty metadata
   fails with a fixed structural diagnostic. Ordinary unmarked Mac helpers stay
   compatible; marked foreign products refuse.
2. Dispatch exact --build-info in both entry points before ordinary flags, stdin,
   PostgreSQL PrepareEnvironment, transport/LSP, any helper launch, GPUI/platform
   initialization, data ownership/profile restore, credential or DB setup. Unknown
   or mixed build-info arguments must fail before startup. Print only BuildInfo
   JSON on success or a fixed diagnostic; never fall through into a GUI/session.
   GUI uses existing BuildInfo::gui_json, which refuses debug/native-smoke builds;
   helper uses this HelperJSON API with compiled authority. Retain the canonical
   no-LF marker unchanged in both executables for the packager's byte check.
3. Add optional hello.ack buildIdentity to existing Go protocol.Response, Swift
   BackendMessage and Rust backend message/hello DTO. Validate original nested
   bytes and preserve 4 KiB semantics before generic duplicate-losing decoders.
   A nil Go pointer uses omitempty so ordinary helper output stays compatible.
   Do not require identity from ordinary SwiftUI/Mac handshakes.
4. For Windows/Linux product GUI, capture validated embedded BuildIdentity at
   startup and require exact matching helper identity, wire protocol 3 and
   capturedExportV1 in COMMON BackendClient handshake before connect, catalog,
   assessment, SQL, changes, exports or any other work. Existing full-export
   capability gates stay intact. Wire version alone does not prove semantics.
   Wrong/missing build/version/source/target/revision/capability fails before
   helper work; no recovery path silently downgrades to a development contract.
5. Wire native startup identity/title/icons/app ID and StartupPolicy. Product
   startup has no built-in fixtures/sample SQL, restores disconnected and supports
   a real unbound empty document with zero profiles; retain explicit disposable
   Mac demo/native-smoke flows. Preserve legacy data/credential namespace and
   canonical DataDirectory ownership through old/new simultaneous launches.
6. Generate the existing packager's identity only after shared source freeze,
   then use exactly that canonical compact marker for both Rust compile-time
   DBEER_PRODUCT_BUILD_IDENTITY and explicit Go link values. Native build scripts
   must not subsequently replace the helper with an unmarked build. Refuse target
   overrides/cross builds, ARM/musl/Windows GNU/Mac products as existing package
   rules require. Preserve the ordinary Mac helper/Swift signing path.
7. Wire supported Windows/Linux CI/native scripts to exact marked paired builds,
   complete original notices and the existing package wrappers. Existing unsigned
   development archives are not newly accepted product candidates. Prepare only
   fresh nonoverwriting local artifacts; no signing/trust change or publication.
8. Declare this Rust fixture consumer, extend early-main/common-handshake failure
   integration cases, and execute the prepared suites only after all remaining
   Task 32 code. Then run exact target-native package/build-info, complete-folder
   update/rollback/old-new-owner acceptance on owned Windows 11 x64 and Ubuntu
   24.04 x64 Wayland/X11. Capture completed summaries and explicit skips. None of
   the 171 native cells, Task 2 or Tasks 31/32 closes from codec compilation.

## Verification status

Go `go test -c` compiled only this new package and its test target successfully;
no binary was executed. Rustfmt parses/formats the new undeclared consumer; it
has not been typechecked as part of the crate and no Rust tests were run.
Swift build --build-tests completed successfully (42.26 seconds) with isolated
ignored scratch/cache/module directories; it compiled the native app/test targets
without running the native test host. Existing accessibility deprecation/linker
search-path and user-cache warnings remain. Initial manifest compilation used an
unwritable default Clang module cache; the supported explicit cache paths resolved
that environment failure. The final incremental compile, including the reviewed
nonzero Data slice-offset case, also completed successfully in 34.67 seconds.
Go reports go1.27.1 darwin/arm64. No completed test-run summary exists because no
test binary or test host was executed. All outputs are under ignored
`build/gpui/task31-contract/`. Runtime/native/DB/credential/UI acceptance and
normal helper/hello/GUI integration remain pending.
