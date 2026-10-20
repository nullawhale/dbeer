use super::{Request, same_capture, valid_item, valid_range};
use crate::language_service::{DiagnosticsBatch, DocumentCapture};
use gpui_kit::{
    App, Context, Entity, EntityId, EntityInputHandler, Focusable, Window,
    base::input::{Diagnostic, DiagnosticSeverity},
    component::input::{EditorState, Position, Rope, RopeExt},
};
use std::ops::Range;

/// Required adapter to the original editor's Atomic + silent explicit-range
/// edit. The current pinned public APIs cannot guarantee this for empty ranges;
/// see COMPLETION_CORE.md for the exact maintained-vendor integration recipe.
/// It must preserve original selections for Undo and perform one native edit.
pub type AtomicEdit =
    fn(&mut EditorState, Range<usize>, &str, &mut Window, &mut Context<EditorState>);

#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub struct NativeSelection {
    pub anchor: usize,
    pub head: usize,
}

/// Adapter input, not a composition/multicursor guess. Populate synchronously
/// from the original editor's real complete selection snapshot. The pinned
/// public API exposes only its active selection, so the sole integration writer
/// must add that narrow vendor accessor before enabling this consumer.
///
/// `selection_revision` must advance on every selection/caret set change, even
/// if it later returns to the same offsets. Never synthesize Single/zero from
/// the active range. Missing evidence stays None and safely refuses completion.
#[derive(Clone)]
pub struct NativeSelections {
    pub editor: EntityId,
    pub document_revision: u64,
    pub selection_revision: u64,
    pub selections: Vec<NativeSelection>,
}

#[derive(Clone, PartialEq, Eq)]
pub struct EditorCapture {
    editor: EntityId,
    document_revision: u64,
    selection_revision: u64,
    selection_utf16: Range<usize>,
    reversed: bool,
    pub caret: usize,
}
impl EditorCapture {
    pub fn read(
        editor: &Entity<EditorState>,
        selections: Option<&NativeSelections>,
        window: &mut Window,
        cx: &mut App,
    ) -> Option<Self> {
        let selections = selections?;
        if selections.editor != editor.entity_id() || selections.selections.len() != 1 {
            return None;
        }
        editor.update(cx, |state, cx| {
            if !state.is_editable()
                || !state.focus_handle(cx).is_focused(window)
                || state.marked_text_range(window, cx).is_some()
                || state.accessibility_document_revision() != selections.document_revision
            {
                return None;
            }
            let selected = state.selected_text_range(false, window, cx)?;
            let caret = state.cursor();
            let only = selections.selections.first()?;
            // Completion is a caret interaction. Preserve actual range and
            // multiple selections by leaving their ordinary editing intact.
            if !selected.range.is_empty()
                || only.anchor != caret
                || only.head != caret
                || state.selected_range() != (caret..caret)
            {
                return None;
            }
            Some(Self {
                editor: editor.entity_id(),
                document_revision: selections.document_revision,
                selection_revision: selections.selection_revision,
                selection_utf16: selected.range,
                reversed: selected.reversed,
                caret,
            })
        })
    }

    pub fn matches_source(&self, editor: &Entity<EditorState>, source: &str, cx: &App) -> bool {
        editor.entity_id() == self.editor
            && editor.read(cx).accessibility_document_revision() == self.document_revision
            && editor.read(cx).value().as_ref() == source
    }
}

#[allow(clippy::too_many_arguments)]
pub(super) fn insert(
    request: &Request,
    item: &crate::language_service::CompletionItem,
    selections: Option<&NativeSelections>,
    edit: AtomicEdit,
    window: &mut Window,
    cx: &mut App,
    valid: impl Fn(&DocumentCapture, &App) -> bool,
) -> bool {
    if !request.current(selections, window, cx, &valid)
        || !valid_item(
            request.capture().source(),
            request.editor_capture.caret,
            item,
        )
    {
        return false;
    }
    let source = request.capture().source();
    // EntityInputHandler uses absolute UTF-16 code units, not an LSP line/column
    // or a UTF-8 range. Both endpoints have already passed the strict converter.
    let range = source[..item.replacement_range.start]
        .encode_utf16()
        .count()..source[..item.replacement_range.end].encode_utf16().count();
    request.editor.update(cx, |state, cx| {
        if !state.is_editable()
            || state.marked_text_range(window, cx).is_some()
            || !state.focus_handle(cx).is_focused(window)
            || state.accessibility_document_revision() != request.editor_capture.document_revision
            || state.selected_range()
                != (request.editor_capture.caret..request.editor_capture.caret)
            || state.value().as_ref() != source
        {
            return false;
        }
        // The integration adapter must set Atomic intent and use the existing
        // silent explicit-range path. No temporary select, set_value, editor
        // recreation, per-character insertion or additional edit is allowed.
        edit(state, range, &item.replacement, window, cx);
        state.focus(window, cx);
        let current = state.value();
        let prefix = &source[..item.replacement_range.start];
        let suffix = &source[item.replacement_range.end..];
        current.len() == prefix.len() + item.replacement.len() + suffix.len()
            && current.starts_with(prefix)
            && current[prefix.len()..].starts_with(&item.replacement)
            && current.ends_with(suffix)
    })
}

