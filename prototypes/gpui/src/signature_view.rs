//! Read-only function signatures from the existing offline Go language service.
//! No SQL parsing, metadata fetching, database access or editor mutations live here.
//! Workspace scheduling and common command wiring live in signature.rs.
#![allow(dead_code)]

mod display;
mod model;
#[cfg(all(test, feature = "native-smoke"))]
mod native_tests;
#[cfg(test)]
mod tests;
#[cfg(test)]
pub(super) fn fixture(mode: &str) -> std::path::PathBuf {
    tests::fake(mode)
}

pub use display::{PopupAction, PopupPresentation};
pub type PopupHandler = display::PopupHandler;
pub type PopupGuard = display::PopupGuard;

use crate::{
    assistance::RequestOwner,
    completion_view::{EditorCapture, NativeSelections},
    language_service::{self, DocumentCapture, SignatureHelp},
};
use gpui_kit::{App, Entity, Window, component::input::EditorState};
use std::{rc::Rc, time::Duration};

/// Matches the native Swift editor's signature refresh delay. The Workspace
/// owns one replaceable task, waits on its executor timer, then calls help().
pub const AUTOMATIC_DELAY: Duration = Duration::from_millis(75);

#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub enum Invocation {
    Automatic,
    Manual,
}

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

/// Retains only Task 23's bounded mailbox and original native editor identity.
/// Dropping the integrator's task on replacement cancels its exact request.
#[derive(Clone)]
pub struct Request {
    id: PopupId,
    owner: RequestOwner,
    editor: Entity<EditorState>,
    editor_capture: EditorCapture,
}
impl Request {
    pub fn id(&self) -> PopupId {
        self.id
    }
    pub fn capture(&self) -> &DocumentCapture {
        &self.owner.capture
    }
    pub async fn help(&self) -> language_service::Result<Option<SignatureHelp>> {
        self.owner.signature_help(self.editor_capture.caret).await
    }
    fn same_snapshot(&self, owner: &DocumentCapture, editor_capture: &EditorCapture) -> bool {
        same_capture(self.capture(), owner) && self.editor_capture == *editor_capture
    }
    fn current(
        &self,
        selections: Option<&NativeSelections>,
        window: &mut Window,
        cx: &mut App,
        valid: &impl Fn(&DocumentCapture, &App) -> bool,
    ) -> bool {
        valid(self.capture(), cx)
            && EditorCapture::read(&self.editor, selections, window, cx).is_some_and(|capture| {
                capture == self.editor_capture
                    && capture.matches_source(&self.editor, self.capture().source(), cx)
            })
    }
}

struct Popup {
    signatures: Rc<model::Signatures>,
    selected: usize,
}

/// One transient instance per Workspace. Invalidating this state never edits
/// text, selection, focus, Undo, execution feedback or diagnostic decorations.
#[derive(Default)]
pub struct State {
    epoch: Epoch,
    request: Option<Request>,
    pending: bool,
    popup: Option<Popup>,
    suppressed: Option<(DocumentCapture, EditorCapture)>,
}
impl State {
    /// Call synchronously on lost editor/window focus, modal opening, tab/profile
    /// rotation, close, changed source/selection or unavailable assistance. Also
    /// drop the retained asynchronous task. Old replies cannot reacquire this epoch.
    pub fn invalidate(&mut self) {
        self.epoch.advance();
        self.request = None;
        self.pending = false;
        self.popup = None;
    }

    pub fn interaction_id(&self) -> Option<PopupId> {
        self.request
            .as_ref()
            .filter(|_| self.pending || self.popup.is_some())
            .filter(|request| self.epoch.owns(request.id))
            .map(Request::id)
    }

