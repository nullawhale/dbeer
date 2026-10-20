//! Immutable changes preparation. SQL generation and policy authority stay in Go.
//! No value in this module is persistent, logged, or a SQL execution request.
use crate::backend::{
    self, BackendClient, BackendError, CellValue, ChangesRequest, OperationRequest,
};
use std::sync::{
    Arc,
    atomic::{AtomicBool, AtomicU64, Ordering},
};

type Result<T> = std::result::Result<T, BackendError>;
fn invalid() -> BackendError {
    BackendError::transport(
        "The changes preparation no longer matches its original batch or session.",
    )
}

#[derive(Clone, Default)]
pub(super) struct Cancellation(Arc<AtomicBool>);
impl Cancellation {
    pub(super) fn cancel(&self) {
        self.0.store(true, Ordering::Release);
    }
    pub(super) fn cancelled(&self) -> bool {
        self.0.load(Ordering::Acquire)
    }
    pub(super) fn check(&self) -> Result<()> {
        if self.cancelled() {
            Err(BackendError::transport(
                "Changes preparation was cancelled before submission.",
            ))
        } else {
            Ok(())
        }
    }
}
#[derive(Clone, Copy, PartialEq, Eq)]
pub(super) enum Purpose {
    Standalone,
    Apply,
}
/// Never constructed from a SQL/catalog session. The UI checks all live IDs at
/// connect completion before adopting it; every new attempt calls connect anew.
#[derive(Clone)]
pub(super) struct FreshSession(Arc<Session>);
struct Session {
    client: BackendClient,
    id: String,
    purpose: Purpose,
    policy: backend::ExecutionPolicy,
    live: AtomicBool,
    assessment_revision: AtomicU64,
    cancel: Cancellation,
}
impl FreshSession {
    pub(super) fn adopt(
        client: BackendClient,
        connected: backend::ConnectionOutcome,
        purpose: Purpose,
        policy: backend::ExecutionPolicy,
        cancel: Cancellation,
        borrowed: &[String],
    ) -> Result<Self> {
        if borrowed.contains(&connected.session_id) {
            return Err(invalid());
        }
        let accepted = connected.transaction_status == backend::TransactionStatus::Idle
            && [
                "cancel",
                "transactions",
                "operationAssessment",
                "executionPolicy",
            ]
            .iter()
            .all(|required| connected.capabilities.iter().any(|c| c == required));
        Ok(Self(Arc::new(Session {
            client,
            id: connected.session_id,
            purpose,
            policy,
            // Invalid fresh responses still own teardown, but cannot submit work.
            live: AtomicBool::new(accepted),
            assessment_revision: AtomicU64::new(0),
            cancel,
        })))
    }
    pub(super) fn id(&self) -> &str {
        &self.0.id
    }
    pub(super) fn client(&self) -> &BackendClient {
        &self.0.client
    }
    pub(super) fn valid(&self) -> bool {
        self.0.live.load(Ordering::Acquire)
            && self.client().is_alive()
            && !self.0.cancel.cancelled()
    }
    /// Revoke even an unused allow grant, then await teardown on this original
    /// client. No replacement workspace client may resolve this ownership.
    pub(super) async fn cleanup(&self) -> Result<()> {
        self.0.live.store(false, Ordering::Release);
        // A lost cancel ACK must not prevent disconnect from tearing down the
        // session and its grant. No SQL work is retried.
        let _ = smol::future::race(self.client().revoke_authorization(self.id()), async {
            smol::Timer::after(std::time::Duration::from_secs(5)).await;
            Err(invalid())
        })
        .await;
        self.client().disconnect(self.id()).await
    }
    pub(super) fn invalidate(&self) {
        self.0.live.store(false, Ordering::Release);
    }
}
/// The exact ordered helper batch. Changes remain typed and never become SQL.
#[derive(Clone)]
pub(super) struct Plan {
    request: ChangesRequest,
    operations: Vec<OperationRequest>,
}
impl Plan {
    pub(super) fn new(request: ChangesRequest) -> Result<Arc<Self>> {
        if !request.valid() {
            return Err(invalid());
        }
        Ok(Arc::new(Self {
            operations: vec![OperationRequest::Apply {
                changes: request.clone(),
            }],
            request,
        }))
    }
    pub(super) fn request(&self) -> &ChangesRequest {
        &self.request
    }
    pub(super) fn operations(&self) -> &[OperationRequest] {
        &self.operations
    }
    pub(super) fn preview(self: &Arc<Self>, session: &FreshSession) -> Result<PendingPreview> {
        if !session.valid() {
            return Err(invalid());
        }
        let revision = session.0.assessment_revision.fetch_add(1, Ordering::AcqRel) + 1;
        let stream = session
            .client()
            .preview_changes(session.id(), self.request.clone())?;
        Ok(PendingPreview {
            plan: self.clone(),
            session: session.clone(),
            stream,
            revision,
        })
    }
    fn statements(&self, outcome: backend::QueryOutcome) -> Result<Vec<backend::PreviewStatement>> {
        if outcome.transaction_status != backend::TransactionStatus::Idle
            || outcome.truncated
            || outcome.result_sets.len() != 1
        {
            return Err(invalid());
        }
        let statements = outcome.result_sets[0].preview_statements()?;
        if statements.len() != self.request.changes.len()
            || !statements
                .iter()
                .zip(&self.request.changes)
                .all(|(p, c)| p.operation == c.kind)
        {
            return Err(invalid());
        }
        Ok(statements)
    }
}
pub(super) struct PendingPreview {
    plan: Arc<Plan>,
    session: FreshSession,
    stream: backend::QueryStream,
    revision: u64,
}
impl PendingPreview {
    pub(super) fn query_id(&self) -> &str {
        &self.stream.query_id
    }
    pub(super) async fn finish(self) -> Result<Previewed> {
        let outcome = crate::live::collect(self.stream).await?;
        if !self.session.valid()
            || self.session.0.assessment_revision.load(Ordering::Acquire) != self.revision
        {
            return Err(invalid());
        }
        let statements = self.plan.statements(outcome)?;
        Ok(Previewed {
            plan: self.plan,
            session: self.session,
            statements,
            revision: self.revision,
        })
    }
}
pub(super) struct Previewed {
    plan: Arc<Plan>,
    session: FreshSession,
    statements: Vec<backend::PreviewStatement>,
    revision: u64,
}
impl Previewed {
    /// Caller validates its immutable UI capture before AND after this await.
    /// Assessment receives changes.apply, never generated SQL classification.
    pub(super) fn begin_assessment(self) -> Result<PendingPreparation> {
        let session = self.session.clone();
        if !session.valid()
            || session.0.assessment_revision.load(Ordering::Acquire) != self.revision
        {
            return Err(invalid());
        }
        let revision = session.0.assessment_revision.fetch_add(1, Ordering::AcqRel) + 1;
        let request = session
            .client()
            .begin_assessment(session.id(), self.plan.operations().to_vec())?;
        Ok(PendingPreparation {
            previewed: self,
            session,
            request,
            revision,
        })
    }
}
pub(super) struct PendingPreparation {
    previewed: Previewed,
    session: FreshSession,
    request: backend::AssessmentRequest,
    revision: u64,
}
impl PendingPreparation {
    pub(super) fn query_id(&self) -> &str {
        &self.request.query_id
    }
    pub(super) async fn finish(self) -> Result<Arc<Preparation>> {
        let assessment = self.request.finish().await?;
        if !self.session.valid()
            || self.session.0.assessment_revision.load(Ordering::Acquire) != self.revision
            || assessment.policy != self.session.0.policy
            || assessment.operations.len() != self.previewed.plan.operations.len()
            || assessment
                .operations
                .iter()
                .any(|op| !op.statements.is_empty())
        {
            return Err(invalid());
        }
        Ok(Arc::new(Preparation {
            previewed: self.previewed,
            session: self.session,
            assessment,
            revision: self.revision,
        }))
    }
}
/// Session-bound immutable proof for Task 19. A standalone preparation cannot
/// produce an approval, and cleanup/Stop invalidates every clone immediately.
pub(super) struct Preparation {
    previewed: Previewed,
    session: FreshSession,
    assessment: backend::OperationAssessment,
    revision: u64,
}
impl Preparation {
    fn valid(&self) -> bool {
        self.session.valid()
            && self.session.0.assessment_revision.load(Ordering::Acquire) == self.revision
    }
    pub(super) fn requires_confirmation(&self) -> bool {
        self.assessment.requires_confirmation()
    }
    pub(super) fn rejected(&self) -> bool {
        self.assessment.rejected()
    }
    pub(super) fn display(&self) -> String {
        display(&self.previewed, &self.assessment)
    }
}
fn display(previewed: &Previewed, assessment: &backend::OperationAssessment) -> String {
    display_statements(&previewed.plan, &previewed.statements, assessment)
}
fn display_statements(
    plan: &Plan,
    statements: &[backend::PreviewStatement],
    assessment: &backend::OperationAssessment,
) -> String {
    let mut text = format!(
        "Policy: {} / readonly={}\nHelper decision: {}\nWhole changes.apply batch: {}\n\n",
        assessment.policy.environment,
        assessment.policy.read_only,
        assessment.decision,
        assessment.operations[0].kind
    );
    for (i, statement) in statements.iter().enumerate() {
        let kind = match statement.operation {
            backend::ChangeKind::Insert => "insert",
            backend::ChangeKind::Update => "update",
            backend::ChangeKind::Delete => "delete",
        };
        text.push_str(&format!(
            "Change {} / {}\n{}\nBound parameters (ordered typed JSON):\n",
            i + 1,
            kind,
            statement.sql
        ));
        // JSON strings preserve exact decimal/temporal text, NULL versus
        // literal text, empty strings, Base64 bytes, escapes and Unicode.
        text.push_str(
            &serde_json::to_string_pretty(&statement.parameters)
                .expect("CellValue serialization is infallible"),
        );
        text.push_str(&format!(
            "\nParameter kinds: {}",
            statement
                .parameters
                .iter()
                .map(parameter_kind)
                .collect::<Vec<_>>()
                .join(", ")
        ));
        text.push_str("\n\n");
    }
    text.push_str(
        "Exact frozen changes (original rows and assignments; DEFAULT is not a bound parameter):\n",
    );
    text.push_str(
        &serde_json::to_string_pretty(plan.request()).expect("Changes serialization is infallible"),
    );
    text
}
impl Preparation {
    pub(super) fn plan(&self) -> &Arc<Plan> {
        &self.previewed.plan
    }
    pub(super) fn session(&self) -> &FreshSession {
        &self.session
    }
    pub(super) fn approval(self: &Arc<Self>, explicitly_reviewed: bool) -> Result<Approval> {
        if self.session.0.purpose != Purpose::Apply
            || !self.valid()
            || self.assessment.rejected()
            || (self.assessment.requires_confirmation() && !explicitly_reviewed)
        {
            return Err(invalid());
        }
        let authorization = self.assessment.authorization.clone().ok_or_else(invalid)?;
        Ok(Approval {
            preparation: self.clone(),
            authorization,
        })
    }
}
pub(super) struct Approval {
    preparation: Arc<Preparation>,
    authorization: String,
}
impl Approval {
    /// In addition to this identity check the caller MUST call Workspace's exact
    /// changes_batch_valid after user review, immediately before submission.
    pub(super) fn authorization_for(&self, preparation: &Arc<Preparation>) -> Result<String> {
        if !Arc::ptr_eq(&self.preparation, preparation) || !preparation.valid() {
            return Err(invalid());
        }
        Ok(self.authorization.clone())
    }
}
/// Submitted exactly once; Stop never discards the terminal or invents rollback.
pub(super) struct PendingApply {
    stream: backend::QueryStream,
    // Retain the original helper/session even if the approval is dropped.
    _session: FreshSession,
}
impl Approval {
    /// Synchronous enqueue and ID publication must share one UI turn. Consuming
    /// the session revision also invalidates every approval clone before enqueue.
    pub(super) fn begin_apply(self, preparation: &Arc<Preparation>) -> Result<PendingApply> {
        let authorization = self.authorization_for(preparation)?;
        let session = preparation.session();
        session
            .0
            .assessment_revision
            .compare_exchange(
                preparation.revision,
                preparation.revision + 1,
                Ordering::AcqRel,
                Ordering::Acquire,
            )
            .map_err(|_| invalid())?;
        let stream = session
            .client()
            .apply_changes(
                session.id(),
                preparation.plan().request().clone(),
                Some(authorization),
            )
            .map_err(before_submission)?;
        Ok(PendingApply {
            stream,
            _session: session.clone(),
        })
    }
}
impl PendingApply {
    pub(super) fn query_id(&self) -> &str {
        &self.stream.query_id
    }
    pub(super) async fn finish(self) -> Result<backend::QueryOutcome> {
        // Cancellation invalidates pre-submission proof, not an authoritative
        // success/rollback received after submission. Never consult valid() here.
        while let Ok(event) = self.stream.events.recv().await {
            match event {
                Ok(backend::QueryEvent::Finished(outcome)) => return Ok(outcome),
                Ok(_) => {}
                Err(mut error) => {
                    // A transport failure after enqueue cannot prove whether a
                    // queued Apply ran, even without query.started/COMMIT ACK.
                    error.outcome_unknown |= error.category == "transport";
                    return Err(error);
                }
            }
        }
        let mut error = BackendError::transport(
            "Apply confirmation was lost. Inspect the affected data before discarding local changes and reloading.",
        );
        error.outcome_unknown = true;
        Err(error)
    }
}

/// Read-only preview/assessment failures and synchronous enqueue refusal cannot
/// imply an unknown mutation. Only PendingApply owns post-submission uncertainty.
pub(super) fn before_submission(mut error: BackendError) -> BackendError {
    error.outcome_unknown = false;
    error
}

pub(super) fn policy(profile: &crate::connections::ConnectionProfile) -> backend::ExecutionPolicy {
    backend::ExecutionPolicy {
        environment: if profile.environment == "unset" {
            "unspecified".into()
        } else {
            profile.environment.clone()
        },
        read_only: profile.readonly,
    }
}
pub(super) fn parameter_kind(value: &CellValue) -> &'static str {
    match value {
        CellValue::Null => "null",
        CellValue::Default => "default",
        CellValue::Text(_) => "text",
        CellValue::Binary(_) => "binary",
    }
}

#[cfg(test)]
mod tests;

#[cfg(test)]
mod database_tests;
