# Installing DBeer

DBeer requires macOS 14+ on Apple Silicon. Running a packaged application does not require Go, Swift, or the source code.

The current release is **0.2.1, build 11**, for the native macOS client and bundled
Go helper. It supports PostgreSQL 16/17/18, MySQL 8.0/8.4, Apache Cassandra 4.1/5.0
and MongoDB 8.0. It includes local MCP access for all four engines and expanded
Cassandra CQL language assistance. Earlier
prerelease archives remain unchanged. Homebrew installation is not available.

1. Obtain the ZIP archive and its `.sha256` file from [the 0.2.1 release](https://github.com/nullawhale/dbeer/releases/tag/v0.2.1) or directly from the project owner. In Terminal, change to the download directory and run `shasum -a 256 -c DBeer-<version>-<build>-macos-arm64.zip.sha256`, substituting the downloaded filename. The result must be `OK`.
2. Extract the ZIP and move `DBeer.app` to `Applications`. When updating, quit the running DBeer instance before replacing the application.
3. Open DBeer. If macOS blocks a trusted internal build, attempt to open it once, then go to **System Settings → Privacy & Security → Open Anyway** and confirm. Follow [Apple's official instructions](https://support.apple.com/en-us/102445). Do not disable application checks system-wide.
4. Open **Connections → Import Connections…**, review the profiles, and select a local CA if needed; alternatively, create a profile with **⌘N**. PostgreSQL 16/17/18, MySQL 8.0/8.4, Cassandra 4.1/5.0 and MongoDB 8.0 are supported. Enter your password in the profile editor. Use `verify-full` and a trusted CA for certificate verification. The password is stored in the local Keychain and excluded from profile exports.
5. For PostgreSQL/MySQL, connect the profile, create a SQL tab (**⌘T**), and execute `SELECT 1` (**⌘Return**). Double-click a table to open its data. Grid changes reach the database only after **Apply**. MongoDB uses JSON find/aggregation requests; see [the MongoDB guide](README.md#mongodb).

Normal updates preserve profiles and passwords in the user directory and Keychain. Updates must come from the same owner with persistent application and helper signatures. A certificate change may cause macOS to request access to an existing password. Do not install temporarily signed CI builds over the working application.

Version 0.1.0 is an early internal build. On October 18, 2026, the owner waived the required second-Mac check; the agreed acceptance run of packaged archives from build 5 to build 6 on the current Mac completed with **PASS**. It covered two-profile import, `SELECT 1` on both database engines before and after updating, Cancel/Stop and Continue during a long query, UUID/draft/Keychain preservation, normal shutdown, and cleanup. This run does not verify Finder/Gatekeeper or installation on a clean second device. An Apple Development signature is not notarization; use only an archive obtained from the owner and verified with SHA256.

Developers can reproduce the separate UI acceptance run with `./scripts/test-install-update.sh` from the repository root. Its XCTest runner requires full Xcode, Docker, and both verified archives; the packaged DBeer application itself does not require these tools.

For an archive-to-current-app check, pass `--baseline-archive` and
`--candidate-app` to that runner. Supported baselines are 0.1.0/build 6 and
0.2.0/build 8. The runner installs private copies, checks the old archive checksum
and both signatures, and tests migration and existing Keychain access without
passing passwords to the candidate app. Matching build numbers do not replace
content/signature verification. This mode creates no release ZIP and does not
change the owner's installed app or existing archives. Details and commands are
in [the acceptance guide](macos/AcceptanceTests/README.md).

DBeer 0.2.1/build 11 uses profile format v5, portable profile format v3, workspace
format v10 and native app/helper protocol v5. Install the complete application;
mixing it with an older helper fails the handshake. Migration preserves profile
UUIDs and access to the same database Keychain entries, writes exact private
backups before replacing older storage, and refuses unknown versions or corrupt
files. Profiles without SSH settings migrate with SSH disabled; existing SSH
settings are preserved. SSH passwords and key passphrases have separate Keychain entries. Profile imports exclude secrets and
SSH trust, and key authentication requires local key-file selection. Portable
profiles also exclude local password commands. Restored SQL tabs, table views and
investigation blocks remain disconnected until an explicit user action.

The working source for 0.3.0 advances workspace storage to v11 for grouped table
filters. Upgrading v10 creates an exact private `.v10.backup` before migration.
Named table views use a separate private local library and are excluded from
connection transfer. Applied settings restore disconnected; unapplied browsing
drafts are not persisted. These changes are not in the 0.2.1/build 11 archive;
install the matching app and helper together when a new release is available.

For Codex/MCP, keep DBeer running and use
`/Applications/DBeer.app/Contents/Helpers/dbeer-core` with argument `--mcp`
(adjust the application location if needed). The first tool call requests
profile-specific session permission in DBeer; reading is the default and writes
require separate approval. **Settings → Agents** lists active clients, supports
revocation and shows the bounded session activity journal. Password-command
profiles are unavailable to agents. See [Codex setup and MCP limits](README.md#local-mcp-agent-access).

Readonly rejects writes and unknown SQL/CQL in the helper. PostgreSQL/MySQL also
enable server-side read-only mode; Cassandra and MongoDB use local assessment.
Enforce strict write restrictions with database user permissions: read-only mode
does not replace server restrictions and has exceptions for temporary tables.
Changing environment or readonly in the profile editor requires the normal
session shutdown workflow; active transactions are never silently completed.

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
