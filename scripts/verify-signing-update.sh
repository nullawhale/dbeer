#!/usr/bin/env bash
# Verify a real signed-code update against an isolated Keychain, without profiles.
set -euo pipefail

repo_root="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)"
if [[ "$(uname -s)" != Darwin || "$#" != 0 ]]; then
    printf 'Usage on macOS: %s\n' "$0" >&2
    exit 2
fi
if [[ "${DBEER_SIGNING_UPDATE_ISOLATED:-0}" != 1 ]]; then
    exec "$repo_root/scripts/with-test-keychain.sh" env DBEER_SIGNING_UPDATE_ISOLATED=1 "$0"
fi
if [[ "${DBEER_TEST_KEYCHAIN:-0}" != 1 || -z "${DBEER_TEST_KEYCHAIN_PATH:-}" ]]; then
    printf 'The update verification requires its isolated test Keychain.\n' >&2
    exit 1
fi

signing_keychain="${DBEER_SIGNING_KEYCHAIN:-$HOME/Library/Keychains/login.keychain-db}"
signing_identity="${DBEER_SIGNING_IDENTITY:-}"
if [[ -z "$signing_identity" ]]; then
    signing_identity="$(security find-identity -v -p codesigning "$signing_keychain" |
        awk '/"Apple Development:/ { print $2 }')"
    identity_count="$(printf '%s\n' "$signing_identity" | awk 'NF { count++ } END { print count+0 }')"
    if [[ "$identity_count" != 1 ]]; then
        printf 'Expected one valid Apple Development identity; set DBEER_SIGNING_IDENTITY explicitly.\n' >&2
        exit 1
    fi
fi
if [[ -z "$signing_identity" || "$signing_identity" == '-' ]]; then
    printf 'An actual signing identity is required; ad hoc signatures cannot prove update compatibility.\n' >&2
    exit 1
fi
if [[ "${DBEER_CI_SIGNING:-0}" == 1 && ( "${CI:-}" != true || "${GITHUB_ACTIONS:-}" != true ) ]]; then
    printf 'Temporary CI signing is only allowed in GitHub Actions.\n' >&2
    exit 1
fi

umask 077
fixture_root="$(mktemp -d "${TMPDIR:-/tmp}/dbeer-signing-update.XXXXXX")"
cleanup() { rm -rf -- "$fixture_root"; }
trap cleanup EXIT
trap 'exit 130' INT
trap 'exit 143' TERM
mkdir -p "$repo_root/build/.cache/signing-update-clang"
export CLANG_MODULE_CACHE_PATH="$repo_root/build/.cache/signing-update-clang"
export DBEER_SIGNING_UPDATE_EXPECTED="$fixture_root/expected"

cat > "$fixture_root/Probe.swift" <<'SWIFT'
import Foundation
import Security

#if PROBE_VERSION_TWO
let buildVersion = "2"
#else
let buildVersion = "1"
#endif

func fail(_ operation: String, _ status: OSStatus? = nil) -> Never {
    let suffix = status.map { " (OSStatus \($0))" } ?? ""
    FileHandle.standardError.write(Data("Signing update probe failed: \(operation)\(suffix).\n".utf8))
    exit(1)
}

func check(_ status: OSStatus, _ operation: String) {
    if status != errSecSuccess { fail(operation, status) }
}

func randomSecret() -> Data {
    var bytes = [UInt8](repeating: 0, count: 32)
    check(SecRandomCopyBytes(kSecRandomDefault, bytes.count, &bytes), "generate isolated fixture")
    return Data(bytes)
}

let environment = ProcessInfo.processInfo.environment
guard let keychainPath = environment["DBEER_TEST_KEYCHAIN_PATH"],
      let expectedPath = environment["DBEER_SIGNING_UPDATE_EXPECTED"],
      CommandLine.arguments.count == 2,
      Bundle.main.object(forInfoDictionaryKey: "CFBundleVersion") as? String == buildVersion else {
    fail("validate isolated probe configuration")
}
// An incompatible ACL fails immediately instead of requesting user approval.
check(SecKeychainSetUserInteractionAllowed(false), "disable interactive Keychain prompts")
var openedKeychain: SecKeychain?
check(SecKeychainOpen(keychainPath, &openedKeychain), "open isolated Keychain")
guard let keychain = openedKeychain else { fail("open isolated Keychain") }
let query: [String: Any] = [
    kSecClass as String: kSecClassGenericPassword,
    kSecAttrService as String: "dev.dbeer.signing-update-probe",
    kSecAttrAccount as String: "isolated-update-fixture",
    kSecMatchSearchList as String: [keychain]
]
let expectedURL = URL(fileURLWithPath: expectedPath)

