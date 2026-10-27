//! Completion pages share the existing original catalog service scheduler.
use super::*;
use crate::language_service::{CatalogSnapshot, metadata::CatalogOwner};
#[derive(Default)]
pub(super) struct CompletionState {
    pub revision: u64,
    pub entries: HashMap<ProfileId, CompletionEntry>,
    pub refresh: std::collections::HashSet<ProfileId>,
}
pub(super) struct CompletionEntry {
    pub revision: u64,
    pub pending: bool,
    pub snapshot: CatalogSnapshot,
    pub owner: Option<CatalogContext>,
    pub status: &'static str,
}
impl Workspace {
    /// Metadata retained after a failed refresh is explicitly marked previous.
    /// A disconnected/replaced service never supplies its old catalog to LSP.
    pub(crate) fn completion_snapshot(&self, profile: &ProfileId) -> (u64, CatalogSnapshot) {
        let Some(entry) = self.catalog.completion.entries.get(profile) else {
            return (0, CatalogSnapshot::default());
        };
        let valid = entry
            .owner
            .as_ref()
            .is_some_and(|c| self.completion_service_valid(c));
        (
            entry.revision.saturating_mul(2) + u64::from(valid),
            if valid {
                entry.snapshot.clone()
            } else {
                CatalogSnapshot::default()
            },
        )
    }
    fn completion_service_valid(&self, context: &CatalogContext) -> bool {
        self.profiles.iter().any(|p| {
            p.id == context.profile
                && p.service_generation == context.service_generation
                && p.loaded
                && p.config.as_ref() == Some(&context.settings)
                && p.session == context.session
                && p.session_settings.as_ref() == Some(&context.settings)
                && p.session_client
                    .as_ref()
                    .is_some_and(|c| c.same_instance(&context.client))
        }) && context.client.is_alive()
            && self
                .backend
                .as_ref()
                .is_some_and(|c| c.same_instance(&context.client))
    }
    pub(super) fn invalidate_completion(&mut self, profile: &ProfileId, pending: bool) {
        self.catalog.completion.revision += 1;
        let revision = self.catalog.completion.revision;
        let entry = self
            .catalog
            .completion
            .entries
            .entry(profile.clone())
            .or_insert(CompletionEntry {
                revision,
                pending,
                snapshot: CatalogSnapshot::default(),
                owner: None,
                status: "Offline metadata",
            });
        entry.revision = revision;
        entry.pending = pending;
        entry.status = if pending {
            "Refreshing SQL assistance metadata; previous metadata retained"
        } else {
            "SQL assistance metadata is disconnected"
        };
    }
    pub(super) fn completion_work_current(&self, context: &CatalogContext, revision: u64) -> bool {
        !self.closing
            && self.catalog_valid(context).is_some()
            && self
                .catalog
                .completion
                .entries
                .get(&context.profile)
                .is_some_and(|entry| entry.revision == revision)
            && self.completion_service_valid(context)
    }
    /// Pending flags coalesce explicit Refresh, and never arise from editor work.
    pub(super) fn pump_completion(&mut self, window: &mut Window, cx: &mut Context<Self>) -> bool {
        if self.closing
            || self.file_request.is_some()
            || self.export_request.is_some()
            || self.run_file.is_some()
        {
            return false;
        }
        if self.profiles.iter().any(|p| p.task.is_some()) {
            return false;
        }
        for index in 0..self.profiles.len() {
            let id = self.profiles[index].id.clone();
            if self.catalog.completion.refresh.remove(&id) {
                self.connect_profile(index, window, cx);
                return true;
            }
            if self
                .catalog
                .completion
                .entries
                .get(&id)
                .is_some_and(|entry| entry.pending)
                && self.profiles[index].loaded
                && self.profiles[index].session.is_some()
                && self.profiles[index].config == self.profiles[index].session_settings
            {
                let entry = self.catalog.completion.entries.get_mut(&id).unwrap();
                let revision = entry.revision;
                entry.pending = false;
                self.start_catalog_work(index, Work::Completion { revision }, window, cx);
                return true;
            }
        }
        false
    }
    pub(super) fn completion_status(&self, profile: &ProfileId) -> Option<&'static str> {
        self.catalog
            .completion
            .entries
            .get(profile)
            .map(|entry| entry.status)
    }
}
pub(super) fn metadata_owner(context: &CatalogContext, revision: u64) -> CatalogOwner {
    CatalogOwner {
        profile_id: context.profile.0.clone(),
        settings_revision: revision,
        service_generation: context.service_generation,
        catalog_revision: revision,
    }
}
pub(super) fn metadata_error() -> backend::BackendError {
    let mut error = backend::BackendError::transport(
        "SQL assistance metadata could not be refreshed; previous metadata retained.",
    );
    error.connected = true;
    error.category = "catalog".into();
    error
}
