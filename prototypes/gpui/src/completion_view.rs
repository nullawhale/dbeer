//! Task 24 presentation/ownership core. Workspace wiring is a separate change.
//! SQL scope, matching, quoting and literal/comment suppression remain in Go.
#![allow(dead_code)]

mod display;
mod native;
#[cfg(test)]
mod tests;

pub type PopupAction = display::PopupAction;
pub type PopupHandler = display::PopupHandler;
pub type PopupGuard = display::PopupGuard;
pub type PopupPresentation = display::PopupPresentation;
pub type EditorPopup = display::EditorPopup;
pub type AtomicEdit = native::AtomicEdit;
pub type Diagnostics = native::Diagnostics;
pub type EditorCapture = native::EditorCapture;
pub type NativeSelection = native::NativeSelection;
pub type NativeSelections = native::NativeSelections;
pub fn caret_popup_bounds(
    geometry: gpui_kit::component::input::PrepaintCaretGeometry,
    viewport: gpui_kit::Size<gpui_kit::Pixels>,
    preferred: gpui_kit::Size<gpui_kit::Pixels>,
) -> Option<gpui_kit::Bounds<gpui_kit::Pixels>> {
    display::caret_popup_bounds(geometry, viewport, preferred)
}
pub fn caret_popup_bounds_above(
    geometry: gpui_kit::component::input::PrepaintCaretGeometry,
    viewport: gpui_kit::Size<gpui_kit::Pixels>,
    preferred: gpui_kit::Size<gpui_kit::Pixels>,
) -> Option<gpui_kit::Bounds<gpui_kit::Pixels>> {
    display::caret_popup_bounds_above(geometry, viewport, preferred)
}

use crate::{assistance::RequestOwner, language_service};
use gpui_kit::{App, Entity, Window, component::input::EditorState};
use language_service::{CompletionBatch, CompletionItem, DocumentCapture};
use std::{ops::Range, rc::Rc};

pub const MAX_ROWS: usize = 100;

#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub enum Invocation {
    Automatic,
    Manual,
}

/// Presentation identity is deliberately opaque and contains no SQL text.
#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub struct PopupId(u64);

#[derive(Default)]
struct Epoch {
    value: u64,
    exhausted: bool,
}
impl Epoch {
    fn advance(&mut self) -> Option<PopupId> {
        self.value = match self.value.checked_add(1) {
            Some(value) if !self.exhausted => value,
            _ => {
                self.exhausted = true;
                return None;
            }
        };
        Some(PopupId(self.value))
    }
    fn owns(&self, id: PopupId) -> bool {
        !self.exhausted && self.value == id.0
    }
}

/// Drop the integrator's retained task when replacing/dismissing a request.
/// RequestOwner forwards cancellation to the bounded Task 23 actor.
#[derive(Clone)]
pub struct Request {
    id: PopupId,
    owner: RequestOwner,
    editor: Entity<EditorState>,
    editor_capture: EditorCapture,
    invocation: Invocation,
}
impl Request {
    pub fn id(&self) -> PopupId {
        self.id
    }
    pub fn capture(&self) -> &DocumentCapture {
        &self.owner.capture
    }
    pub fn invocation(&self) -> Invocation {
        self.invocation
    }
    pub async fn complete(&self) -> language_service::Result<CompletionBatch> {
        self.owner.completion(self.editor_capture.caret).await
    }
    fn current(
        &self,
        selections: Option<&NativeSelections>,
        window: &mut Window,
        cx: &mut App,
        valid: &impl Fn(&DocumentCapture, &App) -> bool,
    ) -> bool {
        valid(self.capture(), cx)
            && EditorCapture::read(&self.editor, selections, window, cx).is_some_and(|current| {
                current == self.editor_capture
                    && current.matches_source(&self.editor, self.capture().source(), cx)
            })
    }
}

struct Popup {
    request: Request,
    items: Vec<Rc<CompletionItem>>,
    selected: usize,
    incomplete: bool,
    scroll: gpui_kit::UniformListScrollHandle,
}