/// Owns the retained editor's native syntax diagnostic set. Query execution
/// feedback uses its separate RangeDecorationCollection and error/status fields;
/// this type never receives or mutates those objects.
#[derive(Default)]
pub struct Diagnostics {
    publication: Option<(Entity<EditorState>, DocumentCapture, Vec<Diagnostic>)>,
}
impl Diagnostics {
    pub fn clear(&mut self, cx: &mut App) {
        if let Some((editor, _, _)) = self.publication.take() {
            clear_editor(&editor, cx);
        }
    }

    pub fn refresh(
        &mut self,
        cx: &mut App,
        valid: impl Fn(&DocumentCapture, &App) -> bool,
    ) -> bool {
        let current = self
            .publication
            .as_ref()
            .is_some_and(|(editor, capture, _)| {
                valid(capture, cx) && editor.read(cx).value().as_ref() == capture.source()
            });
        if !current {
            self.clear(cx);
        }
        current
    }

    /// Publish only source-version-correct data; an old callback cannot erase
    /// diagnostics belonging to a newer publication. Repeated current batches
    /// are cheap and do not touch the editor's text, history, focus or selection.
    pub fn publish(
        &mut self,
        editor: &Entity<EditorState>,
        batch: &DiagnosticsBatch,
        cx: &mut App,
        valid: impl Fn(&DocumentCapture, &App) -> bool,
    ) -> bool {
        if batch.capture.editor_revision.is_none()
            || !valid(&batch.capture, cx)
            || editor.read(cx).value().as_ref() != batch.capture.source()
        {
            self.refresh(cx, valid);
            return false;
        }
        let Some(converted) = convert_diagnostics(batch) else {
            return false;
        };
        if self
            .publication
            .as_ref()
            .is_some_and(|(previous, capture, diagnostics)| {
                previous == editor
                    && same_capture(capture, &batch.capture)
                    && diagnostics == &converted
            })
        {
            return true;
        }
        self.clear(cx);
        let accepted = editor.update(cx, |state, cx| {
            // This operation is synchronous on the UI owner. Native syntax
            // underlines and the existing native diagnostic hover share this set.
            let Some(diagnostics) = state.diagnostics_mut() else {
                return false;
            };
            diagnostics.reset(&gpui_kit::component::input::Rope::from(
                batch.capture.source(),
            ));
            diagnostics.extend(converted.iter().cloned());
            state.clear_diagnostic_popover(cx);
            cx.notify();
            true
        });
        if accepted {
            self.publication = Some((editor.clone(), batch.capture.clone(), converted));
        }
        accepted
    }
}

fn clear_editor(editor: &Entity<EditorState>, cx: &mut App) {
    editor.update(cx, |state, cx| {
        if let Some(diagnostics) = state.diagnostics_mut() {
            diagnostics.clear();
        }
        state.clear_diagnostic_popover(cx);
        cx.notify();
    });
}

fn convert_diagnostics(batch: &DiagnosticsBatch) -> Option<Vec<Diagnostic>> {
    let rope = Rope::from(batch.capture.source());
    let mut values = Vec::new();
    for entry in &batch.diagnostics {
        let range = diagnostic_range(batch.capture.source(), &rope, &entry.range)?;
        let severity = match entry.severity {
            1 => DiagnosticSeverity::Error,
            2 => DiagnosticSeverity::Warning,
            3 => DiagnosticSeverity::Info,
            _ => DiagnosticSeverity::Hint,
        };
        values.push((
            entry.range.start,
            Diagnostic::new(range, entry.message.clone())
                .with_severity(severity)
                .with_source("DBeer SQL"),
        ));
    }
    // The native interval tree needs document order, independent of wire order.
    values.sort_by_key(|(start, _)| *start);
    Some(
        values
            .into_iter()
            .map(|(_, diagnostic)| diagnostic)
            .collect(),
    )
}

pub(super) fn diagnostic_range(
    source: &str,
    rope: &Rope,
    range: &Range<usize>,
) -> Option<Range<Position>> {
    if !valid_range(source, range) {
        return None;
    }
    // Despite using lsp_types::Position as its struct, this pinned native
    // DiagnosticSet consumes Unicode scalar columns via RopeExt, not UTF-16.
    // The wire decoder already converted LSP UTF-16 to exact captured bytes.
    let start = rope.offset_to_position(range.start);
    let end = rope.offset_to_position(range.end);
    (rope.position_to_offset(&start) == range.start && rope.position_to_offset(&end) == range.end)
        .then_some(start..end)
}
