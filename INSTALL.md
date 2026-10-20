# Installing an internal DBeer build

DBeer requires macOS 14+ on Apple Silicon. Running a packaged application does not require Go, Swift, or the source code.

The current local prerelease is **0.2.0, build 7**, for the native macOS client
and bundled Go helper. It includes PostgreSQL, MySQL and Apache Cassandra support.
The numeric application version is 0.2.0; this archive remains a prerelease.
Installed-archive update acceptance for this version is pending. The earlier
0.1.0 acceptance results below apply only to those older archives.
Automated native editor completion and signature-help checks have unresolved
intermittent failures; the full native UI suite has not passed for this prerelease.

1. Obtain the ZIP archive and its `.sha256` file from the project owner. In Terminal, change to the download directory and run `shasum -a 256 -c DBeer-<version>-<build>-macos-arm64.zip.sha256`, substituting the downloaded filename. The result must be `OK`.
2. Extract the ZIP and move `DBeer.app` to `Applications`. When updating, quit the running DBeer instance before replacing the application.
3. Open DBeer. If macOS blocks a trusted internal build, attempt to open it once, then go to **System Settings → Privacy & Security → Open Anyway** and confirm. Follow [Apple's official instructions](https://support.apple.com/en-us/102445). Do not disable application checks system-wide.
4. Open **Connections → Import Connections…**, review the profiles, and select a local CA if needed; alternatively, create a profile with **⌘N**. PostgreSQL 16/17/18, MySQL 8.0/8.4 and Cassandra 4.1/5.0 are supported. Enter your password in the profile editor. Use `verify-full` and a trusted CA for certificate verification. The password is stored in the local Keychain and excluded from profile exports.
5. Connect the profile, create a SQL tab (**⌘T**), and execute `SELECT 1` (**⌘Return**). Double-click a table to open its data. Grid changes reach the database only after **Apply**.

Normal updates preserve profiles and passwords in the user directory and Keychain. Updates must come from the same owner with persistent application and helper signatures. A certificate change may cause macOS to request access to an existing password. Do not install temporarily signed CI builds over the working application.

Version 0.1.0 is an early internal build. On October 18, 2026, the owner waived the required second-Mac check; the agreed acceptance run of packaged archives from build 5 to build 6 on the current Mac completed with **PASS**. It covered two-profile import, `SELECT 1` on both database engines before and after updating, Cancel/Stop and Continue during a long query, UUID/draft/Keychain preservation, normal shutdown, and cleanup. This run does not verify Finder/Gatekeeper or installation on a clean second device. An Apple Development signature is not notarization; use only an archive obtained from the owner and verified with SHA256.

Developers can reproduce the separate UI acceptance run with `./scripts/test-install-update.sh` from the repository root. Its XCTest runner requires full Xcode, Docker, and both verified archives; the packaged DBeer application itself does not require these tools.

The 0.2.0 prerelease migrates profiles to format v3 with environment and readonly settings. The first load of v1/v2 creates `connections.json.v1.backup` or `connections.json.v2.backup` containing the original bytes, preserves UUIDs and access to the same Keychain entries, and replaces the file atomically. Unknown versions and corrupt files are not overwritten. Profile export v2 includes environment and readonly, while legacy v1 imports remain compatible. The application and bundled helper must both use protocol v4; incompatible helpers are rejected during the handshake. These changes do not rename or replace existing 0.1.0 archives.

Readonly in the 0.2.0 prerelease rejects writes and unknown SQL/CQL in the helper. PostgreSQL/MySQL also enable server-side read-only mode; Cassandra uses local assessment. Enforce strict write restrictions with database user permissions: read-only mode does not replace server restrictions and has exceptions for temporary tables. Changing environment or readonly in the profile editor requires the normal session shutdown workflow; active transactions are never silently completed.

Production confirmation uses a structural assessment of the operation. Views, overloaded built-in functions, custom casts, and operators can hide writes. The client does not promise to detect every such effect; restrict write access, temporary tables, and dangerous function execution in the database.

## Windows/Linux development candidates

The GPUI frontend targets Windows 11 x64 and Ubuntu 24.04 x64 Wayland/X11.
Native desktop/install/update acceptance remains pending; these are unsigned
development candidates, separate from the macOS SwiftUI/AppKit release above.
Use the [GPUI install/update/remove guide](prototypes/gpui/packaging/INSTALL.md)
and [runtime prerequisites](prototypes/gpui/packaging/RUNTIME.md). Verify the
exact archive checksum and extract a complete new folder; retain the matching
dbeer-gpui[.exe] and dbeer-core[.exe] pair. Updates are manual complete-folder
updates. Original GPUI user data and OS credentials stay in place. No automatic
publication, trust change, signing or existing archive replacement is performed.
