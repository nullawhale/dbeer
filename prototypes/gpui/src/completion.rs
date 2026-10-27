//! Production retained-editor adapter. SQL decisions remain in the Go service.
use super::*;
use completion_view::{Invocation, NativeSelection, NativeSelections, PopupAction, PopupId};
use std::{collections::HashMap, rc::Rc};
#[cfg(all(test, feature = "native-smoke"))]
pub(super) mod tests;

pub(super) struct Ui {
    popup: completion_view::State,
    task: Option<Task<()>>,
    stamp: Option<Stamp>,
    visible: bool,
    was_visible: bool,
    epoch: Option<u64>,
    diagnostics: HashMap<DocumentId, completion_view::Diagnostics>,
}
impl Default for Ui {
    fn default() -> Self {
        Self {
            popup: completion_view::State::default(),
            task: None,
            stamp: None,
            visible: false,
            was_visible: false,
            epoch: Some(0),
            diagnostics: HashMap::new(),
        }
    }
}

#[derive(Clone, PartialEq, Eq)]
pub(super) struct Stamp {
    document: DocumentId,
    editor: EntityId,
    source_revision: u64,
    selection_revision: u64,
    profile: ProfileId,
    settings: Option<ConnectionProfile>,
    service_generation: Option<(u64, u64)>,
    catalog_revision: u64,
    assistance_revision: u64,
}

pub(super) fn selections(editor: &Entity<EditorState>, cx: &App) -> Option<NativeSelections> {
    let snapshot = editor.read(cx).completion_selection_snapshot()?;
    Some(NativeSelections {
        editor: editor.entity_id(),
        document_revision: snapshot.document_revision,
        selection_revision: snapshot.selection_revision,
        selections: snapshot
            .selections
            .into_iter()
            .map(|selection| NativeSelection {
                anchor: selection.anchor,
                head: selection.head,
            })
            .collect(),
    })
}

fn atomic_edit(
    editor: &mut EditorState,
    range: std::ops::Range<usize>,
    text: &str,
    window: &mut Window,
    cx: &mut Context<EditorState>,
) {
    editor.replace_completion_text(range, text, window, cx);
}

impl Workspace {
    pub(super) fn completion_popup_visible(&self) -> bool {
        self.completion.visible
    }
    pub(super) fn dismiss_completion(&mut self) {
        self.completion.epoch = self.completion.epoch.and_then(|epoch| epoch.checked_add(1));
        self.completion.popup.dismiss();
        self.completion.task = None;
        self.completion.stamp = None;
        self.completion.visible = false;
    }

    pub(super) fn completion_source_changed(&mut self, id: DocumentId, cx: &mut App) {
        self.completion.was_visible = self.completion.visible;
        self.dismiss_completion();
        if let Some(mut diagnostics) = self.completion.diagnostics.remove(&id) {
            diagnostics.clear(cx);
        }
    }

    /// Shared modal ownership plus original native editor evidence. No helper,
    /// connection, credentials, SQL session or execution availability is needed.
    pub(super) fn completion_editor(
        &self,
        window: &mut Window,
        cx: &mut App,
    ) -> Option<(DocumentId, Entity<EditorState>, NativeSelections, Stamp)> {
        if self.closing
            || !window.is_window_active()
            || self.close_flow.is_some()
            || window.has_active_dialog(cx)
            || window.has_active_prompt()
            || self.file_request.is_some()
            || self.export_request.is_some()
            || self.run_file.is_some()
            || self.transfer_task.is_some()
            || self
                .transfer_review
                .as_ref()
                .is_some_and(|review| review.read(cx).is_active())
            || self.changes_preview.is_some()
            || self
                .profile_editor
                .as_ref()
                .is_some_and(|editor| editor.read(cx).is_active())
        {
            return None;
        }
        let tab = self.tabs.get(self.active)?;
        if tab.kind != model::DocumentKind::Sql {
            return None;
        }
        let native = selections(&tab.editor, cx)?;
        // Reads actual focus, marked text and the full native selection set.
        completion_view::EditorCapture::read(&tab.editor, Some(&native), window, cx)?;
        let stamp = Stamp {
            document: tab.id,
            editor: native.editor,
            source_revision: native.document_revision,
            selection_revision: native.selection_revision,
            profile: tab.profile.clone(),
            settings: self
                .profiles
                .iter()
                .find(|profile| profile.id == tab.profile)
                .and_then(|profile| profile.config.clone()),
            service_generation: self
                .profiles
                .iter()
                .find(|profile| profile.id == tab.profile)
                .map(|profile| (profile.generation, profile.service_generation)),
            catalog_revision: self.completion_snapshot(&tab.profile).0,
            assistance_revision: self.assistance.revision,
        };
        Some((tab.id, tab.editor.clone(), native, stamp))
    }

