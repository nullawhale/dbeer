# Portable profile transfer

The experimental GPUI client implements the existing Swift v2/legacy-v1
[portable format](../../protocol/PROFILE_TRANSFER.md). It targets Windows 11 x64
and Ubuntu 24.04 x64; the Mac GPUI window is development only. The Mac product
remains SwiftUI/AppKit. Swift's narrow shared-format change accepts Windows CA
hints without probing them or weakening TLS; Mac import still requires explicit
local remapping for those hints.

Use **Import...** below Connections to choose a JSON file. The preview shows
name, engine, user/endpoint, database, TLS, environment/readonly and any CA hint.
Select individual rows, Select All/None, replace missing/foreign CAs with the
native chooser, then Import Selected. Cancel discards review. Each imported row
gets a fresh saved ID, stays disconnected and has no stored password. Import
never connects, runs SQL, reads or writes any credential. Enter a password later
through the normal profile editor. Existing credentials and profiles remain
unchanged, including profiles with the same name/endpoint.

Use **Export All...** or a saved profile's **Export...** action. Both capture the
original settings before the native save chooser; changing selection while the
chooser is pending cannot change the exported payload. Passwords, private keys
and saved IDs have no fields in the typed transfer DTO. Atomic save synchronizes
a private same-directory temporary file before replacement. Native chooser
completion captures explicit absence or the existing identity/bytes and the
original parent directory. The common PreparedSave publisher refuses changed,
appeared or retargeted destinations, uses no-replace for absence, validates exact
prepared content and removes only its retained temporary identity on failure.
Windows staging receives a protected current-user-only DACL at CREATE_NEW before
content; denied sharing refuses replacement without deleting the destination.

`transfer.rs` owns the bounded reader, strict schema/duplicate validation,
portable CA syntax, exact settings/policy defaults and atomic export.
`transfer_view.rs` owns native chooser/review state and immutable asynchronous
captures. A cancelled review ignores late CA callbacks; review rows freeze during
the single publication, with Cancel disabled until its result. `ProfileStore`
compares every original saved profile under the existing owner's mutation mutex,
merges later additions and current selection, validates all selected profiles
and rechecks CAs before one atomic append. Failure affects no member of the
batch. A stale edit/deletion requires reopening review. Imported saved IDs are
allocated at this boundary, not accepted from either the file or preview.

Prepared Rust cases cover all shared stages and malformed files, explicit and
legacy policy, each engine/TLS/environment/readonly combination, size/count/port/
name bounds, CA syntax/remap/removal, bounded regular-file reads, atomic export
cleanup/private mode, failed metadata replacement, stale originals and concurrent
append/selection without any credential access. A headless GPUI callback case
covers individual/all selection, deselected missing CA, Cancel and late remap.
Swift consumer cases assert all stages, fresh IDs, exact metadata, v1 defaults,
malformed rejection and required foreign-hint remapping. These cases compile;
they have **not executed** under the user's final-integration policy.

Run the commands in IMPLEMENTATION.md at final integration with completed-run
summaries. Native chooser Cancel/identity, filesystem/locked-file/permissions,
Windows drive and UNC behavior and Mac → Windows → Linux → Mac local CA remaps
still require owned desktops. No headless compile establishes trust negotiation,
secure-store, UIA/Narrator or AT-SPI/Orca coverage. Task 2 and all 171 frozen native
cells remain not-run; baseline artifacts/manifests/reference hashes are unchanged.

Connection/import entities may remain retained for failed-save recovery. Assistance
blocks only while their exact modal owner is active, including save and chooser
work. Cancel/success release that active state; old callbacks cannot close a newer
form or disable completion/signatures permanently. Prepared callback/fake-LSP
regressions cover dismissal, successful publication, failed-save reopening and
late old owners. No runtime or credential-store test has run for these fixes.
