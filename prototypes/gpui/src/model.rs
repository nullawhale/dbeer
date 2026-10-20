//! UI-independent document identity, operation snapshots and authoritative session state.
//! No editor reconstruction, SQL parsing or database policy lives here.
use crate::{backend::ResultSet, connections::ConnectionProfile};
use crate::{scripts::DisplayBudget, sql};
use std::{ops::Range, sync::Arc};

#[derive(Clone, Copy, Debug, PartialEq, Eq, Hash)]
pub struct DocumentId(pub u64);
impl std::fmt::Display for DocumentId {
    fn fmt(&self, f: &mut std::fmt::Formatter<'_>) -> std::fmt::Result {
        self.0.fmt(f)
    }
}
#[derive(Clone, Debug, PartialEq, Eq, Hash)]
pub struct ProfileId(pub String);
impl ProfileId {
    pub fn unbound() -> Self {
        Self("unbound:".into())
    }
    pub fn saved(profile: &ConnectionProfile) -> Self {
        Self(profile.id.clone())
    }
    pub fn demo(name: &str) -> Self {
        Self(format!("demo:{name}"))
    }
}

/// Later table/inspection features use these identities without borrowing a SQL tab.
#[derive(Clone, Debug, PartialEq, Eq)]
pub enum DocumentKind {
    Sql,
    Table {
        schema: String,
        object: String,
        object_kind: String,
    },
    Inspection {
        schema: String,
        object: String,
        object_kind: String,
        identity: Option<String>,
    },
}
#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub enum OperationPhase {
    Preparing,
    Reviewing,
    Running,
    Cancelling,
}
#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub enum ExecutionState {
    Preparing,
    Pending,
    Running,
    Succeeded,
    Failed,
    Cancelled,
    Stale,
    Skipped,
    Unknown,
}

/// A submission records its exact source span/revision and ordered result range.
/// Every statement keeps its own source, outcome and ordered result-set range.
#[derive(Default)]
pub struct ExecutionMetrics {
    pub duration_ms: f64,
    pub row_count: u64,
    pub truncated: bool,
}

pub struct StatementExecution {
    pub operation: u64,
    pub source_revision: u64,
    pub source_range: Range<usize>,
    pub state: ExecutionState,
    pub results: Range<usize>,
    pub duration_ms: f64,
    pub row_count: u64,
    pub truncated: bool,
    pub failure: Option<String>,
    pub error_position: Option<sql::MappedAdapterPosition>,
    pub started_at: Option<std::time::Instant>,
    pub history_recorded: bool,
}

/// Captured before asynchronous work. It contains nonsecret endpoint/TLS/policy
/// settings; never derive Debug or log it. Profile indices and UI selection are absent.
#[derive(Clone)]
pub struct OperationContext {
    pub document: DocumentId,
    pub profile: ProfileId,
    pub settings: Option<ConnectionProfile>,
    pub source_revision: u64,
    pub session_generation: u64,
    pub operation: u64,
    pub session: Option<String>,
}