/// Retain one State for the workspace. Source/profile/tab/focus/selection/modal
/// changes invalidate it synchronously, before spawning or publishing anything.
#[derive(Default)]
pub struct State {
    epoch: Epoch,
    pending: Option<PopupId>,
    popup: Option<Popup>,
}
impl State {
    pub fn dismiss(&mut self) {
        self.epoch.advance();
        self.pending = None;
        self.popup = None;
    }

    /// `valid` MUST be Workspace::assistance_capture_current, with the current
    /// App. The caller also gates active SQL document/modal/common command state.
    /// Unknown/multiple native selections refuse rather than losing cursors.
    #[allow(clippy::too_many_arguments)]
    pub fn request(
        &mut self,
        owner: RequestOwner,
        editor: Entity<EditorState>,
        selections: Option<&NativeSelections>,
        invocation: Invocation,
        window: &mut Window,
        cx: &mut App,
        valid: impl Fn(&DocumentCapture, &App) -> bool,
    ) -> Option<Request> {
        self.dismiss();
        if !valid(&owner.capture, cx) || owner.capture.editor_revision.is_none() {
            return None;
        }
        let capture = EditorCapture::read(&editor, selections, window, cx)?;
        if !capture.matches_source(&editor, owner.capture.source(), cx) {
            return None;
        }
        language_service::position_at(owner.capture.source(), capture.caret).ok()?;
        let id = self.epoch.advance()?;
        self.pending = Some(id);
        Some(Request {
            id,
            owner,
            editor,
            editor_capture: capture,
            invocation,
        })
    }

    /// Keeps Go order exactly. No client filtering, ranking, quoting, prefix
    /// fallback or snippet expansion may change the contextual engine result.
    #[allow(clippy::too_many_arguments)]
    pub fn publish(
        &mut self,
        request: &Request,
        batch: CompletionBatch,
        selections: Option<&NativeSelections>,
        window: &mut Window,
        cx: &mut App,
        valid: impl Fn(&DocumentCapture, &App) -> bool,
    ) -> bool {
        if !self.epoch.owns(request.id) || self.pending != Some(request.id) {
            return false;
        }
        self.pending = None;
        if !same_capture(request.capture(), &batch.capture)
            || !valid(&batch.capture, cx)
            || !request.current(selections, window, cx, &valid)
        {
            self.dismiss();
            return false;
        }
        let source = batch.capture.source();
        let items = ordered_items(source, request.editor_capture.caret, batch.items);
        if items.is_empty() {
            self.popup = None;
            return false;
        }
        self.popup = Some(Popup {
            request: request.clone(),
            items,
            selected: 0,
            incomplete: batch.incomplete,
            scroll: gpui_kit::UniformListScrollHandle::new(),
        });
        true
    }

    /// Old failures cannot hide a newer popup or set an execution error.
    pub fn failed(&mut self, request: &Request) {
        if self.epoch.owns(request.id) && self.pending == Some(request.id) {
            self.dismiss();
        }
    }

    pub fn refresh(
        &mut self,
        selections: Option<&NativeSelections>,
        window: &mut Window,
        cx: &mut App,
        valid: impl Fn(&DocumentCapture, &App) -> bool,
    ) -> bool {
        let current = self.popup.as_ref().is_some_and(|popup| {
            self.epoch.owns(popup.request.id)
                && popup.request.current(selections, window, cx, &valid)
        });
        if !current && self.popup.is_some() {
            self.dismiss();
        }
        current
    }

