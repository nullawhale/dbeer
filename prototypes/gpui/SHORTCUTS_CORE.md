# GPUI shortcut preferences and recorder core

Task 28 is implementation code-ready on 2026-10-20. The actual retained Settings
section, startup/store ownership, exact native routing, common menu/toolbar labels
and latest normal-close finalizer are integrated in `src/shortcut_settings.rs`.
Code-ready is not runtime acceptance. Runtime tests remain deferred until final
integration after Task 32 code. The macOS product stays SwiftUI/AppKit; Mac GPUI
is development only. Windows 11 x64 and Ubuntu 24.04 x64 Wayland/X11 acceptance,
Task 2 and all 171 native cells remain open.

## Shared command authority

`src/shortcuts.rs` maps five `ConfigurableCommand` IDs to the existing
`commands::CommandId`. Titles come from that registry. Default and fixed
assignments come directly from the current `commands::DEFAULT_SHORTCUTS` table,
including any later fixed commands added there. There is no second command
registry or copied default shortcut list. Current Windows/Linux defaults are
Ctrl+Enter for Run and Ctrl+Shift+Enter for Run Script. Stop and both Run to File
actions have no default, matching the reference Swift AppShortcut descriptors.
The Mac development host uses the registry's primary Cmd modifier.

`Preferences::{shortcut,menu_label,validated_bindings}` provide one view for
Settings, tooltips, menus and keyboard resolution. `validated_bindings` includes
fixed registry entries and effective configurable entries, and conservatively
treats their scopes as overlapping for conflict checks. `ResolvedBinding` exposes
the existing `CommandId`, the exact `Shortcut` and the original scope. The test-only
`key_binding()` builds a candidate descriptor for registry assertions. Production
does not install configurable generic bindings. SQL actions stay in
`DBeerSqlEditor > Input`; Stop uses the Workspace scope and must retain the
common original-operation gate. Native editing actions remain toolkit actions.

`Preferences::{set,clear,restore_default,replace_overrides,reset_defaults}`
implement atomic accepted model changes. `clear` persists `Unbound`, while a
missing override follows the registry default. Reset removes overrides. A
per-command reset refuses a conflict without changing the model; a complete
replacement validates the final assignment, allowing valid swaps. Failed
capture, validation, cancellation and focus loss leave the previous mapping
intact. Native traversal/deletion/navigation, editing combinations, operating
system commands, platform Super/Win shortcuts and ambiguous Ctrl+Alt/AltGr
combinations are protected. Ctrl+Space and Ctrl+. stay available for native
completion/code actions. Fixed app conflicts use the actual registry, not an
unmaintained list. New bindings introduced by Tasks 24/25 must remain in that
registry or extend its shared protected-key contract.

## Real native event limits and recorder contract

The inspected pinned GPUI `KeyDownEvent` contains `keystroke`, `is_held` and
`prefer_character_input`. `Keystroke` contains native-backend `key`, optional
`key_char` and control/alt/shift/platform/function modifiers. It does **not**
carry physical key position, scan code, modifier side, native dead-key status
or universal marked-text state. The persisted `KeyBasis::NativeKey` explicitly
records this supported identity. Physical/scancode/macOS-keycode DTOs are
rejected. This core never substitutes macOS key codes or infers physical Latin
keys from text.

`Shortcut::{matches_native,label}` and test-only `keystroke`/`binding_text` use the same native
`key` and exact modifiers. `key_char` never changes command identity. Windows
labels use Ctrl/Alt/Shift/Win, Linux uses Ctrl/Alt/Shift/Super; the latter platform
modifiers are displayed faithfully but reserved against user bindings. Native
backends currently provide their own layout conventions: Linux's existing
`keystroke_from_xkb` can use its `guess_ascii` fallback on non-ASCII layouts;
Windows derives native keys from virtual keys/current layout and preserves
character-priority input. There is no repository-level physical-key guarantee.
Greek/Han cases assert that the core obeys the delivered native key rather than
substituting typed characters. These cases do not prove native backend layout
behavior. Actual non-Latin default matching remains a native backend/Task 29
verification obligation, with a maintained backend change required if those
desktop observations reveal a gap.

Create `Recording::begin(command)` only after the recorder gains actual focus.
Call `capture(&mut preferences, &KeyDownEvent, InputSafety, platform)` from that
focused control, then follow `CaptureOutcome`:

- `Bound`: refresh all consumers and reserve the new preference value for save.
- `Rejected`: show the fixed validation message and continue recording; no
  mapping changed. `IgnoredRepeat` and `ModifierOnly` never bind a key.
- `Cancelled`: finish without changes. Escape cancels; Tab cancels with
  `Traverse {reverse}` and allows actual native focus traversal.
