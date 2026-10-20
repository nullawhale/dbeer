//! Production read-only signature adapter for the original retained SQL editor.
//! Source/caret events schedule Go LSP work only; catalog work remains explicit.
use super::*;
use signature_view::{Invocation, PopupAction, PopupId};
use std::rc::Rc;
#[cfg(all(test, feature = "native-smoke"))]
mod tests;

pub(super) struct Ui {
    popup: signature_view::State,
    task: Option<Task<()>>,
    stamp: Option<completion::Stamp>,
    process: Option<u64>,
    pending: bool,
    suppressed: Option<completion::Stamp>,
    epoch: Option<u64>,
}
impl Default for Ui {
    fn default() -> Self {
        Self {
            popup: signature_view::State::default(),
            task: None,
            stamp: None,
            process: None,
            pending: false,
            suppressed: None,
            epoch: Some(0),
        }
    }
}

impl Workspace {
    pub(super) fn dismiss_signatures(&mut self) {
        self.signatures.epoch = self.signatures.epoch.and_then(|epoch| epoch.checked_add(1));
        self.signatures.popup.invalidate();
        self.signatures.task = None;
        self.signatures.stamp = None;
        self.signatures.process = None;
        self.signatures.pending = false;
        // Escape suppression survives invalidation of a pending source sync.
        // A changed native/context stamp or Manual invocation admits help.
    }

