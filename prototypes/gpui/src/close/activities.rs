//! Captured owners drain their original futures; close never retargets them.
use super::*;
impl Workspace {
    pub(crate) fn close_activities(&self) -> Vec<Activity> {
        let mut owners = Vec::new();
        if let Some(r) = &self.file_request {
            owners.push(Activity::File(r.token));
        }
        if let Some(r) = &self.export_request {
            owners.push(Activity::Export(r.token));
        }
        if let Some(r) = &self.run_file {
            owners.push(Activity::RunFile(r.token));
        }
        if let Some(r) = &self.changes_preview {
            owners.push(Activity::Changes(r.token));
        }
        owners
    }
    pub(crate) fn close_owns_activity(&self, owner: Activity) -> bool {
        self.close_flow.as_ref().is_some_and(|f| {
            f.activities.contains(&owner)
                && matches!(
                    f.phase,
                    ClosePhase::Reviewing
                        | ClosePhase::OwnersReview
                        | ClosePhase::OwnersWaiting
                        | ClosePhase::OwnersStopping
                )
        })
    }
    fn close_activity_affected(&self, owner: Activity) -> bool {
        let Some(flow) = &self.close_flow else {
            return false;
        };
        let document = match owner {
            Activity::File(_) => {
                return self.file_activity_target().is_some_and(|(doc, profile)| {
                    doc.is_some_and(|id| flow.contains(id))
                        || matches!(flow.intent, CloseIntent::Window)
                        || flow.intent.profile_id() == Some(profile)
                });
            }
            Activity::Export(_) => self.export_activity_document(),
            Activity::RunFile(_) => self
                .run_file
                .as_ref()
                .and_then(|f| f.capture.document.as_ref())
                .map(|d| d.id),
            Activity::Changes(_) => self
                .changes_preview
                .as_ref()
                .map(preview_view::Flow::document),
        };
        document.is_some_and(|id| flow.contains(id))
    }
    pub(crate) fn close_pending_activities(&self, token: CloseToken) -> bool {
        self.close_flow.as_ref().is_some_and(|f| {
            f.token == token
                && self
                    .close_activities()
                    .iter()
                    .any(|owner| f.activities.contains(owner))
        })
    }
    pub(crate) fn review_close_activities(
        &mut self,
        token: CloseToken,
        window: &mut Window,
        cx: &mut Context<Self>,
    ) {
        if window.has_active_dialog(cx) || window.has_active_prompt() {
            self.wait_close_activities(token, false, window, cx);
            return;
        }
        self.close_flow.as_mut().unwrap().phase = ClosePhase::OwnersReview;
        let view = cx.entity().downgrade();
        window.open_dialog(cx, move |dialog,_,_| {
            let cancel = view.clone(); let stop = view.clone(); let wait = view.clone();
            dialog.title("Work is still in progress").accessibility_label("Work is still in progress").overlay_closable(false).close_button(false)
                .on_ok({let view=view.clone(); move |_,window,cx| {_=view.update(cx,|this,cx|this.cancel_close_review(token,ClosePhase::OwnersReview,window,cx));false}})
                .on_cancel({let view=view.clone(); move |_,window,cx| {_=view.update(cx,|this,cx|this.cancel_close_review(token,ClosePhase::OwnersReview,window,cx));false}})
                .child("Wait for the original file, export or changes operation, or Stop and await its final outcome and session cleanup. Completed changes and published files remain applied. Cancel keeps this workspace open.")
                .footer(div().flex().gap_2()
                    .child(Button::new("cancel-owner-close").label("Cancel").on_click(move |_,window,cx| {_=cancel.update(cx,|this,cx|this.cancel_close_review(token,ClosePhase::OwnersReview,window,cx));}))
                    .child(Button::new("wait-owner-close").label("Wait and Continue").on_click(move |_,window,cx| {_=wait.update(cx,|this,cx|this.choose_close_activities(token,false,window,cx));}))
                    .child(Button::new("stop-owner-close").label("Stop and Continue").on_click(move |_,window,cx| {_=stop.update(cx,|this,cx|this.choose_close_activities(token,true,window,cx));})))
        });
    }
    fn choose_close_activities(
        &mut self,
        token: CloseToken,
        stop: bool,
        window: &mut Window,
        cx: &mut Context<Self>,
    ) {
        if !self.transition_close(token, ClosePhase::OwnersReview, ClosePhase::OwnersStopping) {
            return;
        }
        window.close_dialog(cx);
        if stop {
            let owners = self.close_flow.as_ref().unwrap().activities.clone();
            for owner in owners {
                if !self.close_activity_affected(owner) {
                    continue;
                }
                match owner {
                    Activity::File(token) => {
                        if let Some(r) = self.file_request.as_mut().filter(|r| r.token == token) {
                            r.cancelled = true;
                        }
                    }
                    Activity::Export(token) => {
                        if let Some(r) = self.export_request.as_mut().filter(|r| r.token == token) {
                            r.cancelled = true;
                        }
                    }
                    Activity::RunFile(token) => {
                        if let Some(id) = self
                            .run_file
                            .as_ref()
                            .filter(|r| r.token == token)
                            .and_then(|r| r.capture.document.as_ref())
                            .map(|d| d.id)
                        {
                            self.stop_document(id, cx);
                        }
                    }
                    Activity::Changes(token) => {
                        self.stop_changes_for_close(token, window, cx);
                    }
                }
            }
        }
        // Both explicit Wait and Stop await terminal publication/cleanup. This
        // selected resolution cannot be replaced by a later system close.
        self.wait_close_activities(token, true, window, cx);
    }
    pub(crate) fn wait_close_activities(
        &mut self,
        token: CloseToken,
        selected: bool,
        window: &mut Window,
        cx: &mut Context<Self>,
    ) {
        self.close_flow.as_mut().unwrap().phase = if selected {
            ClosePhase::OwnersStopping
        } else {
            ClosePhase::OwnersWaiting
        };
        self.closing_task=Some(cx.spawn_in(window,async move |view,cx| {
            loop {
                let ready=view.update_in(cx,|this,window,cx| {
                    if !this.close_valid(token) {return None;}
                    if this.close_changes_cleanup_failed() {
                        this.refuse_close(token,"Changes-session teardown was not acknowledged. The original flow and drafts remain available; retry its cleanup before closing.",window,cx);
                        return None;
                    }
                    let pending=this.close_pending_activities(token);
                    Some((!pending || !selected) && !window.has_active_dialog(cx) && !window.has_active_prompt())
                }).ok().flatten();
                match ready {Some(false)=>{},_=>break}
                cx.background_executor().timer(Duration::from_millis(30)).await;
            }
            _=view.update_in(cx,|this,window,cx| {
                if !this.close_valid(token) {this.refuse_close(token,"The captured close context changed while waiting.",window,cx);return;}
                this.closing_task=None;
                if !this.close_pending_activities(token) {
                    // An authoritative Apply may have cleared its committed draft.
                    // Recapture only before any close-owned draft decision exists.
                    this.capture_close_drafts(cx);
                }
                this.close_flow.as_mut().unwrap().phase=ClosePhase::Reviewing;
                this.resume_close(token,window,cx);
            });
        }));
        cx.notify();
    }
    pub(crate) fn capture_close_drafts(&mut self, cx: &App) {
        let Some(flow) = self.close_flow.as_mut() else {
            return;
        };
        flow.drafts = self
            .tabs
            .iter()
            .filter(|t| flow.contains(t.id))
            .flat_map(|tab| {
                tab.grid_views.values().filter_map(|grid| {
                    let g = grid.read(cx).delegate();
                    let d = g.draft.as_ref()?;
                    Some(DraftReview {
                        document: tab.id,
                        grid: grid.clone(),
                        fingerprint: d.fingerprint.clone(),
                        revision: d.revision,
                        approved: !g.has_drafts(),
                    })
                })
            })
            .collect();
    }
}
impl Workspace {
    pub(crate) fn close_catalog_busy(&self, token: CloseToken) -> bool {
        self.close_flow.as_ref().is_some_and(|f| {
            f.token == token
                && self.profiles.iter().any(|p| {
                    p.task.is_some()
                        && (matches!(f.intent, CloseIntent::Window)
                            || f.intent.profile_id().as_ref() == Some(&p.id)
                            || self.tabs.iter().any(|t| {
                                f.contains(t.id)
                                    && t.profile == p.id
                                    && t.catalog_document.as_ref().is_some_and(|d| d.loading)
                            }))
                })
        })
    }
    pub(crate) fn review_close_catalog(
        &mut self,
        token: CloseToken,
        window: &mut Window,
        cx: &mut Context<Self>,
    ) {
        self.close_flow.as_mut().unwrap().phase = ClosePhase::CatalogReview;
        let view = cx.entity().downgrade();
        window.open_dialog(cx,move |dialog,_,_| {
            let cancel=view.clone();let wait=view.clone();
            dialog.title("Catalog work is in progress").accessibility_label("Catalog work is in progress").overlay_closable(false).close_button(false)
                .on_ok({let view=view.clone();move |_,window,cx|{_=view.update(cx,|this,cx|this.cancel_close_review(token,ClosePhase::CatalogReview,window,cx));false}})
                .on_cancel({let view=view.clone();move |_,window,cx|{_=view.update(cx,|this,cx|this.cancel_close_review(token,ClosePhase::CatalogReview,window,cx));false}})
                .child("Wait for the original catalog request before closing its session. Cancel leaves the workspace open.")
                .footer(div().flex().gap_2()
                    .child(Button::new("cancel-catalog-close").label("Cancel").on_click(move |_,window,cx|{_=cancel.update(cx,|this,cx|this.cancel_close_review(token,ClosePhase::CatalogReview,window,cx));}))
                    .child(Button::new("wait-catalog-close").label("Wait and Continue").on_click(move |_,window,cx|{_=wait.update(cx,|this,cx|this.wait_close_catalog(token,window,cx));})))
        });
    }
    fn wait_close_catalog(
        &mut self,
        token: CloseToken,
        window: &mut Window,
        cx: &mut Context<Self>,
    ) {
        if !self.transition_close(token, ClosePhase::CatalogReview, ClosePhase::CatalogWaiting) {
            return;
        }
        window.close_dialog(cx);
        self.closing_task = Some(cx.spawn_in(window, async move |view, cx| {
            loop {
                if !view
                    .update_in(cx, |this, _, _| {
                        this.close_valid(token) && this.close_catalog_busy(token)
                    })
                    .unwrap_or(false)
                {
                    break;
                }
                cx.background_executor()
                    .timer(Duration::from_millis(30))
                    .await;
            }
            _ = view.update_in(cx, |this, window, cx| {
                if !this.transition_close(token, ClosePhase::CatalogWaiting, ClosePhase::Reviewing)
                {
                    this.refuse_close(
                        token,
                        "The catalog context changed while closing. Local drafts were preserved.",
                        window,
                        cx,
                    );
                    return;
                }
                this.closing_task = None;
                this.resume_close(token, window, cx);
            });
        }));
    }
}