- `PassThrough`: preserve the original input/IME handler. Do not stop propagation
  or turn an uncertain native event into a shortcut.

Call `cancel()` on the Cancel button, focus loss, Settings close or recorder
replacement. `Recording::{clear,restore_default,reset_defaults}` finish recording
only after the requested atomic model change succeeds. Other Settings rows may
use the corresponding preference APIs while cancelling the active recorder.
There is no global observer or hook and no database/client reference in this
module.

`InputSafety` requires `Evidence::{Clear,Active,Unknown}` for both original
focused-input marked text and native dead-key state. Read actual
`EditorState::marked_text_range` using the existing `EntityInputHandler` seam;
missing state is Unknown. `InputSafety::from_gpui(event, marked_text)` uses the
current native platform; `from_native` accepts an explicit native source for
pure adapters/cases. Windows's inspected `process_key` uses actual keyboard
state and ToUnicode: negative dead-key results set `prefer_character_input`;
ordinary Ctrl letters whose control characters were filtered retain false.
Together with real marked-text evidence, this admits native Ctrl character
recording without treating AltGr as a shortcut. The Mac development fallback
admits known Enter/Tab/Escape/F1-F24 keys, leaving other missing evidence Unknown.
`prefer_character_input`, active/unknown
composition or dead-key state passes through; repeated keydown never records or
resolves a command. Ctrl+Alt is never accepted even if a backend loses the
AltGr priority flag.

Linux's existing ASCII fallback can hide a raw dead-key name. The maintained
Task 29 backend extension therefore captures the **raw** keysym and actual
compose/preedit status before fallback, around the synchronous original X11 or
Wayland KeyDown dispatch. `dbeer_gpui_linux::{KeyInputSafety,
current_key_input_safety}` returns scoped Clear/Composing/Unknown; this core maps
it to the dead-key evidence. Raw dead keys/Multi_key/preedit/compose in progress
are Active; cancelled/unavailable/NoSymbol states are Unknown. Outside that
native callback, repeats, synthetic events, another thread and KeyUp have no
evidence and remain Unknown. The RAII scope restores previous nested state.
No global observer, fabricated event field or keycode substitution is involved.
This permits real Ctrl letter recording with clear native evidence while
refusing hidden dead keys. The later focused recorder must call the adapter
**inside** that native input callback and read its own actual marked-text state;
it must not cache evidence or replace Unknown with false/Clear. Native Linux
compilation/runtime of this target-gated adapter remains required.

`Preferences::command_for_native(event,safety,platform)` resolves a safe exact
native event to an existing `CommandId`; it performs no action. The later caller
must preserve original control precedence and synchronously enter
`Workspace::command(id, CommandOrigin::Shortcut, ...)`. Existing common capture,
modal/text-field/grid/IME/busy/unknown/session gates and original immutable
document/operation ownership remain authoritative. Do not dispatch to helper
or re-read an active tab after awaiting.

GPUI's generic `Keystroke::should_match` also matches character aliases. Blindly
installing the candidate bindings would bypass the exact native-identity gate.
Integration must gate native events before command dispatch and ensure old
default mappings are removed/replaced when preferences change. Menu/toolbar
callbacks continue using their existing captured command path, with labels read
from the same preference value.

## Independent storage and close contract

`ShortcutStore::new(Arc<DataDirectory>)` reuses the existing Workspace owner.
Create one store per Workspace; clone it for asynchronous tasks. Never acquire
a new data owner. The separate version-1 `shortcuts.json` DTO stores only
`version`, `overrides`, stable command IDs, explicit bound/unbound state and
native-key/modifier data. It has no SQL, result, connection, credential,
authorization, restoration or session fields.

`load(platform)` strictly bounds reads at 16 KiB and validates schema,
duplicate/unknown fields and commands, duplicate command entries, version,
canonical native keys, protected combinations and complete mapping conflicts.
Symlinks, reparse points, nonregular and oversized files are refused.
`load_or_default` returns defaults plus a fixed error while retaining the
original bytes and disabling publication. Invalid stored mappings therefore
fall back truthfully; they are never silently rewritten as defaults.

