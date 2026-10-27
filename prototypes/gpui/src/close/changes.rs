//! Close Apply uses a new fresh session and the ordinary exact preview/review.
//! Inline input is projected into an immutable clone, preserving the live editor
//! (including selection, scroll and Undo) if review or any later close cancels.
use super::*;
use changes_view::{Capture, ChangesBatch, Kind};
impl Workspace {
    pub(crate) fn close_apply_valid(&self, token: CloseToken, id: DocumentId) -> bool {
        self.close_valid(token)
            && self
                .close_flow
                .as_ref()
                .is_some_and(|f| f.phase == ClosePhase::ApplyingChanges(id))
    }
    pub(crate) fn close_changes_batch(&self, capture: &Capture, cx: &App) -> Option<ChangesBatch> {
        if !self.changes_valid(capture, true, cx)
            || self.changes_recovery_locked(capture.owner.document)
        {
            return None;
        }
        let g = capture.grid.read(cx).delegate();
        let mut draft = g.draft.as_ref()?.clone();
        if let Some(inline) = &g.inline {
            let policy = grid_changes::ColumnPolicy::new(
                g.original.columns.get(inline.column)?,
                g.metadata.get(inline.column)?,
            );
            let value = match inline.kind {
                Kind::Null => backend::CellValue::Null,
                Kind::Default => backend::CellValue::Default,
                Kind::Value if policy.binary => {
                    backend::CellValue::Binary(inline.editor.read(cx).value().to_string())
                }
                Kind::Value => backend::CellValue::Text(inline.editor.read(cx).value().to_string()),
            };
            if !draft.set(inline.row, inline.column, value) {
                return None;
            }
        }
        let (schema, object) = capture.owner.target.node.object()?;
        let request = draft.request(schema.to_owned(), object.name.clone());
        request.valid().then(|| ChangesBatch {
            capture: capture.clone(),
            request,
        })
    }
    pub(crate) fn choose_close_apply(
        &mut self,
        token: CloseToken,
        id: DocumentId,
        window: &mut Window,
        cx: &mut Context<Self>,
    ) {
        if !self.close_valid(token) || !self.close_drafts_valid(token, cx) {
            self.refuse_close_review(token, ClosePhase::Changes(id), window, cx);
            return;
        }
        let Some(capture) = self
            .close_flow
            .as_ref()
            .unwrap()
            .drafts
            .iter()
            .find(|d| d.document == id && !d.approved)
            .and_then(|d| d.grid.read(cx).delegate().edit_capture(d.grid.clone()))
        else {
            return;
        };
        if capture
            .grid
            .read(cx)
            .delegate()
            .inline
            .as_ref()
            .map(|i| i.editor.clone())
            .is_some_and(|editor| {
                editor.update(cx, |editor, cx| {
                    editor.marked_text_range(window, cx).is_some()
                })
            })
        {
            return;
        }
        if self.close_changes_batch(&capture, cx).is_none() {
            return;
        }
        if !self.transition_close(
            token,
            ClosePhase::Changes(id),
            ClosePhase::ApplyingChanges(id),
        ) {
            return;
        }
        window.close_dialog(cx);
        self.start_close_changes_apply(capture, token, window, cx);
        if self.changes_preview.is_none() {
            self.refuse_close(
                token,
                "Apply could not start. Local changes were preserved.",
                window,
                cx,
            );
        }
    }
    pub(crate) fn close_apply_finished(
        &mut self,
        token: CloseToken,
        id: DocumentId,
        committed: bool,
        window: &mut Window,
        cx: &mut Context<Self>,
    ) {
        if !self.close_apply_valid(token, id) {
            return;
        }
        if !committed {
            self.refuse_close(token,"Apply was not confirmed. Local changes were preserved. Review the outcome before closing or retrying.",window,cx);
            return;
        }
        let Some(flow) = self.close_flow.as_mut() else {
            return;
        };
        for review in flow.drafts.iter_mut().filter(|d| d.document == id) {
            let g = review.grid.read(cx).delegate();
            if let Some(d) = &g.draft {
                review.revision = d.revision;
                review.fingerprint = d.fingerprint.clone();
                review.approved = !g.has_drafts();
            }
        }
        flow.phase = ClosePhase::Reviewing;
        self.resume_close(token, window, cx);
    }
    pub(crate) fn review_unknown_changes(
        &mut self,
        token: CloseToken,
        id: DocumentId,
        window: &mut Window,
        cx: &mut Context<Self>,
    ) {
        self.close_flow.as_mut().unwrap().phase = ClosePhase::UnknownChanges(id);
        let view = cx.entity().downgrade();
        window.open_dialog(cx,move |dialog,_,_| {
            let cancel=view.clone(); let discard=view.clone();
            dialog.title("Unconfirmed changes").accessibility_label("Unconfirmed changes").overlay_closable(false).close_button(false)
                .on_ok({let view=view.clone(); move |_,window,cx| {_=view.update(cx,|this,cx|this.cancel_close_review(token,ClosePhase::UnknownChanges(id),window,cx));false}})
                .on_cancel({let view=view.clone(); move |_,window,cx| {_=view.update(cx,|this,cx|this.cancel_close_review(token,ClosePhase::UnknownChanges(id),window,cx));false}})
                .child("The commit outcome is unknown. Check the database before applying these changes again. Discard the local changes to continue closing. Disconnect does not prove commit or rollback. Retained table documents remain blocked until Inspect Data, Discard and Reload, and a successful reload.")
                .footer(div().flex().gap_2()
                    .child(Button::new("cancel-unknown-changes-close").label("Cancel").on_click(move |_,window,cx| {_=cancel.update(cx,|this,cx|this.cancel_close_review(token,ClosePhase::UnknownChanges(id),window,cx));}))
                    .child(Button::new("discard-unknown-changes-close").label("Discard Local Changes").on_click(move |_,window,cx| {_=discard.update(cx,|this,cx| {
                        if !this.close_drafts_valid(token,cx) {this.refuse_close_review(token,ClosePhase::UnknownChanges(id),window,cx);return;}
                        if this.transition_close(token,ClosePhase::UnknownChanges(id),ClosePhase::Reviewing) {
                            let flow=this.close_flow.as_mut().unwrap();
                            flow.unknown_discards.push(id);
                            for d in flow.drafts.iter_mut().filter(|d|d.document==id) {d.approved=true;}
                            window.close_dialog(cx);
                            this.resume_close(token,window,cx);
                        }
                    });})))
        });
    }
}
