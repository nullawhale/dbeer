# Installing an internal DBeer build

DBeer requires macOS 14+ on Apple Silicon. Running a packaged application does not require Go, Swift, or the source code.

1. Obtain the ZIP archive and its `.sha256` file from the project owner. In Terminal, change to the download directory and run `shasum -a 256 -c DBeer-<version>-<build>-macos-arm64.zip.sha256`, substituting the downloaded filename. The result must be `OK`.
2. Extract the ZIP and move `DBeer.app` to `Applications`. When updating, quit the running DBeer instance before replacing the application.
3. Open DBeer. If macOS blocks a trusted internal build, attempt to open it once, then go to **System Settings → Privacy & Security → Open Anyway** and confirm. Follow [Apple's official instructions](https://support.apple.com/en-us/102445). Do not disable application checks system-wide.
4. Open **Connections → Import Connections…**, review the profiles, and select a local CA if needed; alternatively, create a profile with **⌘N**. PostgreSQL 16/17/18 and MySQL 8.0/8.4 are supported. Enter your password in the profile editor. Use `verify-full` and a trusted CA for certificate verification. The password is stored in the local Keychain and excluded from profile exports.
5. Connect the profile, create a SQL tab (**⌘T**), and execute `SELECT 1` (**⌘Return**). Double-click a table to open its data. Grid changes reach the database only after **Apply**.

Normal updates preserve profiles and passwords in the user directory and Keychain. Updates must come from the same owner with persistent application and helper signatures. A certificate change may cause macOS to request access to an existing password. Do not install temporarily signed CI builds over the working application.

Version 0.1.0 is an early internal build. On October 18, 2026, the owner waived the required second-Mac check; the agreed acceptance run of packaged archives from build 5 to build 6 on the current Mac completed with **PASS**. It covered two-profile import, `SELECT 1` on both database engines before and after updating, Cancel/Stop and Continue during a long query, UUID/draft/Keychain preservation, normal shutdown, and cleanup. This run does not verify Finder/Gatekeeper or installation on a clean second device. An Apple Development signature is not notarization; use only an archive obtained from the owner and verified with SHA256.

Developers can reproduce the separate UI acceptance run with `./scripts/test-install-update.sh` from the repository root. Its XCTest runner requires full Xcode, Docker, and both verified archives; the packaged DBeer application itself does not require these tools.