    pub(super) fn completion_typed(
        &mut self,
        id: DocumentId,
        inserted: &str,
        window: &mut Window,
        cx: &mut Context<Self>,
    ) {
        let was_visible = std::mem::take(&mut self.completion.was_visible);
        if completion_view::automatic_trigger(inserted, was_visible)
            && self.tabs.get(self.active).is_some_and(|tab| tab.id == id)
        {
            self.start_completion(id, Invocation::Automatic, window, cx);
        }
    }

    pub(super) fn start_completion(
        &mut self,
        id: DocumentId,
        invocation: Invocation,
        window: &mut Window,
        cx: &mut Context<Self>,
    ) {
        self.dismiss_completion();
        let Some(epoch) = self.completion.epoch else {
            return;
        };
        self.sync_assistance(cx);
        let Some((active, _, _, stamp)) = self.completion_editor(window, cx) else {
            return;
        };
        if active != id {
            return;
        }
        self.completion.stamp = Some(stamp.clone());
        self.completion.task = Some(cx.spawn_in(window, async move |view, cx| {
            if invocation == Invocation::Automatic {
                cx.background_executor()
                    .timer(Duration::from_millis(120))
                    .await;
            }
            // Source synchronization is asynchronous on the sole LSP worker.
            // Bound the wait and retain the original native caret/focus epoch.
            let mut request = None;
            for _ in 0..5 {
                let next = view.update_in(cx, |this, window, cx| {
                    if this.completion.epoch != Some(epoch)
                        || this.completion.stamp.as_ref() != Some(&stamp)
                    {
                        return Err(());
                    }
                    let Some((active, editor, native, current)) =
                        this.completion_editor(window, cx)
                    else {
                        this.dismiss_completion();
                        return Err(());
                    };
                    if active != id || current != stamp {
                        this.dismiss_completion();
                        return Err(());
                    }
                    let Some(owner) = this.assistance_request(id, cx) else {
                        return Ok(None);
                    };
                    let mut popup = std::mem::take(&mut this.completion.popup);
                    let request = popup.request(
                        owner,
                        editor,
                        Some(&native),
                        invocation,
                        window,
                        cx,
                        |capture, cx| this.assistance_capture_current(capture, cx),
                    );
                    this.completion.popup = popup;
                    Ok(request)
                });
                match next {
                    Ok(Ok(Some(next))) => {
                        request = Some(next);
                        break;
                    }
                    Ok(Ok(None)) => {
                        cx.background_executor()
                            .timer(Duration::from_millis(40))
                            .await
                    }
                    _ => return,
                }
            }
            let Some(request) = request else {
                return;
            };
            let result = request.complete().await;
            _ = view.update_in(cx, |this, window, cx| {
                if this.completion.epoch != Some(epoch) {
                    return;
                }
                let Some((active, _, native, current)) = this.completion_editor(window, cx) else {
                    this.dismiss_completion();
                    return;
                };
                if active != id
                    || current != stamp
                    || this.completion.stamp.as_ref() != Some(&stamp)
                {
                    this.dismiss_completion();
                    return;
                }
                let mut popup = std::mem::take(&mut this.completion.popup);
                this.completion.visible = match result {
                    Ok(batch) => {
                        popup.publish(&request, batch, Some(&native), window, cx, |capture, cx| {
                            this.assistance_capture_current(capture, cx)
                        })
                    }
                    Err(_) => {
                        popup.failed(&request);
                        false
                    }
                };
                this.completion.popup = popup;
                // Optional assistance never mutates query status/error marks.
                cx.notify();
            });
        }));
        cx.notify();
    }

    fn completion_act(
        &mut self,
        id: PopupId,
        action: PopupAction,
        window: &mut Window,
        cx: &mut Context<Self>,
    ) -> bool {
        let Some((_, _, native, stamp)) = self.completion_editor(window, cx) else {
            self.dismiss_completion();
            return false;
        };
        if self.completion.stamp.as_ref() != Some(&stamp) {
            self.dismiss_completion();
            return false;
        }
        let mut popup = std::mem::take(&mut self.completion.popup);
        let accepted = popup.act(
            id,
            action,
            Some(&native),
            atomic_edit,
            window,
            cx,
            |capture, cx| self.assistance_capture_current(capture, cx),
        );
        self.completion.popup = popup;
        if matches!(
            action,
            PopupAction::Accept | PopupAction::Choose(_) | PopupAction::Dismiss
        ) {
            self.completion.visible = false;
            self.completion.stamp = None;
            self.completion.task = None;
        }
        cx.notify();
        accepted
    }

