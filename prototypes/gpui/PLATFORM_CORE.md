# GPUI native platform core and integration handoff

Task 29's core and production Workspace/editor/grid/dialog/Settings integration
are code-ready. Runtime and final target-native acceptance remain pending.
The production contract and exact final cases are in NATIVE_INTERACTION.md.
Task 2 and all 171 frozen native acceptance cells remain open. Runtime tests are
deferred until final integration after the remaining implementation. Mac GPUI is
development only; the macOS SwiftUI/AppKit product is unchanged.

## Actual native accessibility route

The pinned GPUI Pre 0.3.9 Window accessibility implementation constructs real
AccessKit updates and marshals action requests to its foreground executor. The
maintained Linux 0.3.9 backend owns accesskit_unix::Adapter in both Wayland and
X11 windows, with real activation/action/deactivation callbacks and active tree
updates. The pinned Windows 0.3.9 backend owns accesskit_windows::Adapter for its
actual HWND, handles WM_GETOBJECT and raises real UIA events. These source paths
were inspected; native Windows/Linux compilation and runtime are not inferred.
No second backend, accessibility daemon or global hook is introduced.

src/accessibility/{model,grid,native}.rs supplies an actual publishing/action
route through those adapters, rather than only a serialized inspectable tree:

- RetainedTree::new() creates UI-thread-only Rc state. publish(nodes, focus)
  atomically validates a complete capture; invalidate() removes all actions.
  Capture contains document/result/snapshot/revision/modal-owner identities.
  Binding adds a monotonic publication epoch. Bad trees, cycles/depth, duplicate
  IDs, invalid focus/grid metadata, secret PasswordInput values, unsupported/
  readonly/disabled actions and bounded-text/node excess refuse atomically.
- NodeKey contains opaque document/component/original-source-row/column-ordinal
  identities. It contains no database value, SQL, address, profile name or secret.
  External automation identity remains stable across viewport/selection changes;
  replaced result/snapshot identity changes. Display row positions are separate.
- grid_nodes(GridCapture) builds Grid -> Row -> GridCell and ColumnHeader nodes
  only for the retained realized slice (8,192-node cap). It exposes total counts,
  zero-based visual positions, original IDs, active descendant, full/sparse
  selection summaries and exact selected state on every realized item. Scrolling
  actions request another retained viewport; no unbounded row expansion or
  database request is made during accessibility capture.
- container(tree,key,handler) creates the corresponding REAL visual div with a
  stable guarded ID. Add existing content, bounds/styles and real FocusHandle to
  that wrapper under the SAME parent hierarchy. decorate can augment an existing
  identified wrapper but owns its synthetic callback. Do not add invisible
  duplicate controls or invent bounds. Names, roles, values, row/column metadata,
  readonly/disabled/multiselectable flags and native actions reach AccessKit.
- NativeActionHandler runs on the UI thread only after capture/data validation
  and after releasing the tree borrow. The Workspace handler must recheck its
  live owners, then use the same original retained focus/grid/editor/common
  command paths as keyboard actions. Cell Click opens existing typed editing;
  direct cell SetValue is not advertised and cannot bypass draft/Preview/Apply.
  Focus/ScrollIntoView/context use original source identity, never current index.
- Value deliberately has no Debug/Serialize: SQL NULL, empty string, text NULL,
  DEFAULT, exact numeric strings and Base64/binary byte count stay distinguishable.
  Assistive technology intentionally receives the displayed exact values; they
  must never enter logs, telemetry, debug-tree dumps, probe evidence or exports.

The Workspace integrator must invalidate BEFORE editor/source/draft/modal/
document/result/snapshot/selection-owner changes, publish current captures and
attach the semantic wrappers to actual retained controls. A pure publish without
rendered wrappers is not accessibility integration. Focus must remain the actual
EditorState/grid/control FocusHandle. Active descendant belongs to exactly one
realized cell while the grid owns focus. AT navigation to offscreen items must
use the grid's existing realization/scroll path. Full UIA/AT-SPI virtualization
behavior and selection-pattern observation remain native acceptance work.

