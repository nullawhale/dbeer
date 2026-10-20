//! Purpose-bound finalization hooks. Later assistance/preferences integrations
//! register their actual retained owners here instead of widening SQL snapshots.
#![allow(dead_code)] // Actual LSP/preferences owners register in Tasks 23/26-28.
use super::*;
use std::{future::Future, pin::Pin};
#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub(crate) enum FinalizerKind {
    LanguageService,
    Appearance,
    ThemeLibrary,
    Shortcuts,
    #[cfg(test)]
    TestPreference,
}
#[derive(Clone)]
pub(crate) struct FinalizationContext {
    pub token: CloseToken,
    pub intent: CloseIntent,
    pub documents: Vec<DocumentId>,
}
pub(crate) struct FinalizationJob {
    pub revision: u64,
    pub future: Pin<Box<dyn Future<Output = Result<(), String>>>>,
}
type Revision = Box<dyn Fn(&Workspace, &App) -> u64>;
type Prepare = Box<dyn Fn(&Workspace, &FinalizationContext, &App) -> FinalizationJob>;
pub(crate) struct Finalizer {
    kind: FinalizerKind,
    revision: Revision,
    prepare: Prepare,
}
// These are concrete integration seams; the later UI integrations own actual
// service/store construction and may register only their original owner.
#[allow(dead_code)]
impl Finalizer {
    pub(crate) fn new(
        kind: FinalizerKind,
        revision: impl Fn(&Workspace, &App) -> u64 + 'static,
        prepare: impl Fn(&Workspace, &FinalizationContext, &App) -> FinalizationJob + 'static,
    ) -> Self {
        Self {
            kind,
            revision: Box::new(revision),
            prepare: Box::new(prepare),
        }
    }
}
impl Workspace {
    #[allow(dead_code)]
    pub(crate) fn register_close_finalizer(&mut self, finalizer: Finalizer) -> bool {
        if self.closing
            || self
                .close_finalizers
                .iter()
                .any(|f| f.kind == finalizer.kind)
        {
            return false;
        }
        self.close_finalizers.push(finalizer);
        true
    }
    pub(crate) fn close_finalizers_current(&self, token: CloseToken, cx: &App) -> bool {
        self.close_flow.as_ref().is_some_and(|flow| {
            flow.token == token
                && self
                    .close_finalizers
                    .iter()
                    .all(|f| flow.finalized.contains(&(f.kind, (f.revision)(self, cx))))
        })
    }
    pub(crate) fn flush_close_participants(
        &mut self,
        token: CloseToken,
        window: &mut Window,
        cx: &mut Context<Self>,
    ) -> bool {
        let Some(flow) = self
            .close_flow
            .as_ref()
            .filter(|f| f.token == token && f.phase == ClosePhase::Finishing)
        else {
            return true;
        };
        let Some(participant) = self
            .close_finalizers
            .iter()
            .find(|f| !flow.finalized.contains(&(f.kind, (f.revision)(self, cx))))
        else {
            return false;
        };
        let context = FinalizationContext {
            token,
            intent: flow.intent.clone(),
            documents: flow.documents.iter().map(|d| d.0).collect(),
        };
        let kind = participant.kind;
        let job = (participant.prepare)(self, &context, cx);
        self.closing_task = Some(cx.spawn_in(window, async move |view, cx| {
            let result = job.future.await;
            _ = view.update_in(cx, |this, window, cx| {
                if !this.close_valid(token)
                    || !this
                        .close_flow
                        .as_ref()
                        .is_some_and(|f| f.phase == ClosePhase::Finishing)
                {
                    return;
                }
                // A superseded/failed OLD job cannot refuse a newer owner any
                // more than an old success can authorize it. Drain that owner.
                if this
                    .close_finalizers
                    .iter()
                    .find(|f| f.kind == kind)
                    .is_none_or(|f| (f.revision)(this, cx) != job.revision)
                {
                    this.flush_close_documents(token, window, cx);
                    return;
                }
                if let Err(error) = result {
                    this.refuse_close(token, &error, window, cx);
                    return;
                }
                let flow = this.close_flow.as_mut().unwrap();
                flow.finalized.retain(|(k, _)| *k != kind);
                flow.finalized.push((kind, job.revision));
                // A later preference edit must flush the latest revision, never
                // authorize exit from an earlier successful write.
                this.flush_close_documents(token, window, cx);
            });
        }));
        true
    }
}