`reserve(preferences,platform)` must run synchronously at each accepted UI
change before debounce/spawn. It validates the whole snapshot and returns an
owned `SaveRequest` with `revision()`. `commit()` returns `Published` or
`Superseded`; all store clones share ordering. Reservations and publication
serialize under the same state mutex, and owner mutation locking serializes
cooperating persistence writers. Reads compare exact prior bytes immediately
before replacement. Both ordinary saves and explicit default recovery use the
shared `files::CapturedDestination` and `PreparedSave` publisher. It retains the
original parent and destination identity/bytes or absence, creates a same-directory
private temporary exclusively, syncs it, and verifies the retained handle, named
temporary identity and exact staged content before publication. Cleanup removes
only that retained named identity; foreign replacements remain untouched. There
is no destination-delete workaround. Unix staging uses 0600 beneath the owner's
0700 directory. Windows creates protected owner-only staging before writing and
transfers the authorized destination DACL only at publication. Unverified Windows
publication returns `PublicationUnknown`, leaves `latest_saved()` false and never
promises unchanged destination bytes. Actual ACLs, sharing, durability and
replacement require native acceptance. Directory sync after known publication
does not falsely report an unchanged destination.

Failed load remains unwritable until explicit successful reload or user-invoked
`recover_defaults`. Recovery first writes exact bounded original bytes to a
private exclusive, nonoverwriting `shortcuts-recovery-<UUID>.json`, then resets
atomically and invalidates older reservations. The backup uses the same anchored
byte-oriented `PreparedSave` publisher with fresh captured absence and private
creation before content. Arbitrary corrupt bytes, including invalid UTF-8, are
copied without decoding. Existing names retry with a fresh UUID; late collisions
refuse rather than overwrite. Backup write/sync or unverified Windows publication
aborts before primary reset, retains any published or foreign evidence, and leaves
preferences unwritable. Cleanup can remove only retained owned staging identity.
Oversized/unreadable/unsafe files
require external repair and cannot be erased by recovery. Fixed errors never
display native payloads, paths or user data. External conflict preserves its
bytes and requires explicit reload.

`latest_saved()` remains false after a failed load/save or pending latest
reservation. Normal close freezes Settings mutations and awaits the retained latest request
for the latest accepted in-memory value. `flush_latest` remains test-only for
standalone store cases. Only an acknowledged Published/latest-saved state completes that
flush. Superseded is not evidence that the latest request published. Retain the
owner across awaited work and preserve the existing Cancel/Retry/transaction/
unknown-outcome close decisions. Never flush an obsolete startup preference
snapshot or widen SQL restoration DTOs.

## Production Workspace and Settings integration

`Workspace.shortcuts` retains one `shortcut_settings::State`. Startup creates one
`ShortcutStore` from `ProfileStore::data_owner()` and loads before first render;
no second directory lock, connection/session or restoration field is added.
A disposable Workspace explicitly projects PreviewOnly and never writes personal
preferences. Saved, Saving, read-only fallback, failed save, Reloading and
Recovering are fixed projections of the original owner.

Settings > Shortcuts enters the common command dispatcher and opens the same
retained Settings dialog as Appearance. `mount_shortcuts` keeps the real section
and typed subscription beside the original ThemeLibraryView. It validates original
Settings/section IDs, actual current projection revision, pending local epoch and
original focused recorder before recomputing a candidate from current preferences.
Record/Rebind, Clear, Cancel, per-command Restore Default and Restore All Defaults
reuse the core. Dismissal synchronously invalidates capture before closing the
original dialog and restores its captured focus. Appearance/OS/library updates do
not replace shortcut inputs or gain shortcut mutation authority.

Accepted changed mappings reserve the full valid value synchronously before
spawn. A broadcast completion retains the exact request/reservation/store for UI
and close. A no-change request advances its UI epoch without invalidating the
actual latest reservation. Only Published plus `latest_saved()` projects Saved;
Superseded and stale callbacks cannot acknowledge newer state. Write failure
permits Retry of current preferences. Conflict/read failures require explicit
Reload. Read-only startup never reserves defaults. Recover Defaults preserves
exact bounded original bytes privately before replacement through the original
store. Original reload/recovery tickets remain retained through Settings dismissal;
no later edit can run during IO, and only that current ticket may reconcile.

The common Shortcuts finalizer drains original IO INCLUDING foreground
reconciliation, then awaits the latest reserved mutation and checks actual
publication. Completion revisions cause the close graph to reflush both old
successes and errors, preserving CloseToken and sibling scope. Unchanged failed
startup and disposable previews have no writable mutation and cannot trap close.
Unsaved accepted changes still refuse close retryably. All SQL/session/transaction/
unknown/full-export/Apply/file/modal/Cancel guards remain authoritative.

`shortcut_key` runs synchronously inside the original native callback. It yields
to Settings/recorders, prompts, text fields and close; reads the original focused
SQL editor's actual marked text; consumes scoped native dead-key/compose evidence;
and resolves exact key identity through `command_for_native`. Unknown/active
composition, repeats, character priority and Ctrl+Alt/AltGr pass through. SQL
bindings require original editor focus; Stop retains the common original-operation
gate on proven non-text focus too. After pure availability, dispatch enters
`Workspace::command(id, Shortcut, ...)` synchronously and captures the original
operation once. No helper call exists in preference or recorder paths.