## Retained editor text and independent palette extension

The original Editor -> Input exposed only basic value/Focus/SetValue. The new
maintained gpui-component 0.7.3 actually adds AccessKit TextRun children, Unicode
grapheme byte lengths (CRLF is one selectable unit), native TextSelection with
anchor/focus, SetTextSelection and ReplaceSelectedText. Actions use the original
EditorState and exact UTF-8 offsets. They preserve Undo and refuse stale source,
foreign/stale run IDs, invalid character indexes, disabled/readonly edits and
active IME composition. Masked/password values have no text subtree. Source and
capture generations cannot wrap into a new valid approval.

Retain one component::input::InputAccessibilityGuard per original editor;
invalidate() it before each source/document/modal-owner change. Pass it with
Editor::accessibility_guard and a stable Editor::accessibility_id. Do not create
a new editor to change semantics or palettes. accessibility::retained_editor(
state,name,read_only,disabled,guard,optional_palette) supplies this real route;
the returned Editor still accepts normal context-menu/clipboard/style builders.
Actual document-aware guard lifetime and production calls remain integration.

Task 26's render seam is now concrete: Editor::editor_style(InputEditorStyle)
forwards the complete independent palette at Input's existing render boundary.
Maintained gpui-base::set_editor_style_explicit keeps all RGBA including alpha
zero through actual render; normal set_editor_style retains its old unset
resolution. Default fold renderer is retained when the caller supplies none.
No InputEditorStyle DTO or retained engine/entity is replaced. Task 26 must use
this API for original SQL/Preview editors and its editor-owned popup palettes.

Text ranges cap at 16 MiB/65,536 logical runs. Larger text, or a single grapheme
exceeding AccessKit's u8 length ABI, retains the existing value-only route rather
than splitting an indivisible character or inventing text geometry. Source-valid visible single-visual-line bounds use the actual retained layout.
Character/wrapped-line/magnifier coordinates are optional and absent; stale,
wrapped, offscreen or pending-scroll run bounds are omitted. These are explicit
capability limits, not completed native acceptance. Standard-sized native text
range/selection support now has implementation; real UIA/Narrator and AT-SPI/Orca
observations, wrapping/bidi/large-source behavior and geometry remain open.

Both exact pinned crates, full Apache licenses, original manifests/revision/
archive hashes and local patch audits are tracked under vendor/gpui-component
and vendor/gpui-base. Cyrillic upstream test literals use equivalent Rust Unicode
escapes; no runtime locale was removed. Task 31 must ship both new notices.
Task 16's native multi-MIME Linux clipboard code is preserved.

## GNOME session-manager protocol and close authority

