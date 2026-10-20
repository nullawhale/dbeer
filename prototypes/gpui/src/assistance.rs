//! Workspace adapter for optional offline assistance. No connection side effects.
mod runtime;
#[cfg(test)]
mod tests;
use super::*;
use language_service::{CatalogSnapshot, ContextKey, DiagnosticsBatch, Dialect, DocumentCapture};
use runtime::Availability;
use std::{
    collections::HashMap,
    hash::{Hash, Hasher},
    sync::Arc,
};

struct Settings {
    value: Option<ConnectionProfile>,
    revision: u64,
}
#[derive(Default)]
pub(super) struct State {
    runtime: Option<runtime::Runtime>,
    task: Option<Task<()>>,
    settings: HashMap<ProfileId, Settings>,
    documents: Vec<runtime::Document>,
    pub revision: u64,
    settings_revision: u64,
    output_revision: u64,
    closing: bool,
    pub diagnostics: HashMap<String, DiagnosticsBatch>,
}
/// Task 24/25 request owner; holds no process/session/credential handle.
#[derive(Clone)]
#[allow(dead_code)] // Consumers are the separately implemented Tasks 24/25.
pub(super) struct RequestOwner {
    runtime: runtime::Runtime,
    pub capture: DocumentCapture,
}
#[allow(dead_code)]
impl RequestOwner {
    pub async fn completion(
        &self,
        offset: usize,
    ) -> language_service::Result<language_service::CompletionBatch> {
        self.runtime.completion(self.capture.clone(), offset).await
    }
    pub async fn signature_help(
        &self,
        offset: usize,
    ) -> language_service::Result<Option<language_service::SignatureHelp>> {
        self.runtime
            .signature_help(self.capture.clone(), offset)
            .await
    }
}
impl Workspace {
    #[cfg(all(test, feature = "native-smoke"))]
    pub(super) fn assistance_fixture(&mut self, path: std::path::PathBuf, cx: &mut Context<Self>) {
        self.dismiss_completion();
        self.dismiss_signatures();
        self.assistance.runtime = Some(runtime::Runtime::start(path));
        self.assistance.documents.clear();
        self.sync_assistance(cx);
    }
    pub(super) fn start_assistance(&mut self, cx: &mut Context<Self>) {
        self.assistance.runtime = Some(runtime::Runtime::start(platform::helper_path()));
        self.register_close_finalizer(close::finalizers::Finalizer::new(
            close::finalizers::FinalizerKind::LanguageService,
            |this, cx| this.assistance_close_revision(cx),
            |this, context, cx| {
                let revision = this.assistance_close_revision(cx);
                let runtime = this.assistance.runtime.clone();
                let ids = context
                    .documents
                    .iter()
                    .filter_map(|id| {
                        this.tabs
                            .iter()
                            .find(|t| t.id == *id && t.kind == model::DocumentKind::Sql)
                            .map(|t| t.persistent_id.clone())
                    })
                    .collect();
                let window = matches!(context.intent, CloseIntent::Window);
                // Construct now so the future retains the exact current URI,
                // version, context and process captures throughout finalization.
                let finalization = runtime.map(|r| r.finalize(ids, window));
                close::finalizers::FinalizationJob {
                    revision,
                    future: Box::pin(async move {
                        if let Some(finalization) = finalization {
                            finalization.await;
                        }
                        Ok(())
                    }),
                }
            },
        ));
        self.sync_assistance(cx);
        self.assistance.task = Some(cx.spawn(async move |view, cx| {
            loop {
                cx.background_executor()
                    .timer(Duration::from_millis(80))
                    .await;
                if view
                    .update(cx, |this, cx| {
                        this.sync_assistance(cx);
                        let Some(runtime) = this.assistance.runtime.clone() else {
                            return;
                        };
                        let (revision, availability) = runtime.availability();
                        if this.assistance.output_revision != revision {
                            this.assistance.output_revision = revision;
                            if availability != Availability::Ready {
                                this.assistance.diagnostics.clear();
                            }
                            for batch in runtime.diagnostics() {
                                if this.assistance_capture_current(&batch.capture, cx) {
                                    this.assistance
                                        .diagnostics
                                        .insert(batch.capture.document_id.clone(), batch);
                                }
                            }
                            this.assistance.diagnostics.retain(|id, batch| {
                                this.assistance.documents.iter().any(|d| {
                                    d.id == *id
                                        && d.context == batch.capture.context
                                        && d.source.as_ref() == batch.capture.source()
                                })
                            });
                            cx.notify();
                        }
                    })
                    .is_err()
                {
                    break;
                }
            }
        }));
    }
    fn assistance_close_revision(&self, cx: &App) -> u64 {
        let mut hash = std::collections::hash_map::DefaultHasher::new();
        self.assistance.revision.hash(&mut hash);
        for tab in self
            .tabs
            .iter()
            .filter(|t| t.kind == model::DocumentKind::Sql)
        {
            tab.id.hash(&mut hash);
            tab.persistent_id.hash(&mut hash);
            tab.profile.hash(&mut hash);
            tab.generation.hash(&mut hash);
            tab.editor.read(cx).value().as_ref().hash(&mut hash);
            if let Some(capture) = self
                .assistance
                .runtime
                .as_ref()
                .and_then(|r| r.capture(&tab.persistent_id))
            {
                capture.uri.hash(&mut hash);
                capture.version.hash(&mut hash);
                capture.process_generation.hash(&mut hash);
            }
        }
        for profile in &self.profiles {
            profile.id.hash(&mut hash);
            profile.generation.hash(&mut hash);
        }
        hash.finish()
    }
    fn assistance_context(&self, profile: &ProfileId) -> (Dialect, ContextKey, CatalogSnapshot) {
        let settings = self
            .profiles
            .iter()
            .find(|p| p.id == *profile)
            .and_then(|p| p.config.as_ref());
        let dialect = if settings.is_some_and(|s| s.engine == "mysql") {
            Dialect::MySQL
        } else {
            Dialect::PostgreSQL
        };
        let revision = self
            .assistance
            .settings
            .get(profile)
            .map_or(0, |s| s.revision);
        let (catalog_revision, catalog) = self.completion_snapshot(profile);
        (
            dialect,
            ContextKey {
                profile_id: Some(profile.0.clone()),
                settings_revision: revision,
                catalog_revision,
            },
            catalog,
        )
    }
    /// Called by the retained editor's Change subscription and the bounded timer.
    /// The timer observes binding/settings/helper changes, never queries a DB.
    pub(super) fn sync_assistance(&mut self, cx: &mut Context<Self>) {
        let Some(runtime) = self.assistance.runtime.clone() else {
            return;
        };
        let resumed = self.assistance.closing && !self.closing;
        self.assistance.closing = self.closing;
        if self.closing {
            self.dismiss_completion();
            self.dismiss_signatures();
            return;
        }
        let resumed = resumed || runtime.take_resume();
        let mut changed = resumed;
        for profile in &self.profiles {
            if self
                .assistance
                .settings
                .get(&profile.id)
                .is_none_or(|s| s.value != profile.config)
            {
                self.assistance.settings_revision += 1;
                self.assistance.settings.insert(
                    profile.id.clone(),
                    Settings {
                        value: profile.config.clone(),
                        revision: self.assistance.settings_revision,
                    },
                );
                changed = true;
            }
        }
        let mut documents = Vec::new();
        let mut bytes = 0;
        // Active ordinary SQL remains eligible beyond 32 retained tabs/8 MiB.
        for index in std::iter::once(self.active)
            .chain(0..self.tabs.len())
            .filter(|i| *i < self.tabs.len())
        {
            let tab = &self.tabs[index];
            if tab.kind != model::DocumentKind::Sql
                || documents
                    .iter()
                    .any(|d: &runtime::Document| d.id == tab.persistent_id)
            {
                continue;
            }
            let (dialect, context, catalog) = self.assistance_context(&tab.profile);
            if tab.editor.read(cx).value().len()
                > language_service::LanguageService::MAX_DOCUMENT_BYTES
            {
                continue;
            }
            let source = self
                .assistance
                .documents
                .iter()
                .find(|d| d.id == tab.persistent_id && d.source_revision == tab.generation)
                .map(|d| d.source.clone())
                .unwrap_or_else(|| Arc::from(tab.editor.read(cx).value().as_ref()));
            if source.len() > language_service::LanguageService::MAX_DOCUMENT_BYTES
                || bytes + source.len() > 8 * 1024 * 1024
                || documents.len() == 32
            {
                continue;
            }
            bytes += source.len();
            documents.push(runtime::Document {
                id: tab.persistent_id.clone(),
                source_revision: tab.generation,
                source,
                dialect,
                context,
                catalog,
            });
        }
        changed |= self.assistance.documents.len() != documents.len()
            || self
                .assistance
                .documents
                .iter()
                .zip(&documents)
                .any(|(a, b)| {
                    a.id != b.id
                        || a.source_revision != b.source_revision
                        || a.context != b.context
                        || a.dialect != b.dialect
                });
        if changed {
            self.assistance.revision += 1;
            self.assistance.diagnostics.clear();
            self.assistance.documents = documents.clone();
            runtime.synchronize(self.assistance.revision, documents);
        }
        if resumed
            && matches!(
                runtime.availability().1,
                Availability::Stopped | Availability::Unavailable
            )
        {
            runtime.retry();
        }
    }
    #[allow(dead_code)] // Exact capture boundary for Task 24/25.
    pub(super) fn assistance_request(&self, id: DocumentId, cx: &App) -> Option<RequestOwner> {
        if self.closing || self.file_request.is_some() || self.run_file.is_some() {
            return None;
        }
        let tab = self
            .tabs
            .iter()
            .find(|t| t.id == id && t.kind == model::DocumentKind::Sql)?;
        let runtime = self.assistance.runtime.clone()?;
        let capture = runtime.capture(&tab.persistent_id)?;
        self.assistance_capture_current(&capture, cx)
            .then_some(RequestOwner { runtime, capture })
    }
    /// Physical LSP identity, including while the newest source is synchronizing.
    /// Reading the actor capture never spawns a process or queries a database.
    pub(super) fn assistance_process_generation(&self, id: DocumentId) -> Option<u64> {
        let tab = self.tabs.iter().find(|tab| tab.id == id)?;
        self.assistance
            .runtime
            .as_ref()?
            .capture(&tab.persistent_id)
            .map(|capture| capture.process_generation)
    }
    pub(super) fn assistance_capture_current(&self, capture: &DocumentCapture, cx: &App) -> bool {
        if self.closing
            || !self
                .assistance
                .runtime
                .as_ref()
                .is_some_and(|r| r.current(capture))
        {
            return false;
        }
        let Some(tab) = self
            .tabs
            .iter()
            .find(|t| t.persistent_id == capture.document_id && t.kind == model::DocumentKind::Sql)
        else {
            return false;
        };
        let settings = self
            .profiles
            .iter()
            .find(|p| p.id == tab.profile)
            .and_then(|p| p.config.as_ref());
        self.assistance
            .settings
            .get(&tab.profile)
            .is_some_and(|s| s.value.as_ref() == settings)
            && self.assistance_context(&tab.profile).1 == capture.context
            && capture.editor_revision == Some(tab.generation)
            && tab.editor.read(cx).value().as_ref() == capture.source()
    }
    pub(super) fn retry_assistance(&mut self, window: &mut Window, cx: &mut Context<Self>) {
        if self.closing
            || window.has_active_dialog(cx)
            || self.file_request.is_some()
            || self.export_request.is_some()
            || self.run_file.is_some()
        {
            return;
        }
        self.dismiss_completion();
        self.dismiss_signatures();
        if let Some(runtime) = &self.assistance.runtime {
            runtime.retry();
        }
        cx.notify();
    }
    pub(super) fn assistance_status(&self) -> &'static str {
        if self.tabs.get(self.active).is_some_and(|t| {
            t.kind == model::DocumentKind::Sql
                && !self
                    .assistance
                    .documents
                    .iter()
                    .any(|d| d.id == t.persistent_id)
        }) {
            return "SQL assistance unavailable for this document size";
        }
        match self.assistance.runtime.as_ref().map(|r| r.availability().1) {
            Some(Availability::Ready) => "SQL assistance ready",
            Some(Availability::Starting) => "Starting SQL assistance",
            _ => "SQL assistance unavailable",
        }
    }
}