func expectedSecret() -> Data {
    do { return try Data(contentsOf: expectedURL) }
    catch { fail("read protected fixture expectation") }
}

func remember(_ data: Data) {
    do {
        try data.write(to: expectedURL, options: .atomic)
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: expectedPath)
    } catch { fail("write protected fixture expectation") }
}

@MainActor func readSecret() -> Data {
    var search = query
    search[kSecReturnData as String] = true
    search[kSecMatchLimit as String] = kSecMatchLimitOne
    var item: CFTypeRef?
    check(SecItemCopyMatching(search as CFDictionary, &item), "read previous signed build's credential")
    guard let data = item as? Data else { fail("decode isolated credential") }
    return data
}

switch CommandLine.arguments[1] {
case "create":
    guard buildVersion == "1" else { fail("create from original build") }
    let secret = randomSecret()
    var attributes = query
    attributes.removeValue(forKey: kSecMatchSearchList as String)
    attributes[kSecUseKeychain as String] = keychain
    attributes[kSecValueData as String] = secret
    check(SecItemAdd(attributes as CFDictionary, nil), "create credential from signed build 1")
    remember(secret)
    guard readSecret() == secret else { fail("verify original credential") }
case "update-and-delete":
    guard buildVersion == "2", readSecret() == expectedSecret() else {
        fail("read original credential after signed update")
    }
    let replacement = randomSecret()
    check(SecItemUpdate(query as CFDictionary, [kSecValueData as String: replacement] as CFDictionary),
          "update original credential from signed build 2")
    remember(replacement)
    guard readSecret() == replacement else { fail("verify credential update") }
    check(SecItemDelete(query as CFDictionary), "delete credential from signed build 2")
    guard SecItemCopyMatching(query as CFDictionary, nil) == errSecItemNotFound else {
        fail("verify isolated credential deletion")
    }
default: fail("validate probe action")
}
print("Signed probe build \(buildVersion): PASS")
SWIFT

for version in 1 2; do
    app="$fixture_root/build-$version/UpdateProbe.app"
    mkdir -p "$app/Contents/MacOS"
    cat > "$app/Contents/Info.plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><dict>
<key>CFBundleIdentifier</key><string>dev.dbeer.signing-update-probe</string>
<key>CFBundleExecutable</key><string>UpdateProbe</string>
<key>CFBundlePackageType</key><string>APPL</string>
<key>CFBundleVersion</key><string>$version</string>
</dict></plist>
PLIST
    swift_version_flag=-DPROBE_VERSION_ONE
    if [[ "$version" == 2 ]]; then swift_version_flag=-DPROBE_VERSION_TWO; fi
    xcrun swiftc -swift-version 6 -O -module-cache-path "$CLANG_MODULE_CACHE_PATH" \
        "$swift_version_flag" "$fixture_root/Probe.swift" -framework Security \
        -o "$app/Contents/MacOS/UpdateProbe"
    codesign --force --timestamp=none --keychain "$signing_keychain" --sign "$signing_identity" "$app"
    codesign --verify --strict "$app"
    codesign --display --requirements - "$app" 2>&1 |
        sed -n '/^designated => /p' > "$fixture_root/requirement-$version"
    codesign --display --verbose=4 "$app" 2>&1 |
        sed -n 's/^CDHash=//p' > "$fixture_root/hash-$version"
done
if [[ ! -s "$fixture_root/requirement-1" || ! -s "$fixture_root/hash-1" || ! -s "$fixture_root/hash-2" ]] ||
    ! cmp -s "$fixture_root/requirement-1" "$fixture_root/requirement-2" ||
    cmp -s "$fixture_root/hash-1" "$fixture_root/hash-2"; then
    printf 'The two builds must have equal designated requirements and different code hashes.\n' >&2
    exit 1
fi

# Replace the executable at the same isolated installation path, as an update does.
installed_app="$fixture_root/installed/UpdateProbe.app"
mkdir -p "$(dirname -- "$installed_app")"
ditto "$fixture_root/build-1/UpdateProbe.app" "$installed_app"
"$installed_app/Contents/MacOS/UpdateProbe" create
rm -rf -- "$installed_app"
ditto "$fixture_root/build-2/UpdateProbe.app" "$installed_app"
"$installed_app/Contents/MacOS/UpdateProbe" update-and-delete
printf 'PASS: changed signed build reads, updates and deletes the previous build\047s isolated credential without prompting.\n'
printf 'This verifies same-Mac signature/ACL compatibility; actual application installation on a second Mac remains a separate check.\n'