pub struct DocumentState {
    pub id: DocumentId,
    pub title: String,
    /// Durable identity is independent of runtime operation IDs.
    pub persistent_id: String,
    pub file: crate::files::DocumentFile,
    pub profile: ProfileId,
    pub kind: DocumentKind,
    pub generation: u64,
    pub session_generation: u64,
    pub session: Option<String>,
    /// The configuration that actually created this physical session.
    pub session_settings: Option<ConnectionProfile>,
    pub query_id: Option<String>,
    pub transaction: String,
    pub uncertain: bool,
    pub stop_requested: bool,
    pub resolving_close: bool,
    pub result_sets: Vec<ResultSet>,
    pub selected_result: usize,
    pub executions: Vec<StatementExecution>,
    pub operation: Option<OperationContext>,
    pub phase: Option<OperationPhase>,
    /// Captured source remains available for statement/history consumers even if
    /// the editor changes. It must never be serialized as a live session/grant.
    pub execution_source: Option<Arc<sql::PreparedFragment>>,
    pub execution_editor_bound: bool,
    pub history_allowed: bool,
    pub active_execution: usize,
    pub selected_execution: usize,
    pub successful_ranges: Vec<Range<usize>>,
    pub error_position: Option<sql::MappedAdapterPosition>,
    pub display_budget: DisplayBudget,
    pub(super) run_file_recovery: Option<crate::run_to_file::Recovery>,
    next_operation: u64,
}
impl DocumentState {
    pub fn sql(id: DocumentId, title: String, profile: ProfileId) -> Self {
        Self {
            id,
            title,
            persistent_id: crate::restoration::new_uuid(),
            file: crate::files::DocumentFile::default(),
            profile,
            kind: DocumentKind::Sql,
            generation: 0,
            session_generation: 0,
            session: None,
            session_settings: None,
            query_id: None,
            transaction: "idle".into(),
            uncertain: false,
            stop_requested: false,
            resolving_close: false,
            result_sets: Vec::new(),
            selected_result: 0,
            executions: Vec::new(),
            operation: None,
            phase: None,
            execution_source: None,
            execution_editor_bound: true,
            history_allowed: true,
            active_execution: 0,
            selected_execution: 0,
            successful_ranges: Vec::new(),
            error_position: None,
            display_budget: DisplayBudget::default(),
            run_file_recovery: None,
            next_operation: 1,
        }
    }
    pub fn busy(&self) -> bool {
        self.operation.is_some()
    }
    pub fn snapshot_locked(&self) -> bool {
        self.busy() || self.uncertain || self.transaction != "idle" || self.session.is_some()
    }
    pub fn begin(
        &mut self,
        settings: Option<ConnectionProfile>,
        source_bytes: usize,
    ) -> Option<OperationContext> {
        if self.busy()
            || self.uncertain
            || (self.session.is_some() && self.session_settings != settings)
        {
            return None;
        }
        if self.session.is_none() {
            self.session_generation += 1;
        }
        let context = OperationContext {
            document: self.id,
            profile: self.profile.clone(),
            settings,
            source_revision: self.generation,
            session_generation: self.session_generation,
            operation: self.next_operation,
            session: self.session.clone(),
        };
        self.next_operation += 1;
        self.stop_requested = false;
        self.history_allowed = true;
        self.query_id = None;
        self.operation = Some(context.clone());
        self.phase = Some(OperationPhase::Preparing);
        self.executions.clear();
        self.clear_execution_marks();
        self.execution_source = None;
        self.active_execution = 0;
        self.selected_execution = 0;
        self.display_budget = DisplayBudget::default();
        self.executions.push(StatementExecution {
            operation: context.operation,
            source_revision: self.generation,
            source_range: 0..source_bytes,
            state: ExecutionState::Preparing,
            results: 0..0,
            duration_ms: 0.,
            row_count: 0,
            truncated: false,
            failure: None,
            error_position: None,
            started_at: None,
            history_recorded: false,
        });
        Some(context)
    }
    /// Terminal/session identity deliberately ignores source edits. A completed
    /// transaction still happened even when its display payload became obsolete.
    pub fn owns(&self, context: &OperationContext) -> bool {
        self.id == context.document
            && self.profile == context.profile
            && self.session_generation == context.session_generation
            && self
                .operation
                .as_ref()
                .is_some_and(|active| active.operation == context.operation)
            && self
                .executions
                .get(self.active_execution)
                .is_some_and(|execution| {
                    execution.operation == context.operation
                        && execution.source_revision == context.source_revision
                        && execution.source_range.start <= execution.source_range.end
                })
            && context
                .session
                .as_ref()
                .is_none_or(|id| self.session.as_ref() == Some(id))
    }
    pub fn accepts(
        &self,
        context: &OperationContext,
        settings: Option<&ConnectionProfile>,
    ) -> bool {
        self.owns(context)
            && self.generation == context.source_revision
            && context.settings.as_ref() == settings
            && !self.stop_requested
            && !self.uncertain
    }
    pub fn attach(
        &mut self,
        context: &OperationContext,
        session: String,
    ) -> Option<OperationContext> {
        if !self.owns(context) {
            return None;
        }
        self.session = Some(session.clone());
        self.session_settings = context.settings.clone();
        let mut attached = context.clone();
        attached.session = Some(session);
        self.operation = Some(attached.clone());
        Some(attached)
    }
    pub fn started(&mut self, context: &OperationContext, query: String) -> bool {
        if !self.owns(context) {
            return false;
        }
        self.query_id = Some(query);
        self.selected_execution = self.active_execution;
        self.phase = Some(OperationPhase::Running);
        if let Some(execution) = self.executions.get_mut(self.active_execution) {
            execution.started_at = Some(std::time::Instant::now());
            execution.state = ExecutionState::Running;
        }
        true
    }
    pub fn end(
        &mut self,
        context: &OperationContext,
        state: ExecutionState,
        result_count: usize,
    ) -> bool {
        if !self.owns(context) {
            return false;
        }
        let fallback_results = self.execution_source.is_none();
        if let Some(execution) = self.executions.get_mut(self.active_execution) {
            if matches!(
                execution.state,
                ExecutionState::Preparing | ExecutionState::Pending | ExecutionState::Running
            ) {
                execution.state = state;
            }
            if fallback_results && execution.results.is_empty() {
                execution.results = 0..result_count;
            }
        }
        for execution in &mut self.executions {
            if matches!(
                execution.state,
                ExecutionState::Pending | ExecutionState::Preparing
            ) {
                execution.state = ExecutionState::Skipped;
            }
        }
        self.operation = None;
        self.phase = None;
        self.query_id = None;
        self.resolving_close = false;
        true
    }
    pub fn clear_execution_marks(&mut self) {
        self.successful_ranges.clear();
        self.error_position = None;
    }
    pub fn prepare_batch(&mut self, fragment: Arc<sql::PreparedFragment>) {
        let Some(context) = &self.operation else {
            return;
        };
        self.executions = fragment
            .statements()
            .iter()
            .map(|statement| StatementExecution {
                operation: context.operation,
                source_revision: context.source_revision,
                source_range: statement.span().bytes(),
                state: ExecutionState::Pending,
                results: 0..0,
                duration_ms: 0.,
                row_count: 0,
                truncated: false,
                failure: None,
                error_position: None,
                started_at: None,
                history_recorded: false,
            })
            .collect();
        self.execution_source = Some(fragment);
        self.active_execution = 0;
        self.selected_execution = 0;
    }
    /// Only the authoritative current terminal may add results or success marks.
    /// Result budget and original identities survive all subsequent statements.
    pub fn record_statement(
        &mut self,
        context: &OperationContext,
        state: ExecutionState,
        sets: Vec<ResultSet>,
        metrics: ExecutionMetrics,
        valid: bool,
    ) -> bool {
        if !self.owns(context) {
            return false;
        }
        let range = if valid {
            self.display_budget.retain(sets, &mut self.result_sets)
        } else {
            self.result_sets.len()..self.result_sets.len()
        };
        let execution = &mut self.executions[self.active_execution];
        execution.state = state;
        self.selected_result = range.start;
        execution.results = range;
        execution.duration_ms = metrics.duration_ms;
        execution.row_count = metrics.row_count;
        execution.truncated = metrics.truncated || self.display_budget.truncated;
        if valid
            && self.execution_editor_bound
            && state == ExecutionState::Succeeded
            && !self.stop_requested
            && !self.uncertain
        {
            self.successful_ranges.push(execution.source_range.clone());
        }
        self.query_id = None;
        true
    }
    pub fn retire_session(&mut self) {
        self.session_generation += 1;
        self.session = None;
        self.session_settings = None;
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    fn document() -> DocumentState {
        DocumentState::sql(DocumentId(1), "Query.sql".into(), ProfileId::demo("one"))
    }
    #[test]
    fn edited_source_discards_payload_but_reconciles_original_terminal() {
        let mut d = document();
        let c = d.begin(None, 12).unwrap();
        let c = d.attach(&c, "session-one".into()).unwrap();
        assert!(d.started(&c, "query-one".into()));
        d.generation += 1;
        assert!(!d.accepts(&c, None));
        assert!(d.owns(&c));
        d.transaction = "transaction".into();
        assert!(d.end(&c, ExecutionState::Stale, 0));
        assert!(!d.busy());
        assert!(d.snapshot_locked());
        assert_eq!(d.transaction, "transaction");
        assert_eq!(d.executions[0].source_range, 0..12);
        assert_eq!(d.executions[0].source_revision, 0);
    }
    #[test]
    fn late_terminal_cannot_clear_new_operation_or_replacement_session() {
        let mut d = document();
        let old = d.begin(None, 3).unwrap();
        d.end(&old, ExecutionState::Cancelled, 0);
        let new = d.begin(None, 4).unwrap();
        assert!(!d.end(&old, ExecutionState::Failed, 0));
        assert!(d.owns(&new));
        d.retire_session();
        assert!(!d.end(&new, ExecutionState::Succeeded, 0));
    }
    #[test]
    fn endpoint_tls_policy_changes_invalidate_payload_and_prevent_session_reuse() {
        let mut d = document();
        let p = ConnectionProfile::new();
        let c = d.begin(Some(p.clone()), 3).unwrap();
        let c = d.attach(&c, "session-one".into()).unwrap();
        for change in [0, 1, 2] {
            let mut changed = p.clone();
            match change {
                0 => changed.host = "other-host".into(),
                1 => changed.ssl_mode = "require".into(),
                _ => changed.readonly = !p.readonly,
            }
            assert!(!d.accepts(&c, Some(&changed)));
            assert!(d.owns(&c));
        }
        d.end(&c, ExecutionState::Succeeded, 0);
        let mut changed = p;
        changed.readonly = !changed.readonly;
        assert!(d.begin(Some(changed), 3).is_none());
    }
    #[test]
    fn tab_identity_stop_and_unknown_are_independent_locks() {
        let mut first = document();
        let c = first.begin(None, 8).unwrap();
        let mut second = document();
        second.id = DocumentId(2);
        assert!(!second.owns(&c));
        assert!(first.begin(None, 8).is_none());
        first.stop_requested = true;
        first.phase = Some(OperationPhase::Cancelling);
        assert!(!first.accepts(&c, None));
        assert!(first.end(&c, ExecutionState::Cancelled, 0));
        first.uncertain = true;
        assert!(first.begin(None, 8).is_none());
        assert!(first.snapshot_locked());
    }
}

#[cfg(test)]
mod script_tests {
    use super::*;
    fn batch() -> (DocumentState, OperationContext) {
        let mut d = DocumentState::sql(
            DocumentId(7),
            "Script.sql".into(),
            ProfileId::demo("script"),
        );
        let source = sql::resolve(
            sql::SourceText::new("SELECT '😀';\r\nSELECT 2;\r\nSELECT 3;"),
            0..0,
            sql::Dialect::PostgreSQL,
            true,
        )
        .unwrap();
        let c = d.begin(None, source.source().text().len()).unwrap();
        d.prepare_batch(Arc::new(source));
        let c = d.attach(&c, "original-session".into()).unwrap();
        (d, c)
    }
    #[test]
    fn completed_prefix_multisets_and_transaction_survive_middle_failure() {
        let (mut d, c) = batch();
        d.started(&c, "first".into());
        d.record_statement(
            &c,
            ExecutionState::Succeeded,
            vec![ResultSet::default(); 2],
            ExecutionMetrics::default(),
            true,
        );
        d.transaction = "transaction".into();
        assert!(d.busy());
        d.active_execution = 1;
        d.started(&c, "second".into());
        d.record_statement(
            &c,
            ExecutionState::Failed,
            vec![ResultSet::default()],
            ExecutionMetrics::default(),
            true,
        );
        d.transaction = "failedTransaction".into();
        d.end(&c, ExecutionState::Failed, 3);
        assert_eq!(d.executions[0].state, ExecutionState::Succeeded);
        assert_eq!(d.executions[0].results, 0..2);
        assert_eq!(d.executions[1].results, 2..3);
        assert_eq!(d.executions[2].state, ExecutionState::Skipped);
        assert_eq!(d.transaction, "failedTransaction");
        assert_eq!(d.successful_ranges.len(), 1);
        assert_eq!(d.session.as_deref(), Some("original-session"));
    }
    #[test]
    fn stop_in_terminal_gap_preserves_completed_prefix_and_skips_unsubmitted() {
        let (mut d, c) = batch();
        d.started(&c, "first".into());
        d.record_statement(
            &c,
            ExecutionState::Succeeded,
            vec![ResultSet::default()],
            ExecutionMetrics::default(),
            true,
        );
        d.stop_requested = true;
        assert!(!d.accepts(&c, None));
        d.end(&c, ExecutionState::Cancelled, 1);
        assert_eq!(d.executions[0].state, ExecutionState::Succeeded);
        assert!(
            d.executions[1..]
                .iter()
                .all(|e| e.state == ExecutionState::Skipped)
        );
        assert_eq!(d.successful_ranges.len(), 1);
    }
    #[test]
    fn cancellation_unknown_and_stale_source_never_add_success_marks_or_allow_blind_retry() {
        for state in [
            ExecutionState::Cancelled,
            ExecutionState::Unknown,
            ExecutionState::Stale,
        ] {
            let (mut d, c) = batch();
            d.started(&c, "first".into());
            d.uncertain = state == ExecutionState::Unknown;
            d.record_statement(
                &c,
                state,
                vec![ResultSet::default()],
                ExecutionMetrics::default(),
                state != ExecutionState::Stale,
            );
            d.end(&c, state, 1);
            assert!(d.successful_ranges.is_empty());
            if state == ExecutionState::Unknown {
                assert!(d.begin(None, 1).is_none());
            }
        }
        let (mut d, c) = batch();
        d.record_statement(
            &c,
            ExecutionState::Succeeded,
            vec![],
            ExecutionMetrics::default(),
            true,
        );
        d.generation += 1;
        d.clear_execution_marks();
        assert!(d.successful_ranges.is_empty() && !d.accepts(&c, None) && d.owns(&c));
        d.end(&c, ExecutionState::Stale, 0);
        d.begin(None, 1).unwrap();
        assert!(d.successful_ranges.is_empty());
    }
}

#[cfg(test)]
mod display_budget_script_tests {
    use super::*;
    #[test]
    fn exhausted_display_rows_does_not_skip_later_command_or_transaction_terminal() {
        let mut d = DocumentState::sql(
            DocumentId(4),
            "Budget.sql".into(),
            ProfileId::demo("budget"),
        );
        let fragment = sql::resolve(
            sql::SourceText::new("SELECT 1; SELECT 2; COMMIT;"),
            0..0,
            sql::Dialect::PostgreSQL,
            true,
        )
        .unwrap();
        let c = d.begin(None, fragment.source().text().len()).unwrap();
        d.prepare_batch(Arc::new(fragment));
        for i in 0..3 {
            d.active_execution = i;
            d.started(&c, format!("query-{i}"));
            let set = if i < 2 {
                ResultSet {
                    rows: vec![vec![Some("exact".into())]; 600],
                    row_count: 600,
                    displayed_row_count: 600,
                    ..Default::default()
                }
            } else {
                ResultSet {
                    command_tag: "COMMIT".into(),
                    ..Default::default()
                }
            };
            d.record_statement(
                &c,
                ExecutionState::Succeeded,
                vec![set],
                ExecutionMetrics::default(),
                true,
            );
        }
        d.transaction = "idle".into();
        d.end(&c, ExecutionState::Succeeded, 3);
        assert!(
            d.display_budget.truncated
                && d.executions
                    .iter()
                    .all(|e| e.state == ExecutionState::Succeeded)
        );
        assert_eq!(
            d.result_sets.iter().map(|s| s.rows.len()).sum::<usize>(),
            1000
        );
        assert_eq!(d.result_sets[2].command_tag, "COMMIT");
        assert_eq!(d.executions[2].results, 2..3);
        assert!(!d.busy() && d.transaction == "idle");
    }
}