    /// Capture phase runs before the retained input's Tab/Enter/navigation.
    /// Unproven native composition/dead-key evidence always passes through.
    pub(super) fn completion_key(
        &mut self,
        event: &KeyDownEvent,
        window: &mut Window,
        cx: &mut Context<Self>,
    ) {
        let Some((_, editor, native, stamp)) = self.completion_editor(window, cx) else {
            self.dismiss_completion();
            self.dismiss_signatures();
            return;
        };
        let marked = editor.update(cx, |state, cx| {
            if state.marked_text_range(window, cx).is_some() {
                shortcuts::Evidence::Active
            } else {
                shortcuts::Evidence::Clear
            }
        });
        let safety = shortcuts::InputSafety::from_gpui(event, marked);
        let modifiers = event.keystroke.modifiers;
        if event.keystroke.key == "space"
            && modifiers.control
            && !modifiers.alt
            && !modifiers.platform
            && !modifiers.shift
            && !event.is_held
            && !event.prefer_character_input
            && safety.marked_text == shortcuts::Evidence::Clear
            && safety.dead_key == shortcuts::Evidence::Clear
        {
            self.command(
                CommandId::Complete,
                CommandOrigin::Shortcut,
                None,
                window,
                cx,
            );
            window.prevent_default();
            cx.stop_propagation();
            return;
        }
        let Some(action) = PopupAction::from_native(event, safety) else {
            return;
        };
        if action == PopupAction::Dismiss {
            let completion = self.completion.stamp.as_ref() == Some(&stamp);
            let signature = self.signature_escape(completion, window, cx);
            if completion || signature {
                self.dismiss_completion();
                window.prevent_default();
                cx.stop_propagation();
                cx.notify();
            }
            return;
        }
        let mut popup = std::mem::take(&mut self.completion.popup);
        let presentation = popup.presentation(Some(&native), window, cx, |capture, cx| {
            self.assistance_capture_current(capture, cx)
        });
        self.completion.popup = popup;
        if let Some(presentation) = presentation
            && self.completion_act(presentation.id(), action, window, cx)
        {
            window.prevent_default();
            cx.stop_propagation();
        }
    }

    pub(super) fn completion_selection_changed(
        &mut self,
        window: &mut Window,
        cx: &mut Context<Self>,
    ) {
        if self.completion.stamp.is_some() {
            if self
                .completion_editor(window, cx)
                .is_none_or(|(_, _, _, stamp)| self.completion.stamp.as_ref() != Some(&stamp))
            {
                self.dismiss_completion();
            }
            cx.notify();
        }
    }

    pub(super) fn completion_overlay(
        &mut self,
        window: &mut Window,
        cx: &mut Context<Self>,
    ) -> Option<AnyElement> {
        self.refresh_syntax_diagnostics(cx);
        let Some((_, _, native, stamp)) = self.completion_editor(window, cx) else {
            self.dismiss_completion();
            return None;
        };
        if self.completion.stamp.as_ref() != Some(&stamp) {
            self.dismiss_completion();
            return None;
        }
        let mut popup = std::mem::take(&mut self.completion.popup);
        let presentation = popup.presentation(Some(&native), window, cx, |capture, cx| {
            self.assistance_capture_current(capture, cx)
        });
        self.completion.popup = popup;
        let presentation = presentation?;
        let weak = cx.weak_entity();
        let handler = Rc::new(move |id, action, window: &mut Window, cx: &mut App| {
            _ = weak.update(cx, |this, cx| {
                this.completion_act(id, action, window, cx);
            });
        });
        let weak = cx.weak_entity();
        let guard = Rc::new(move |id, window: &mut Window, cx: &mut App| {
            weak.update(cx, |this, cx| {
                let Some((_, _, native, stamp)) = this.completion_editor(window, cx) else {
                    return false;
                };
                if this.completion.stamp.as_ref() != Some(&stamp) {
                    return false;
                }
                let mut popup = std::mem::take(&mut this.completion.popup);
                let current = popup
                    .presentation(Some(&native), window, cx, |capture, cx| {
                        this.assistance_capture_current(capture, cx)
                    })
                    .is_some_and(|presentation| presentation.id() == id);
                this.completion.popup = popup;
                current
            })
            .unwrap_or(false)
        });
        Some(presentation.render(self.editor_palette(cx), handler, guard))
    }

    fn refresh_syntax_diagnostics(&mut self, cx: &mut Context<Self>) {
        let mut diagnostics = std::mem::take(&mut self.completion.diagnostics);
        diagnostics.retain(|id, owner| {
            let Some(tab) = self.tabs.iter().find(|tab| tab.id == *id) else {
                owner.clear(cx);
                return false;
            };
            owner.refresh(cx, |capture, cx| {
                self.assistance_capture_current(capture, cx)
            });
            if tab.kind != model::DocumentKind::Sql {
                owner.clear(cx);
                return false;
            }
            true
        });
        for tab in self
            .tabs
            .iter()
            .filter(|tab| tab.kind == model::DocumentKind::Sql)
        {
            if let Some(batch) = self.assistance.diagnostics.get(&tab.persistent_id) {
                diagnostics.entry(tab.id).or_default().publish(
                    &tab.editor,
                    batch,
                    cx,
                    |capture, cx| self.assistance_capture_current(capture, cx),
                );
            }
        }
        self.completion.diagnostics = diagnostics;
    }
}