    /// Use this both for mouse callbacks and safe native key callbacks. A stale
    /// pointer callback carries its original id and cannot affect a new popup.
    #[allow(clippy::too_many_arguments)]
    pub fn act(
        &mut self,
        id: PopupId,
        action: PopupAction,
        selections: Option<&NativeSelections>,
        edit: AtomicEdit,
        window: &mut Window,
        cx: &mut App,
        valid: impl Fn(&DocumentCapture, &App) -> bool,
    ) -> bool {
        if !self.epoch.owns(id)
            || !self.popup.as_ref().is_some_and(|p| p.request.id == id)
            || !self.refresh(selections, window, cx, &valid)
        {
            return false;
        }
        if action == PopupAction::Dismiss {
            self.dismiss();
            return true;
        }
        let popup = self.popup.as_mut().expect("validated popup owner");
        match action {
            PopupAction::Previous => {
                popup.selected = popup.selected.saturating_sub(1);
            }
            PopupAction::Next => {
                popup.selected = (popup.selected + 1).min(popup.items.len() - 1);
            }
            PopupAction::First => popup.selected = 0,
            PopupAction::Last => popup.selected = popup.items.len() - 1,
            PopupAction::Accept | PopupAction::Choose(_) => {
                let index = match action {
                    PopupAction::Choose(index) => index,
                    _ => popup.selected,
                };
                let Some(item) = popup.items.get(index).cloned() else {
                    return false;
                };
                let request = popup.request.clone();
                // Invalidate before editing: InputEvent::Change cannot revive
                // this response. The edit itself rechecks actual retained state.
                self.dismiss();
                return native::insert(&request, &item, selections, edit, window, cx, valid);
            }
            PopupAction::Dismiss => unreachable!(),
        }
        popup
            .scroll
            .scroll_to_item(popup.selected, gpui_kit::ScrollStrategy::Nearest);
        true
    }

    pub fn presentation(
        &mut self,
        selections: Option<&NativeSelections>,
        window: &mut Window,
        cx: &mut App,
        valid: impl Fn(&DocumentCapture, &App) -> bool,
    ) -> Option<PopupPresentation> {
        if !self.refresh(selections, window, cx, valid) {
            return None;
        }
        let popup = self.popup.as_ref()?;
        Some(PopupPresentation::new(
            popup.request.id,
            popup.request.editor.clone(),
            popup.items.clone(),
            popup.selected,
            popup.incomplete,
            popup.scroll.clone(),
        ))
    }
}

fn same_capture(a: &DocumentCapture, b: &DocumentCapture) -> bool {
    a.document_id == b.document_id
        && a.uri == b.uri
        && a.version == b.version
        && a.context == b.context
        && a.process_generation == b.process_generation
        && a.editor_revision.is_some()
        && a.editor_revision == b.editor_revision
        && a.dialect == b.dialect
        && a.source() == b.source()
}

fn valid_range(source: &str, range: &Range<usize>) -> bool {
    range.start <= range.end
        && language_service::position_at(source, range.start).is_ok()
        && language_service::position_at(source, range.end).is_ok()
}

fn valid_item(source: &str, caret: usize, item: &CompletionItem) -> bool {
    !item.label.is_empty()
        && valid_range(source, &item.replacement_range)
        // The actual Go primary textEdit replaces the word surrounding the
        // request caret. Refuse a foreign edit elsewhere in the document.
        && item.replacement_range.start <= caret
        && caret <= item.replacement_range.end
        && source.len() - item.replacement_range.len() + item.replacement.len()
            <= language_service::LanguageService::MAX_DOCUMENT_BYTES
}

fn ordered_items(
    source: &str,
    caret: usize,
    items: Vec<CompletionItem>,
) -> Vec<Rc<CompletionItem>> {
    items
        .into_iter()
        .filter(|item| valid_item(source, caret, item))
        .take(MAX_ROWS)
        .map(Rc::new)
        .collect()
}

/// A UI trigger only, not SQL analysis. Go returns no candidates inside each
/// dialect's literals/comments. Call after an actual retained input edit with
/// clear IME state; restoration, programmatic edits and caret motion do not call
/// it. Deletion only refreshes an already-visible popup.
pub fn automatic_trigger(inserted: &str, popup_was_open: bool) -> bool {
    if inserted.is_empty() {
        return popup_was_open;
    }
    inserted.len() <= 64
        && !inserted.chars().any(char::is_whitespace)
        && inserted
            .chars()
            .next_back()
            .is_some_and(|ch| ch.is_alphanumeric() || matches!(ch, '_' | '.' | '"' | '`'))
}
