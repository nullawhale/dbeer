/// Stable opaque copy of the COMMON close graph's token. The adapter allocates
/// no CloseTokens and cannot mark ExitOutcome::Reviewed or authorize removal.
#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub(crate) struct CommonCloseToken(pub u64);
#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub(crate) struct RequestToken {
    pub registration: u64,
    pub sequence: u64,
}
#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub(crate) enum Phase {
    Query,
    End,
}
#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub(crate) enum Signal {
    Query(u32),
    End(u32),
    Cancel,
    Stop,
}
#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub(crate) enum Availability {
    Starting,
    Registered,
    ServiceLost,
    Unavailable,
    Stopped,
}

/// The common graph supplies this synchronously. Ready means all review,
/// operation terminals, original disconnect ACKs and latest final flush already
/// completed, while the graph STILL OWNS its removal decision. It is not an
/// adapter-issued approval. Any graph mutation must publish Waiting/Absent
/// before that mutation, never after an asynchronous stale completion.
#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub(crate) enum CloseReadiness {
    Absent,
    Waiting(CommonCloseToken),
    Ready(CommonCloseToken),
}
impl CloseReadiness {
    fn common(self) -> Option<CommonCloseToken> {
        match self {
            Self::Absent => None,
            Self::Waiting(token) | Self::Ready(token) => Some(token),
        }
    }
}
#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub(crate) struct PendingRequest {
    pub token: RequestToken,
    pub phase: Phase,
    pub flags: u32,
    pub common: Option<CommonCloseToken>,
}
#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub(crate) enum Event {
    Availability {
        generation: u64,
        state: Availability,
    },
    /// Informational only. MUST NOT invoke Quit, open review or stop any work.
    /// is_ok merely records the response to this signal, never exit permission.
    Response {
        request: PendingRequest,
        is_ok: bool,
    },
    /// Invalidate only this OS association. Do not cancel a user-owned Commit/
    /// Roll Back/Stop already selected in the common graph. Never continue Quit
    /// from a former OS signal after this event.
    Cancelled { request: PendingRequest },
    /// Stop/forced logout offers no guaranteed review time. No known database
    /// outcome or successful draft flush may be inferred.
    Forced { generation: u64 },
}
#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub(crate) struct Reply {
    pub request: PendingRequest,
    pub is_ok: bool,
    pub reason: &'static str,
}
pub(crate) const REVIEW_REASON: &str =
    "DBeer has not completed its close review. Return to DBeer and close it before logging out.";