`commands::install_keys` skips the five configurable commands, removing old
Run/Script defaults from generic alias matching. Fixed commands and native input
editing remain unchanged, including protected Ctrl+Space completion and popup
navigation/signature Escape precedence. Menu labels, toolbar text/tooltips and
native matching read the SAME current preferences; native menus refresh after
accepted edit/reset/reload/recovery. No physical key or Mac keycode substitution
is used; actual target layout/IME/AltGr observations remain pending.

## Prepared verification and source freeze

The section, owner, core and integrated production paths compile in default and
native-smoke all-target configurations. Both all-target Clippy configurations
with warnings denied and root fmt --check completed successfully using Rust
1.99.1. Exact commands, exit codes, durations and logs are in ignored
`build/gpui/task28-static-results.json` and `task28-final-*.log`. Only the existing
block 0.1.6 future incompatibility notice remains. Broad module dead-code
allowances are removed; standalone candidate binding/store convenience APIs are
confined to test targets. No new vendor/shared Go/Swift code required additional
unit-target compilation. Source/privacy/provenance scans are recorded separately.

`shortcut_settings/tests.rs` adds original startup/restart, explicit unbinding,
reset, exact corrupt backup, disposable/epoch exhaustion, candidate-only/no-backend,
actual latest reservation finalization, shared Settings request subscriptions,
stale owner/event refusal, original retained appearance/library/editor/focus,
recorder precedence, marked-text/AltGr/text-field refusal, exact native alias and
unknown/close gates, recovery/explicit external reload after Settings dismissal,
and stale-error/latest-close token/sibling cases. These cases are PREPARED and
UNRUN. Existing core/control/fixture tests remain required.

Prepared cases cover registry/default equality, explicit unbound/reset/restart,
atomic swaps/conflicting reset, fixed/native editing conflicts, failed capture,
Escape/Tab/repeat/modifiers, IME/dead/unknown/AltGr pass-through, native Greek/Han
identity, forbidden physical DTOs, strict duplicate/unknown/future/corrupt/oversize
input, exact recovery backup, ordered/concurrent requests, reload invalidation,
external conflict, injected replacement failure, unrelated workspace-file
isolation, private modes/symlinks and Windows locked destination. Actual commit
and recovery hooks additionally replace or edit staged files before publication,
assert unchanged destination/publication revision, preserve foreign replacements
and exact recovery backups, and retain stale-reservation/retry/restart behavior.
The actual normal-close finalizer consumes each faulted commit result and refuses
to finish until a later latest request publishes successfully. These regressions
are prepared and unrun.
The additional actual default-recovery backup cases cover invalid UTF-8 exactness,
colliding names, empty private staging under broad Windows parent inheritance,
retained foreign identity across injected write/sync failures and late foreign
backup targets. They retain read-only failure, published revision, stale request
and explicit retry/restart authority and remain unrun pending coordinated checks.
Resolution
returns only CommandId and cannot submit a backend request; integrated original
capture/no-backend assertions are prepared in the production owner tests.

No runtime Rust/Go/Swift/database/UI/credential/clipboard test or probe ran. No
Windows/Linux desktop build, installed upgrade or native acceptance is claimed.
Frozen baseline/manifests/reference/replay, owner signing/trust, release metadata
and the macOS product are unchanged. Task 28 is at full source freeze.

At final integration after Task 32 code, execute the prepared cases and record
completed summaries before claiming a pass:

```sh
./scripts/gpui-prototype.sh test --locked -- shortcuts:: --test-threads=1
./scripts/gpui-prototype.sh test --locked -- shortcut_settings:: --test-threads=1
./scripts/gpui-prototype.sh test --locked -- shortcut_settings_view:: --test-threads=1
./scripts/gpui-prototype.sh test --locked --features native-smoke -- shortcuts:: --test-threads=1
./scripts/gpui-prototype.sh test --locked --features native-smoke -- shortcut_settings:: --test-threads=1
./scripts/gpui-prototype.sh test --locked --features native-smoke -- shortcut_settings_view:: --test-threads=1
./scripts/gpui-prototype.sh test --locked --features native-smoke -- commands:: --test-threads=1
./scripts/gpui-prototype.sh test --locked --features native-smoke -- close:: --test-threads=1
```

Then verify real Settings, menu/toolbar/keyboard synchronization, clear/reset
restart, corrupt recovery, latest close saves, native editing/focus/IME/dead keys,
AltGr and non-Latin layouts using owned Windows 11 and Ubuntu Wayland/X11
desktops. Headless compilation cannot close those native acceptance cells.