    pub(super) fn start_signatures(
        &mut self,
        id: DocumentId,
        invocation: Invocation,
        window: &mut Window,
        cx: &mut Context<Self>,
    ) {
        self.sync_assistance(cx);
        let Some((active, _, _, stamp)) = self.completion_editor(window, cx) else {
            self.dismiss_signatures();
            return;
        };
        if active != id {
            return;
        }
        let process = self.assistance_process_generation(id);
        if invocation == Invocation::Automatic {
            if self.signatures.suppressed.as_ref() == Some(&stamp) {
                return;
            }
            // Includes settled null/failure: do not generate an observer loop.
            if self.signatures.stamp.as_ref() == Some(&stamp) && self.signatures.process == process
            {
                return;
            }
        }
        self.dismiss_signatures();
        let Some(epoch) = self.signatures.epoch else {
            return;
        };
        self.signatures.suppressed = None;
        self.signatures.stamp = Some(stamp.clone());
        self.signatures.process = process;
        self.signatures.pending = true;
        self.signatures.task = Some(cx.spawn_in(window, async move |view, cx| {
            if invocation == Invocation::Automatic {
                cx.background_executor()
                    .timer(signature_view::AUTOMATIC_DELAY)
                    .await;
            }
            // A Change notification may precede the worker's didChange. Bound
            // this wait; retain the original UI stamp before every timer.
            let mut request = None;
            for _ in 0..5 {
                let next = view.update_in(cx, |this, window, cx| {
                    if this.signatures.epoch != Some(epoch)
                        || this.signatures.stamp.as_ref() != Some(&stamp)
                    {
                        return Err(());
                    }
                    let Some((active, editor, native, current)) =
                        this.completion_editor(window, cx)
                    else {
                        this.dismiss_signatures();
                        return Err(());
                    };
                    if active != id
                        || current != stamp
                        || this.assistance_process_generation(id) != process
                    {
                        this.dismiss_signatures();
                        cx.notify();
                        return Err(());
                    }
                    let Some(owner) = this.assistance_request(id, cx) else {
                        return Ok(None);
                    };
                    let mut popup = std::mem::take(&mut this.signatures.popup);
                    let request = popup.request(
                        owner,
                        editor,
                        Some(&native),
                        invocation,
                        window,
                        cx,
                        |capture, cx| this.assistance_capture_current(capture, cx),
                    );
                    this.signatures.popup = popup;
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
                _ = view.update_in(cx, |this, _, _| {
                    if this.signatures.epoch == Some(epoch) {
                        this.signatures.pending = false;
                    }
                });
                return;
            };
            let result = request.help().await;
            _ = view.update_in(cx, |this, window, cx| {
                if this.signatures.epoch != Some(epoch) {
                    return;
                }
                let Some((active, _, native, current)) = this.completion_editor(window, cx) else {
                    this.dismiss_signatures();
                    return;
                };
                if active != id
                    || current != stamp
                    || this.signatures.stamp.as_ref() != Some(&stamp)
                    || this.assistance_process_generation(id) != process
                {
                    this.dismiss_signatures();
                    return;
                }
                let mut popup = std::mem::take(&mut this.signatures.popup);
                match result {
                    Ok(help) => {
                        popup.publish(&request, help, Some(&native), window, cx, |capture, cx| {
                            this.assistance_capture_current(capture, cx)
                        });
                    }
                    Err(_) => popup.failed(&request),
                }
                this.signatures.popup = popup;
                this.signatures.pending = false;
                // Optional help never touches execution status or diagnostics.
                cx.notify();
            });
        }));
    }

    pub(super) fn refresh_signatures(&mut self, window: &mut Window, cx: &mut Context<Self>) {
        let Some((id, _, _, _)) = self.completion_editor(window, cx) else {
            self.dismiss_signatures();
            return;
        };
        self.start_signatures(id, Invocation::Automatic, window, cx);
    }

    /// Escape also owns the debounce interval before State has an interaction id.
    /// A completion-only Escape suppresses signatures for this same snapshot.
    pub(super) fn signature_escape(
        &mut self,
        completion: bool,
        window: &mut Window,
        cx: &mut Context<Self>,
    ) -> bool {
        let Some((_, _, native, stamp)) = self.completion_editor(window, cx) else {
            self.dismiss_signatures();
            return false;
        };
        let active = self.signatures.stamp.as_ref() == Some(&stamp)
            && (self.signatures.pending || self.signatures.popup.interaction_id().is_some());
        if !active && !completion {
            return false;
        }
        if let Some(id) = self.signatures.popup.interaction_id() {
            let mut popup = std::mem::take(&mut self.signatures.popup);
            popup.act(
                id,
                PopupAction::Dismiss,
                Some(&native),
                window,
                cx,
                |capture, cx| self.assistance_capture_current(capture, cx),
            );
            self.signatures.popup = popup;
        }
        self.dismiss_signatures();
        self.signatures.suppressed = Some(stamp);
        true
    }

    fn signature_act(
        &mut self,
        id: PopupId,
        action: PopupAction,
        window: &mut Window,
        cx: &mut Context<Self>,
    ) -> bool {
        let Some((document, _, native, stamp)) = self.completion_editor(window, cx) else {
            self.dismiss_signatures();
            return false;
        };
        if self.signatures.stamp.as_ref() != Some(&stamp)
            || self.signatures.process != self.assistance_process_generation(document)
        {
            self.dismiss_signatures();
            return false;
        }
        let mut popup = std::mem::take(&mut self.signatures.popup);
        let accepted = popup.act(id, action, Some(&native), window, cx, |capture, cx| {
            self.assistance_capture_current(capture, cx)
        });
        self.signatures.popup = popup;
        if accepted && action == PopupAction::Dismiss {
            self.dismiss_signatures();
            self.signatures.suppressed = Some(stamp);
        }
        cx.notify();
        accepted
    }

    pub(super) fn signature_overlay(
        &mut self,
        window: &mut Window,
        cx: &mut Context<Self>,
    ) -> Option<AnyElement> {
        self.refresh_signatures(window, cx);
        let (_, _, native, _) = self.completion_editor(window, cx)?;
        let mut popup = std::mem::take(&mut self.signatures.popup);
        let presentation = popup.presentation(Some(&native), window, cx, |capture, cx| {
            self.assistance_capture_current(capture, cx)
        });
        self.signatures.popup = popup;
        let presentation = presentation?;
        let weak = cx.weak_entity();
        let handler = Rc::new(move |id, action, window: &mut Window, cx: &mut App| {
            _ = weak.update(cx, |this, cx| {
                this.signature_act(id, action, window, cx);
            });
        });
        let weak = cx.weak_entity();
        let guard = Rc::new(move |id, window: &mut Window, cx: &mut App| {
            weak.update(cx, |this, cx| {
                let Some((document, _, native, stamp)) = this.completion_editor(window, cx) else {
                    this.dismiss_signatures();
                    return false;
                };
                if this.signatures.stamp.as_ref() != Some(&stamp)
                    || this.signatures.process != this.assistance_process_generation(document)
                {
                    this.dismiss_signatures();
                    return false;
                }
                let mut popup = std::mem::take(&mut this.signatures.popup);
                let current = popup
                    .presentation(Some(&native), window, cx, |capture, cx| {
                        this.assistance_capture_current(capture, cx)
                    })
                    .is_some_and(|presentation| presentation.id() == id);
                this.signatures.popup = popup;
                current
            })
            .unwrap_or(false)
        });
        Some(presentation.render(self.editor_palette(cx), handler, guard))
    }
}