pub(crate) struct Policy {
    registration: u64,
    sequence: u64,
    active: Option<PendingRequest>,
}
impl Policy {
    pub(crate) fn new(registration: u64) -> Self {
        Self {
            registration,
            sequence: 0,
            active: None,
        }
    }
    /// Repeated requests coalesce to the same token, even when Query advances
    /// to End. Once Cancel/service loss occurs, that token can never be reused.
    pub(crate) fn signal(
        &mut self,
        signal: Signal,
        readiness: CloseReadiness,
    ) -> (Option<Reply>, Option<Event>) {
        match signal {
            Signal::Cancel => (
                None,
                self.active
                    .take()
                    .map(|request| Event::Cancelled { request }),
            ),
            Signal::Stop => {
                self.active = None;
                (
                    None,
                    Some(Event::Forced {
                        generation: self.registration,
                    }),
                )
            }
            Signal::Query(flags) | Signal::End(flags) => {
                let phase = if matches!(signal, Signal::Query(_)) {
                    Phase::Query
                } else {
                    Phase::End
                };
                let token = if let Some(active) = self.active {
                    active.token
                } else {
                    // Exhaustion never returns an affirmative response or reuses
                    // a previous sequence. The client reconnects with a new
                    // registration if this unreachable bound is encountered.
                    let Some(sequence) = self.sequence.checked_add(1) else {
                        return (
                            None,
                            Some(Event::Availability {
                                generation: self.registration,
                                state: Availability::Unavailable,
                            }),
                        );
                    };
                    self.sequence = sequence;
                    RequestToken {
                        registration: self.registration,
                        sequence,
                    }
                };
                let common = self
                    .active
                    .and_then(|request| request.common)
                    .or(readiness.common());
                let request = PendingRequest {
                    token,
                    phase,
                    flags,
                    common,
                };
                self.active = Some(request);
                // If a different common flow appeared, it cannot authorize a
                // response bound to the old one. A forced flag does not waive
                // review; GNOME may ignore a negative response regardless.
                let is_ok =
                    matches!(readiness, CloseReadiness::Ready(token) if Some(token) == common);
                (
                    Some(Reply {
                        request,
                        is_ok,
                        reason: if is_ok { "" } else { REVIEW_REASON },
                    }),
                    None,
                )
            }
        }
    }
    pub(crate) fn lost(&mut self) -> Option<Event> {
        self.active
            .take()
            .map(|request| Event::Cancelled { request })
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    #[test]
    fn unreviewed_repeated_query_is_negative_and_never_allocates_common_close() {
        let mut policy = Policy::new(8);
        let (one, event) = policy.signal(Signal::Query(0), CloseReadiness::Absent);
        assert!(event.is_none());
        let one = one.unwrap();
        assert!(!one.is_ok);
        assert!(one.request.common.is_none());
        let two = policy
            .signal(Signal::Query(0), CloseReadiness::Absent)
            .0
            .unwrap();
        assert_eq!(one.request.token, two.request.token);
        assert_eq!(two.reason, REVIEW_REASON);
    }
    #[test]
    fn common_token_and_readiness_remain_the_only_authority() {
        let mut policy = Policy::new(1);
        let token = CommonCloseToken(55);
        let query = policy
            .signal(Signal::Query(0), CloseReadiness::Waiting(token))
            .0
            .unwrap();
        assert!(!query.is_ok);
        let end = policy
            .signal(Signal::End(0), CloseReadiness::Ready(token))
            .0
            .unwrap();
        assert!(end.is_ok);
        assert_eq!(query.request.token, end.request.token);
        let stale = policy
            .signal(Signal::End(0), CloseReadiness::Ready(CommonCloseToken(56)))
            .0
            .unwrap();
        assert!(!stale.is_ok);
        assert_eq!(stale.request.common, Some(token));
    }
    #[test]
    fn os_cancel_invalidates_association_and_new_query_never_inherits_ready_state() {
        let mut policy = Policy::new(1);
        let common = CommonCloseToken(1);
        let old = policy
            .signal(Signal::Query(0), CloseReadiness::Waiting(common))
            .0
            .unwrap();
        assert_eq!(
            policy
                .signal(Signal::Cancel, CloseReadiness::Ready(common))
                .1,
            Some(Event::Cancelled {
                request: old.request
            })
        );
        assert!(
            policy
                .signal(Signal::Cancel, CloseReadiness::Absent)
                .1
                .is_none()
        );
        let new = policy
            .signal(Signal::Query(0), CloseReadiness::Absent)
            .0
            .unwrap();
        assert_ne!(old.request.token, new.request.token);
        assert!(!new.is_ok);
        assert!(new.request.common.is_none());
    }
    #[test]
    fn service_loss_and_forced_stop_do_not_claim_review_or_transaction_outcome() {
        let mut policy = Policy::new(9);
        let request = policy
            .signal(Signal::Query(1), CloseReadiness::Absent)
            .0
            .unwrap();
        assert!(!request.is_ok);
        assert_eq!(
            policy.lost(),
            Some(Event::Cancelled {
                request: request.request
            })
        );
        assert_eq!(
            policy.signal(Signal::Stop, CloseReadiness::Absent).1,
            Some(Event::Forced { generation: 9 })
        );
        let other = Policy::new(10)
            .signal(Signal::Query(0), CloseReadiness::Absent)
            .0
            .unwrap();
        assert_ne!(
            request.request.token.registration,
            other.request.token.registration
        );
    }
}