    /// `valid` must call Workspace::assistance_capture_current. The caller also
    /// gates the current SQL document, common command context and modal state.
    /// Requests run on source AND native selection revision changes, never on
    /// a Rust approximation of a function call. An unchanged null reply is cached.
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
        if owner.capture.editor_revision.is_none() || !valid(&owner.capture, cx) {
            self.invalidate();
            return None;
        }
        let Some(editor_capture) = EditorCapture::read(&editor, selections, window, cx) else {
            self.invalidate();
            return None;
        };
        if !editor_capture.matches_source(&editor, owner.capture.source(), cx)
            || language_service::position_at(owner.capture.source(), editor_capture.caret).is_err()
        {
            self.invalidate();
            return None;
        }
        if invocation == Invocation::Automatic {
            if self
                .suppressed
                .as_ref()
                .is_some_and(|(capture, selection)| {
                    same_capture(capture, &owner.capture) && *selection == editor_capture
                })
            {
                return None;
            }
            if self.request.as_ref().is_some_and(|request| {
                self.epoch.owns(request.id)
                    && request.same_snapshot(&owner.capture, &editor_capture)
            }) {
                return None;
            }
        }
        self.invalidate();
        self.suppressed = None;
        let request = Request {
            id: self.epoch.advance()?,
            owner,
            editor,
            editor_capture,
        };
        self.pending = true;
        self.request = Some(request.clone());
        Some(request)
    }

    #[allow(clippy::too_many_arguments)]
    pub fn publish(
        &mut self,
        request: &Request,
        help: Option<SignatureHelp>,
        selections: Option<&NativeSelections>,
        window: &mut Window,
        cx: &mut App,
        valid: impl Fn(&DocumentCapture, &App) -> bool,
    ) -> bool {
        if !self.owns_pending(request.id) {
            return false;
        }
        if !request.current(selections, window, cx, &valid) {
            self.invalidate();
            return false;
        }
        self.pending = false;
        self.popup = None;
        let Some(help) = help else {
            return false;
        };
        if !same_capture(request.capture(), &help.capture) || !valid(&help.capture, cx) {
            self.invalidate();
            return false;
        }
        let Some(signatures) = model::Signatures::new(help.signatures, help.active_signature)
        else {
            self.invalidate();
            return false;
        };
        let selected = signatures.active;
        self.popup = Some(Popup {
            signatures: Rc::new(signatures),
            selected,
        });
        true
    }

    /// A failed optional request hides only its own popup; it cannot become a
    /// SQL execution error or erase help belonging to a newer context.
    pub fn failed(&mut self, request: &Request) {
        if self.owns_pending(request.id) {
            self.pending = false;
            self.popup = None;
        }
    }

    fn owns_pending(&self, id: PopupId) -> bool {
        self.pending
            && self.epoch.owns(id)
            && self
                .request
                .as_ref()
                .is_some_and(|request| request.id == id)
    }

    /// Recheck pending as well as visible state. Focus/caret/selection movement
    /// must invalidate before an asynchronous reply or pointer interaction.
    pub fn refresh(
        &mut self,
        selections: Option<&NativeSelections>,
        window: &mut Window,
        cx: &mut App,
        valid: impl Fn(&DocumentCapture, &App) -> bool,
    ) -> bool {
        let current = self.request.as_ref().is_some_and(|request| {
            self.epoch.owns(request.id) && request.current(selections, window, cx, &valid)
        });
        if !current && self.request.is_some() {
            self.invalidate();
        }
        current
    }

    /// Escape can also suppress a still-pending request. Selection and context
    /// changes admit a fresh request; Manual explicitly admits the same snapshot.
    pub fn act(
        &mut self,
        id: PopupId,
        action: PopupAction,
        selections: Option<&NativeSelections>,
        window: &mut Window,
        cx: &mut App,
        valid: impl Fn(&DocumentCapture, &App) -> bool,
    ) -> bool {
        if self.interaction_id() != Some(id) || !self.refresh(selections, window, cx, valid) {
            return false;
        }
        if action == PopupAction::Dismiss {
            if let Some(request) = &self.request {
                self.suppressed = Some((request.capture().clone(), request.editor_capture.clone()));
            }
            self.invalidate();
            return true;
        }
        let Some(popup) = &mut self.popup else {
            return false;
        };
        let Some(selected) = popup.signatures.navigate(popup.selected, action) else {
            return false;
        };
        popup.selected = selected;
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
        let request = self.request.as_ref()?;
        let popup = self.popup.as_ref()?;
        Some(PopupPresentation::new(
            request.id,
            request.editor.clone(),
            popup.signatures.clone(),
            popup.selected,
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