src/session_end/{policy,gnome}.rs implements an actual session-bus connection to
GNOME's registered-client API, not compositor close or sleep hooks. The GNOME 46
primary interface specifies RegisterClient(ss)->o, UnregisterClient(o),
QueryEndSession(u), EndSession(u), CancelEndSession(), Stop(), and
EndSessionResponse(bs). Query requires a reply within one second; End has ten
seconds. Neither signal permits opening UI. See the official pinned
[ClientPrivate XML](https://raw.githubusercontent.com/GNOME/gnome-session/46.0/gnome-session/org.gnome.SessionManager.ClientPrivate.xml)
and [manager XML](https://raw.githubusercontent.com/GNOME/gnome-session/46.0/gnome-session/org.gnome.SessionManager.xml).

The adapter uses zbus 5.19.0 async-io, one owned bounded worker/private connection,
32-entry queues, bounded setup/calls and a two-second reconnect delay. It pins
calls and signal sender to the service's original unique owner; subscribes before
RegisterClient to avoid a signal gap; filters only its returned client path;
observes owner loss; unregisters only its own exact path; and closes its private
connection. Initial failure reports Unavailable, service loss reports ServiceLost,
and every reconnect has a fresh generation with no old approval. Overflow closes
the event stream and clears ownership/readiness; consumers must treat receiver
closure as loss and consult snapshot, never as a reviewed exit. Drop requests
bounded cleanup; orderly UI teardown awaits Client::shutdown(). No foreign PID,
logout/reboot/force/inhibit request, global hook or persistent D-Bus service exists.

Required Linux-only integration hooks are:

- Client::start(startup_id) -> Result<Client,ClientError>. App ID currently
  app.dbeer.DBeer must match Task 31's final desktop identity. Availability starts
  as Starting; only a Registered event establishes actual registration.
- events() -> Receiver<Event> and snapshot() -> Snapshot. Event::Response is
  informational; it MUST NOT dispatch Quit, stop work or open any modal.
- set_readiness(registration_generation, CloseReadiness) -> bool must be called
  from common close ownership, with the captured current registered generation.
  Absent and Waiting(CommonCloseToken) refuse. Ready(token) means every existing
  user-authorized review/operation terminal/original disconnect ACK/latest final
  flush already completed and the graph still owns final removal. Ready is an
  immutable terminal state; it cannot precede later source/draft/operation edits.
  The adapter cannot grant ExitOutcome::Reviewed, call finish_close, remove a
  window or manufacture a CloseToken. Stale registration publication refuses.
- Cancelled(request) clears only that OS association. Never continue/start Quit
  from the canceled request, and never replace/cancel a user's selected Commit,
  Roll Back or Stop. Normal independently user-authorized close keeps its common
  token/authority; asynchronous work must still revalidate it.
- Forced means Stop or an OS override may provide no review/flush time. Preserve
  unknown database outcomes and disconnected restoration; never infer rollback.

```text
Starting -> Registered(generation) -> Query/End(request token)
                           |              |
                       owner loss         +-- Absent/Waiting -> immediate false
                           |              +-- terminal matching Ready -> true
                           |              +-- Cancel -> invalidate OS token
                           v
                 ServiceLost/Unavailable -> retry(new generation, no readiness)
```

Repeated signals coalesce one OS token and preserve an associated common token;
a different common token cannot authorize the former request. Cancel allocates
no new close and invalidates the former token. New signals allocate a new token.
Fixed nonsecret rejection reasons ask the user to return to DBeer and close it
before logout. GNOME may ignore refusal when logout is forced; this implementation
honors the documented platform equivalent without claiming interactive logout
review or guaranteed delay. The common Task 22 close graph remains the only
decision authority. Windows' Task 11 owned-HWND subclass is unchanged; actual
Windows native compilation/lifetime/message delivery stays required.

## Native shortcut evidence

The maintained Linux backend additionally exposes
current_key_input_safety()->Option<KeyInputSafety> with Clear/Composing/Unknown
only during original synchronous Wayland/X11 KeyDown dispatch. It uses raw xkb
keysym before ASCII fallback, compose status and backend preedit, then restores
TLS via RAII. None outside dispatch/other threads/repeats/synthetic/KeyUp is not
Clear. Task 28 also checks the original recorder InputState marked_text_range,
repeat/character-priority/modifier rules. Windows' real ToUnicode dead-key path
already sets prefer_character_input; ordinary Ctrl+ASCII control output is
filtered and remains recordable with native evidence and clear marked text.
Actual dead-key/AltGr/IME/layout behavior still needs target observation.

## Verification and remaining production work

Prepared pure cases include exact typed values/fixtures, duplicate identities,
cycles/bounds/atomic refusal, virtual positions versus original rows, full/sparse
selection, actual GPUI native property writing, stale document/result/snapshot/
revision/modal callbacks, UI-thread ownership, UTF-8/CRLF/empty/foreign text
positions, guard exhaustion and native dispatch TLS lifetime. Policy cases cover
common tokens, repeated/canceled requests, force and service loss. The ignored
private-bus case starts only its own dbus-daemon and fake GNOME service, exercises
actual registration/signals/replies/cancellation/owner loss/unregistration, and
never connects to the operator's bus. Native editor unit cases cover actual
selection/replacement/Undo/readonly/disabled/IME and repeated palette renders;
the base case verifies actual explicit alpha-zero rendering and normal defaults.

Only compilation, Clippy and formatting/static checks are implementation-time
verification. Unit targets for dependencies are NOT compiled by root all-targets;
component/base test targets were checked separately. Exact final results/logs
are supplied in the handoff. No test execution, database/UI/store/clipboard probe
or target-native compilation is claimed. At final integration run and retain
completed summaries, including explicit skipped native cases:

```sh
./scripts/gpui-prototype.sh test --locked -- accessibility:: --test-threads=1
./scripts/gpui-prototype.sh test --locked -- session_end:: --test-threads=1
# On an owned native Linux test host with dbus-daemon, explicitly include:
./scripts/gpui-prototype.sh test --locked -- session_end::gnome::protocol_tests --ignored --test-threads=1
# Matching Rust toolchain/environment, without a helper or external desktop:
cargo test --manifest-path prototypes/gpui/vendor/gpui-base/Cargo.toml --locked --lib -- dbeer_explicit_alpha --test-threads=1
# Supply the same root gpui-base path patch when testing component separately:
cargo test --manifest-path prototypes/gpui/vendor/gpui-component/Cargo.toml --locked --features tree-sitter,tree-sitter-sql --config "patch.crates-io.gpui-base.path = '$PWD/prototypes/gpui/vendor/gpui-base'" --lib -- input::accessibility::tests --test-threads=1
cargo test --manifest-path prototypes/gpui/vendor/gpui-component/Cargo.toml --locked --features tree-sitter,tree-sitter-sql --config "patch.crates-io.gpui-base.path = '$PWD/prototypes/gpui/vendor/gpui-base'" --lib -- dbeer_ --test-threads=1
```

Use the actual matching native build runners on Windows 11 and Ubuntu 24.04
Wayland/X11. Later integration must populate editor/grid/inspectors/dialogs/
Settings, route all actions through current retained owners, wire close readiness
and bounded teardown, preserve modal Return/Escape and real keyboard/IME paths,
and observe DPI/mixed-monitor/high-contrast/focus/hover visibility. Native UIA/
AT-SPI inspection must cover exact values, selection and virtualization, not just
node counts, API presence or a model snapshot. No frozen baseline/hash/manifest/
reference artifact was modified, and no acceptance checkbox is waived.

## Task 26 palette and selector checkpoint

Actual application/editor Settings now populate the retained production workflow.
A narrow maintained Select builder forwards native automation IDs to the existing
ComboBox root, preserving name/value/focus/actions. The original editor's explicit
style is readable by its native diagnostic popover, so opposite app/editor modes
do not reintroduce application diagnostic colors. Root all-target check/Clippy
compile these consumers in default/native-smoke configurations. No new vendor
unit tests were added; no dependency unit test execution or native UIA/AT-SPI
observation is implied. Actual target IDs/roles/values/actions remain unobserved.

## Task 29 production checkpoint

The original retained Workspace now consumes this bridge on actual DataTable
root/row/header/cell bounds, typed exact values and original virtual identities.
Native actions use live document/result/snapshot/source/selection/modal owners,
original focus/scroll/edit/menu paths and the existing Preview/Apply workflow.
SQL/review/inline/inspector editors retain live owner guards and actual native
selection epochs. Named dialog semantics follow actual popup bounds and original
focus traps; keyboard context, Tab, Delete and F2 routes are retained. Large-cell
budgets disclose missing native values without discarding the rest of the UI.

Normal Linux startup now attaches the owned GNOME client. Common terminal
evidence follows all helper/ACK/current-finalizer/latest document completion;
Ready leads only to bounded owned teardown and the original terminal removal
continuation. A retained publisher survives moving the Client into shutdown.
No required flush follows Ready normally; OS events never create close authority.
Actual UIA/AT-SPI, keyboard/IME/clipboard/DPI/session delivery and all frozen
native acceptance cells remain unrun. See NATIVE_INTERACTION.md for boundaries
and deferred commands; static compilation supplies no observation evidence.
