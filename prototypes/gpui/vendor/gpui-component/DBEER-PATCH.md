# Maintained DBeer input accessibility and palette extension

Upstream: `gpui-component` 0.7.3, Apache-2.0, from
https://static.crates.io/crates/gpui-component/gpui-component-0.7.3.crate .
Archive SHA256: `465a363235cd4062ef5f0953fc096fc764ed6f53dfbd9f409f669f93ea3b1ff9`.
The package's `.cargo_vcs_info.json` records upstream revision
`67265a36e260ffe03c5aaebdcd8d654dbf892eab`, path `crates/component` in
https://github.com/longbridge/gpui-kit . Preserve `LICENSE-APACHE`, original
README/manifests/source, this notice and the base crate notice in distribution.
No build reads ignored DBeer documentation or fetches this patch.

The original package is copied completely except `.cargo-ok` (Cargo cache
bookkeeping). `UPSTREAM.sha256` records original file hashes; `LOCAL-CHANGES.json`
records changed/new source and fixture hashes. The local Cargo.lock differs only
because its gpui-base source resolves to the maintained same-version local copy.

Production changes include `src/input/{accessibility.rs,input.rs,editor.rs,
state.rs,mod.rs}`, `src/input/popovers/diagnostic_popover.rs`, and `src/select.rs`. Input publishes actual AccessKit TextRun children,
UTF-8 grapheme lengths, anchor/focus TextSelection and captured native selection/
replacement actions. These use the original EditorState/selection/edit/Undo/IME
implementation. Password/masked values receive no text subtree. Readonly,
disabled and active composition reject unsupported changes. The UI-thread-only
InputAccessibilityGuard must be invalidated before document/source/modal-owner
replacement; current source and source-generation checks also refuse stale work.
Guard epochs never wrap back into a valid epoch. Public automation IDs remain
separate from guarded internal element IDs. No SQL/result/secret logging exists.

Editor::editor_style(InputEditorStyle) forwards a full explicit palette at Input's
render boundary to maintained gpui-base::set_editor_style_explicit. Ordinary
inputs preserve the old global/unset-sentinel route. Explicit fully transparent
RGBA colors remain explicit. Retained source, entity, Undo, IME, native clipboard,
context-menu and highlighter state remain owned by the original editor. Missing
application fold-icon rendering retains the toolkit's original fold renderer.

Text range exposure is bounded to 16 MiB / 65,536 logical runs. A grapheme whose
UTF-8 byte length exceeds AccessKit's u8 character-length ABI, or larger input,
uses the original value-only route rather than fabricated/split character units.
Source-revision-valid single-visual-line bounds use the actual retained layout.
Wrapped-line/character/magnifier geometry and native screen-reader
observation remain explicit integration/acceptance work. No fake rectangles or
unverified platform capability claims are supplied.

The original archive's unit tests refer to five files outside its package. They
are made self-contained without suppressing those tests: two icons come from the
cached exact gpui-kit-assets 0.7.3 package; markdown and Aurora JSON come from the
same upstream revision's `examples/fixtures/test.md` and `themes/aurora.json`.
They are under tests/fixtures, with exact hashes in LOCAL-CHANGES.json. The two
Lucide icons retain the original gpui-kit-assets LICENSE-LUCIDE notice. The dock
export test reads the actual adjacent maintained gpui-base source. No referenced
remote images are downloaded. One upstream diff test string used Cyrillic;
equivalent Rust Unicode escapes preserve the exact test string while satisfying
the DBeer source-character convention. No production locale is omitted.

Prepared regressions cover grapheme/CRLF/empty/reversed selection, run/source/
capture staleness, oversized units and guard exhaustion, actual retained-editor
selection/edit/Undo, readonly/disabled/IME refusal and repeated palette rendering.
They are compile checked only at this implementation stage. Run selected native
and pure cases at final integration; do not treat compilation as UIA/AT-SPI proof.

Task 24 additionally forwards the maintained base input's `InputSelection`,
`InputSelectionSnapshot` and `InputTextEvent` from the existing input module.
The concrete retained EditorState owns the snapshot, selection epoch, Atomic
completion replacement and native event implementation; the component introduces
no alternate selection/history engine or completion provider.

Task 26 forwards Select::accessibility_id through the maintained BaseSelect to
its existing ComboBox root, alongside its original name/value/focus/actions.
No semantic duplicate or alternate input is created. DiagnosticPopover reads
its original retained editor's explicit style on every render for independent
background/text/severity-border colors; ordinary inputs retain global colors.
Exact changed-source hashes are in LOCAL-CHANGES.json. Root integration targets
compile these APIs; no new dependency unit tests or observed UIA/AT-SPI/native
selector evidence is claimed. Native target observations remain pending.

Task 29 connects these APIs to production retained owners. InputAccessibilityGuard
accepts a UI-thread-only live owner predicate; native input actions also recheck
the actual independent selection epoch and exact current top-dialog FocusHandle,
including containment in that original dialog. Text selection/replacement
invalidates its capture before entering the original native engine. Retained
source/entity/Undo/IME/password/readonly ownership remains unchanged.

Narrow TableDelegate additions decorate the actual original table root and rows,
report original selection semantics, and invalidate before mutable delegate
access. ContextMenuHandle opens the same original menu at its actual retained
bounds; ordinary focus-path triggers accept Shift+F10/Menu while externally
owned grid handlers retain their selection route. No menu, editor, table or
parallel semantic tree replaces the existing widget.

Dialog::accessibility_label names the actual popup surface with its original
Dialog/AlertDialog role and FocusHandle. Maintained Base keeps the original
fullscreen trap/dismissal host and registers the same focus handle only on the
popup. This preserves real semantic bounds without a second focus owner.
Icon-only buttons fall back to their displayed tooltip for their native name.
All source changes and exact current local hashes are in LOCAL-CHANGES.json.
Prepared production/native guard/selection cases are compile checked; native
Windows/Linux input, UIA/AT-SPI and screen-reader observation remain unrun.

Named popup identity is bound to ActiveDialog's checked monotonic original
lifetime, allocated only when opening and retained across all builder/render/
theme/focus refreshes. Canceled/reopened dialogs cannot reuse that internal
native subtree identity; author IDs are explicitly published separately. The
prepared case checks original focus and same-live redraw stability plus reopen
ABA. It is compile checked only; target observation remains pending.

The standalone unit-target Cargo.lock is reviewed against the current product
lock with all four maintained patch mappings (gpui-base, gpui-component,
gpui-pre-linux and gpui-pre). It supports the changed behavior test targets
without silently substituting upstream gpui-pre. Task 30 records actual
root/standalone package, feature and source differences; this lock does not
select the marked product host-resource feature. Original upstream lock bytes
remain identified by UPSTREAM.sha256; current bytes are in LOCAL-CHANGES.json.
