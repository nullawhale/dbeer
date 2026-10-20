//! Maintained common-graph hook for Task 29's owned GNOME registration.
//! No session-manager signal invokes Quit or opens UI. Production startup
//! attaches the real adapter in Task 29; disposable headless work never does.
use super::*;
impl Workspace {
    pub(crate) fn publish_close_readiness(&self) {
        #[cfg(target_os = "linux")]
        if let Some(client) = &self.session_end_readiness {
            let snapshot = client.snapshot();
            let readiness = self
                .close_flow
                .as_ref()
                .map_or(session_end::CloseReadiness::Absent, |f| {
                    session_end::CloseReadiness::Waiting(session_end::CommonCloseToken(f.token.0))
                });
            _ = client.set(snapshot.generation, readiness);
        }
    }
    #[cfg(target_os = "linux")]
    pub(crate) fn start_desktop_session(&mut self, window: &mut Window, cx: &mut Context<Self>) {
        let startup_id = std::env::var("DESKTOP_AUTOSTART_ID").unwrap_or_default();
        if let Ok(client) = session_end::Client::start(startup_id) {
            self.attach_session_end(client, window, cx);
        }
    }
    #[cfg(target_os = "linux")]
    pub(crate) fn attach_session_end(
        &mut self,
        client: session_end::Client,
        window: &mut Window,
        cx: &mut Context<Self>,
    ) -> bool {
        if self.closing || self.session_end.is_some() {
            return false;
        }
        let events = client.events();
        self.session_end_readiness = Some(client.publisher());
        self.session_end = Some(client);
        self.publish_close_readiness();
        self.session_end_task = Some(cx.spawn_in(window, async move |view, cx| {
            while let Ok(event) = events.recv().await {
                _ = view.update_in(cx, |this, _, _| {
                    // Registration/reconnection owns a NEW generation. Publish
                    // only current common Waiting/Absent; no old Ready survives.
                    // Cancelled invalidates the OS association inside the adapter
                    // and does not replace an independently selected resolution.
                    if matches!(event, session_end::Event::Availability { .. }) {
                        this.publish_close_readiness();
                    }
                    // Response is informational; Forced supplies no terminal,
                    // commit/rollback, draft flush or reviewed-exit evidence.
                });
            }
            // Closure/loss grants nothing. Clear only OS readiness, preserving
            // any user's independently selected Commit/Rollback/Stop resolution.
            _ = view.update_in(cx, |this, _, _| {
                if let Some(client) = &this.session_end_readiness {
                    _ = client.set(
                        client.snapshot().generation,
                        session_end::CloseReadiness::Absent,
                    );
                }
            });
        }));
        true
    }
    pub(crate) fn shutdown_close_platform(
        &mut self,
        evidence: TerminalEvidence,
        window: &mut Window,
        cx: &mut Context<Self>,
    ) -> bool {
        let token = evidence.token;
        #[cfg(target_os = "linux")]
        if self.close_valid(token)
            && self.close_drafts_valid(token, cx)
            && self.close_finalizers_current(token, cx)
            && self.snapshot_after_close(cx) == evidence.snapshot
            && self.close_flow.as_ref().is_some_and(|f| {
                f.token == token
                    && f.phase == ClosePhase::Finishing
                    && f.helpers_finished
                    && matches!(f.intent, CloseIntent::Window)
            })
            && let Some(client) = self.session_end.take()
        {
            // All helpers, original disconnect ACKs, current participant saves
            // and the latest document flush have ALREADY completed. The common
            // token remains owned in Finishing; the adapter grants no exit.
            _ = client.set_readiness(
                client.snapshot().generation,
                session_end::CloseReadiness::Ready(session_end::CommonCloseToken(token.0)),
            );
            // Unregister our own exact generation/path while the common
            // token still owns terminal Finishing. Unreviewed requests refuse
            // within their noninteractive deadlines. No required persistence or
            // helper work remains after this bounded owned teardown.
            let snapshot = evidence.snapshot;
            self.session_end_task = None;
            self.closing_task = Some(cx.spawn_in(window, async move |view, cx| {
                client.shutdown().await;
                _ = view.update_in(cx, |this, window, cx| {
                    if this.close_valid(token) {
                        if this.snapshot_after_close(cx) == snapshot
                            && this.close_finalizers_current(token, cx)
                        {
                            // No required flush follows Ready: this is only the
                            // original terminal graph's removal continuation.
                            this.complete_terminal_close(token, window, cx);
                        } else {
                            this.publish_close_readiness();
                            this.flush_close_documents(token, window, cx);
                        }
                    }
                });
            }));
            return true;
        }
        #[cfg(not(target_os = "linux"))]
        let _ = (token, evidence.snapshot, window, cx);
        false
    }
}
impl Workspace {
    pub(crate) fn shutdown_close_helpers(
        &mut self,
        token: CloseToken,
        window: &mut Window,
        cx: &mut Context<Self>,
    ) -> bool {
        let Some(flow) = self.close_flow.as_ref().filter(|f| {
            f.token == token && matches!(f.intent, CloseIntent::Window) && !f.helpers_finished
        }) else {
            return false;
        };
        let mut clients = Vec::<BackendClient>::new();
        for client in flow
            .helpers
            .iter()
            .cloned()
            .chain(self.backend.iter().cloned())
            .chain(self.tabs.iter().filter_map(|t| {
                t.session_client()
                    .or_else(|| t.run_file_recovery.as_ref().and_then(|r| r.client.clone()))
            }))
            .chain(
                self.profiles
                    .iter()
                    .filter_map(|p| p.session_client.clone()),
            )
        {
            if !clients.iter().any(|c| c.same_instance(&client)) {
                clients.push(client);
            }
        }
        self.closing_task=Some(cx.spawn_in(window,async move |view,cx| {
            for client in clients {
                if !view.update_in(cx,|this,_,_|this.close_valid(token)).unwrap_or(false) {return;}
                if client.await_owned_exit().await.is_err() {
                    _=view.update_in(cx,|this,window,cx|this.refuse_close(token,"The owned helper has not completed teardown. Local drafts were preserved.",window,cx));return;
                }
            }
            _=view.update_in(cx,|this,window,cx| {
                if !this.close_valid(token) {return;}
                this.close_flow.as_mut().unwrap().helpers_finished=true;
                this.flush_close_documents(token,window,cx);
            });
        }));
        true
    }
}
