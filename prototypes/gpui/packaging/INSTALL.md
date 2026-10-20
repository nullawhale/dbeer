# DBeer Windows/Linux development candidate

These packages are unsigned development candidates until Windows 11 x64 and
Ubuntu 24.04 x64 Wayland/X11 installed acceptance completes. A build, checksum
or successful extraction does not establish desktop parity. The macOS product
uses the separate SwiftUI/AppKit application and its existing Apple signing.

## Verify and extract

Obtain an archive, its adjacent `.sha256` file and `BUILD-IDENTITY.json` from the
same trusted source. Compare the entire published SHA256 through an independently
trusted channel. A checksum detects changes; it does not authenticate a publisher.
No script downloads, publishes, changes trust or installs automatically.

On Windows, use `Get-FileHash -Algorithm SHA256 -LiteralPath <archive.zip>` and
compare its hash to the adjacent file. Extract the complete ZIP into a new folder
owned by your user. Keep `dbeer-gpui.exe` and `dbeer-core.exe` together. Launch
`dbeer-gpui.exe` as a standard user. Read WINDOWS-SIGNING.md and RUNTIME.md first.
Do not remove security warnings or disable SmartScreen/Defender to run a candidate.

On Ubuntu, run `sha256sum -c <archive.tar.gz.sha256>` from the directory containing
both files. Inspect `tar -tzf <archive.tar.gz>` before extracting into a new folder
owned by your user. Keep `dbeer-gpui` and `dbeer-core` together and launch
`./dbeer-gpui` inside a graphical login. No root access is required. Do not extract
over another package or a directory containing unrelated files.

The `.candidate` output directory groups the archive, checksum and build identity
as one publication. The archive includes MANIFEST.json with per-file SHA256,
BUILD-IDENTITY.json, SOURCE-PROVENANCE.json, NATIVE-DEPENDENCIES.json, changelog, original icon assets,
all ten theme sources/four original notices/licenses and dependency notices.
Source provenance lists exact repository-relative input digests and sizes and
shares the helper's embedded source identity. It records trusted builder inputs;
checksums alone are not a compiler attestation or publisher signature.
`--build-info` on each executable must report matching `identity` values and its
own `component`. That mode must exit before graphics, data loading or helper
startup. Ordinary product startup also requires an exact helper identity match.

## Optional Ubuntu desktop integration

Ubuntu's Python 3.11+ is needed only for this optional operation. From inside the
extracted package run `python3 ./integrate-linux.py install`. It creates the user's
`applications/app.dbeer.DBeer.desktop`, `icons/hicolor/scalable/apps/app.dbeer.DBeer.svg`
and `dbeer-integration/app.dbeer.DBeer.json` under absolute XDG_DATA_HOME or
`~/.local/share`. The launcher refers to the package's absolute executable path;
keep the extracted package in place. Spaces, quotes, percent signs and Unicode
are escaped as Desktop Entry/Exec values. No arguments or SQL files are accepted
by the launcher. The desktop app ID must match the running GPUI window.

Use `python3 ./integrate-linux.py remove` before moving or updating that package.
Removal checks the exact owned manifest, device/inode identities and current file digests. A changed,
missing, symlinked or unrelated entry refuses cleanup and preserves remaining
files. Neither operation copies binaries, removes a package directory, deletes
parent directories, touches private application data or accesses credentials.
No root, system desktop registration or autostart entry is used. If integration
was installed with `--data-home <absolute-path>`, use the same path for removal.

## Manual update and removal

Close all GPUI instances through the normal close workflow before an update.
Resolve transactions, uncertain outcomes, staged edits, exports and unsaved files;
wait for settings and draft saves. Verify/extract a complete new package beside
the old package. Remove owned desktop integration, then install it from the new
folder if desired. Run the new executable. Keep the old archive and folder for
review/rollback; never replace only the helper or overwrite a previous archive.
There is no updater, MSI/MSIX, AppImage or unattended install.

The product deliberately retains the prototype data locations:

- Windows: `%LOCALAPPDATA%\DBeerGPUI` (local, not roaming).
- Ubuntu: absolute `$XDG_CONFIG_HOME/dbeer-gpui`, otherwise `~/.config/dbeer-gpui`.

Both executables use the original `.workspace.lock`. A second old/new instance
must refuse before reading/mutating the library. There is no PID-based stale-lock
removal, forced termination or filesystem-copy migration. GPUI prototypes from
before the ownership policy are unsupported for simultaneous use; close them.
Opaque saved profile IDs, selection, SQL document UUIDs/drafts/history, settings,
imported themes and shortcuts remain in the same files. Saved passwords remain
in the same native credential service `dev.dbeer.gpui-prototype`, under unchanged
profile-account IDs. This display identity change does not move passwords.

Fresh product startup has no built-in demo profiles or sample SQL. Saved IDs such
as `demo-brewery` are ordinary saved IDs. Restored documents stay disconnected;
startup/restore never connects, executes SQL or accesses credentials implicitly.
Explicit connection or execution uses the normal workflow.

Remove optional owned desktop integration, then delete only the extracted package
folder you created if you want to remove the application. Retain user data and OS
credentials unless you deliberately remove them through the application/platform
UI. There is no automatic downgrade conversion: an older executable may refuse
newer data formats. Corrupt/future-version files must remain unchanged. Do not
restore stale copies over current state or run old/new versions concurrently.

## Acceptance still required

Clean standard-user install, native dependencies, actual rendering/input/pickers,
clipboard interoperability, credentials, accessibility and previous-to-candidate
state retention require Windows 11 x64 and Ubuntu 24.04 x64 desktop evidence,
separately on Wayland and X11. No native acceptance is implied by this package.
