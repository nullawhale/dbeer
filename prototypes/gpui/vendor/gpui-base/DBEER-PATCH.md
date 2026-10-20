# Maintained DBeer explicit editor palette extension

Upstream: `gpui-base` 0.7.3, Apache-2.0, from
https://static.crates.io/crates/gpui-base/gpui-base-0.7.3.crate .
Archive SHA256: `2e9955b6f4b048fd50ca15fc8e225d80bb00ba9ebc8fecdddde5ad26dbef9270`.
Original revision: `67265a36e260ffe03c5aaebdcd8d654dbf892eab`, path `crates/base`,
https://github.com/longbridge/gpui-kit . Preserve LICENSE-APACHE, original
README/manifests/source and this notice in distribution. The full archive is
copied except `.cargo-ok` cache bookkeeping. Original and changed-source hashes
are in UPSTREAM.sha256 and LOCAL-CHANGES.json.

Production changes include src/input/base/{state,element,cursor}.rs and
src/select.rs. A private explicit
projection flag and public set_editor_style_explicit(InputEditorStyle) preserve
all supplied colors, including alpha zero, through the actual render boundary.
Existing set_editor_style keeps its original unset-sentinel behavior. The public
InputEditorStyle struct is unchanged; no consumer literal requires another field.
A source revision getter and a latest-painted-layout revision stamp expose only
source-valid visible single-line range_to_bounds geometry; stale/wrapped/offscreen
or pending-scroll geometry stays absent. Native text actions also check that
opaque revision to reject same-text ABA edits.
Neither projection path replaces text, selection, Undo, IME, scroll, highlighter
or entity ownership. Maintained gpui-component's Editor::editor_style opts in.

A prepared native unit regression renders the same retained editor with explicit
alpha-zero colors and verifies source/selection retention plus normal default
resolution afterward. Compilation is recorded separately from execution. One
original src/text/selection.rs test character is represented with an equivalent
Rust Unicode escape to meet the DBeer prohibition on Cyrillic source characters.
No original production behavior or test expectation is removed.

Task 24 adds `completion_selection_snapshot()` with every original anchor/head
and checked independent selection epoch. Every mutable selection seam and real
focus/blur transition advances that epoch, including leave/return with unchanged
text; exhaustion refuses snapshots. `replace_completion_text()` uses Atomic
intent and the existing silent explicit UTF-16 range path. It avoids the ordinary
explicit-range cursor collapse before history capture, so Undo retains the
original reversed and secondary selections. The application refuses completion
while multiple or nonempty selections are present. No programmatic temporary
selection, per-character insertion, external clipboard or second editor is used.

The separate `InputTextEvent` originates only from nonsilent, noncomposition,
nonhistory native multiline insertion without an explicit replacement range.
Ordinary Change continues unchanged. Restoration, set_value, silent completion,
Undo and IME marked-text updates do not summon automatic completion. Its transient
text is presentation input and is never logged or serialized.

Prepared native editor cases cover non-BMP/CRLF UTF-16 insertion, empty and
single-character Atomic replacements beside typing, one Undo/Redo, actual focus,
reversed/secondary original selections, source-independent caret/focus ABA,
composition refusal and checked-epoch exhaustion. The dependency's actual lib
and test targets are compile-checked separately from root all-targets; execution
and target-native input/Undo observation remain deferred.

Task 26 adds Select::accessibility_id on the existing ObservedElement ComboBox
root. It retains original keyboard/focus/value/activation ownership. The narrow
explicit_editor_style() getter returns only an already application-owned style
when explicit projection is active; retained diagnostic surfaces consume it
without changing source/input/Undo state. Ordinary application inputs return
None and keep the global route. Exact hashes are in LOCAL-CHANGES.json; root
integration typechecking is static evidence, not native UIA/AT-SPI observation.

Task 29 adds Dialog/AlertDialog::semantic_popup for a styled host that publishes
its named semantics on the actual popup bounds. FocusTrapContainer can register
the existing trap without also tracking that same FocusHandle on the fullscreen
backdrop host; the original handle is tracked once on the actual component popup.
Default dialog/focus-trap behavior remains unchanged for all other callers.
No new focus engine, modal decision or native keyboard policy is introduced.
Exact changes to dialog.rs, alert_dialog.rs and focus_trap.rs are audited in
LOCAL-CHANGES.json. Native focus/Return/Escape and screen-reader bounds remain
explicit Windows/Linux acceptance gates.

The standalone unit-target Cargo.lock is reviewed against the current product
lock with all four maintained patch mappings (gpui-base, gpui-component,
gpui-pre-linux and gpui-pre). It supports the changed behavior test targets
without silently substituting upstream gpui-pre. Task 30 records actual
root/standalone package, feature and source differences; this lock does not
select the marked product host-resource feature. Original upstream lock bytes
remain identified by UPSTREAM.sha256; current bytes are in LOCAL-CHANGES.json.
