//! A physical SQL session belongs to a helper instance, not a textual session ID.
use super::*;
use workspace::QueryTab;

#[derive(Clone)]
pub(super) struct SessionOwner {
    session: String,
    generation: u64,
    client: BackendClient,
}
impl QueryTab {
    pub(super) fn own_session(&mut self, client: BackendClient) {
        self.session_owner = self.session.as_ref().map(|session| SessionOwner {
            session: session.clone(),
            generation: self.session_generation,
            client,
        });
    }
    pub(super) fn session_client(&self) -> Option<BackendClient> {
        self.session_owner
            .as_ref()
            .filter(|owner| {
                self.session.as_ref() == Some(&owner.session)
                    && self.session_generation == owner.generation
            })
            .map(|owner| owner.client.clone())
            .or_else(|| {
                self.run_file_recovery
                    .as_ref()
                    .filter(|r| {
                        self.session.is_some()
                            && r.session == self.session
                            && r.session_generation == self.session_generation
                    })
                    .and_then(|r| r.client.clone())
            })
            .or_else(|| {
                self.operation
                    .as_ref()
                    .filter(|op| {
                        self.session.is_some()
                            && op.session == self.session
                            && op.session_generation == self.session_generation
                    })
                    .and(self.operation_client.clone())
            })
    }
    pub(super) fn retire_session(&mut self) {
        self.document.retire_session();
        self.session_owner = None;
    }
}
