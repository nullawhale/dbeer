//! Actual GNOME 46-compatible session-bus adapter. Only this owned connection's
//! registered client is addressed; no logout/reboot/inhibit/kill methods exist.

use super::{Availability, CloseReadiness, Event, PendingRequest, Policy, Signal};
use async_channel::{Receiver, Sender};
use smol::{Timer, future, stream::StreamExt};
use std::{
    future::Future,
    sync::{
        Arc, Mutex,
        atomic::{AtomicBool, Ordering},
    },
    thread::{self, JoinHandle},
    time::Duration,
};
use zbus::{
    Connection, MatchRule, Message, MessageStream, Proxy, message::Type, zvariant::OwnedObjectPath,
};

const SERVICE: &str = "org.gnome.SessionManager";
const MANAGER_PATH: &str = "/org/gnome/SessionManager";
const PRIVATE: &str = "org.gnome.SessionManager.ClientPrivate";
const APP_ID: &str = "app.dbeer.DBeer";
const CALL_TIMEOUT: Duration = Duration::from_millis(450);
const CONNECT_TIMEOUT: Duration = Duration::from_secs(2);
const RETRY_DELAY: Duration = Duration::from_secs(2);
const QUEUE_CAPACITY: usize = 32;
static WORKER_ACTIVE: AtomicBool = AtomicBool::new(false);

#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub(crate) enum ClientError {
    AlreadyStarted,
    ThreadStart,
    BusUnavailable,
    Timeout,
    QueueClosed,
    InvalidStartupId,
}
#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub(crate) struct Snapshot {
    pub generation: u64,
    pub availability: Availability,
    pub request: Option<PendingRequest>,
}
struct State {
    snapshot: Snapshot,
    readiness: CloseReadiness,
}
impl Default for State {
    fn default() -> Self {
        Self {
            snapshot: Snapshot {
                generation: 0,
                availability: Availability::Starting,
                request: None,
            },
            readiness: CloseReadiness::Absent,
        }
    }
}

/// Retained common-graph publication ownership survives moving the private
/// client into bounded teardown. It owns no connection/path or exit authority.
#[derive(Clone)]
pub(crate) struct ReadinessPublisher {
    state: Arc<Mutex<State>>,
}
impl ReadinessPublisher {
    pub(crate) fn snapshot(&self) -> Snapshot {
        self.state
            .lock()
            .unwrap_or_else(|e| e.into_inner())
            .snapshot
    }
    pub(crate) fn set(&self, generation: u64, readiness: CloseReadiness) -> bool {
        let mut state = self.state.lock().unwrap_or_else(|e| e.into_inner());
        if state.snapshot.availability != Availability::Registered
            || state.snapshot.generation != generation
        {
            return false;
        }
        state.readiness = readiness;
        true
    }
}

/// Exactly one owned worker and one private session connection at a time.
/// Event overflow is fail-closed: disconnect, clear readiness/association and
/// close the event receiver; snapshot remains authoritative. Callers MUST handle
/// receiver closure as loss, not successful close. Reconnect uses a new generation
/// and cannot resurrect a Ready/Waiting token from the former connection.
pub(crate) struct Client {
    state: Arc<Mutex<State>>,
    shutdown: Sender<()>,
    events: Receiver<Event>,
    done: Receiver<()>,
    worker: Option<JoinHandle<()>>,
}
impl Client {
    /// Start from the UI thread without waiting for D-Bus. Registration success
    /// is reported separately as Availability::Registered, never presumed here.
    pub(crate) fn start(startup_id: String) -> Result<Self, ClientError> {
        if startup_id.len() > 4096 || startup_id.contains('\0') {
            return Err(ClientError::InvalidStartupId);
        }
        if WORKER_ACTIVE
            .compare_exchange(false, true, Ordering::AcqRel, Ordering::Acquire)
            .is_err()
        {
            return Err(ClientError::AlreadyStarted);
        }
        let state = Arc::new(Mutex::new(State::default()));
        let (stop_tx, stop_rx) = async_channel::bounded(1);
        let (events_tx, events_rx) = async_channel::bounded(QUEUE_CAPACITY);
        let (done_tx, done_rx) = async_channel::bounded(1);
        let worker_state = Arc::clone(&state);
        let worker = thread::Builder::new()
            .name("dbeer-session-end".into())
            .spawn(move || {
                struct ActiveGuard;
                impl Drop for ActiveGuard {
                    fn drop(&mut self) {
                        WORKER_ACTIVE.store(false, Ordering::Release);
                    }
                }
                let _guard = ActiveGuard;
                smol::block_on(run(worker_state, stop_rx, events_tx, startup_id));
                _ = done_tx.try_send(());
            })
            .map_err(|_| {
                WORKER_ACTIVE.store(false, Ordering::Release);
                ClientError::ThreadStart
            })?;
        Ok(Self {
            state,
            shutdown: stop_tx,
            events: events_rx,
            done: done_rx,
            worker: Some(worker),
        })
    }
    pub(crate) fn events(&self) -> Receiver<Event> {
        self.events.clone()
    }
    pub(crate) fn publisher(&self) -> ReadinessPublisher {
        ReadinessPublisher {
            state: Arc::clone(&self.state),
        }
    }
    pub(crate) fn snapshot(&self) -> Snapshot {
        self.publisher().snapshot()
    }
    /// Only common graph ownership may supply this. A terminal Ready token is
    /// immutable: it must have completed every review/terminal/ACK/latest flush,
    /// and permit no subsequent source/draft/operation mutations before removal.
    /// This stores no SQL, credentials, results or paths.
    pub(crate) fn set_readiness(&self, generation: u64, readiness: CloseReadiness) -> bool {
        self.publisher().set(generation, readiness)
    }

    /// Await from a UI task during orderly teardown. No UI-thread join while
    /// the worker runs; all D-Bus operations have explicit bounded deadlines.
    pub(crate) async fn shutdown(mut self) {
        _ = self.shutdown.try_send(());
        _ = self.done.recv().await;
        if let Some(worker) = self.worker.take() {
            _ = worker.join();
        }
    }
}
impl Drop for Client {
    fn drop(&mut self) {
        _ = self.shutdown.try_send(());
        self.shutdown.close();
        // Dropping a JoinHandle detaches ONLY this bounded worker. It still
        // sees channel close, unregisters its own client, closes the connection
        // and releases WORKER_ACTIVE; start cannot create overlapping workers.
    }
}

async fn timeout<F: Future<Output = Result<T, E>>, T, E>(
    duration: Duration,
    operation: F,
) -> Result<T, ClientError> {
    future::race(
        async { operation.await.map_err(|_| ClientError::BusUnavailable) },
        async {
            Timer::after(duration).await;
            Err(ClientError::Timeout)
        },
    )
    .await
}
fn availability(
    state: &Arc<Mutex<State>>,
    events: &Sender<Event>,
    generation: u64,
    value: Availability,
) -> Result<(), ClientError> {
    {
        let mut state = state.lock().unwrap_or_else(|e| e.into_inner());
        state.snapshot = Snapshot {
            generation,
            availability: value,
            request: None,
        };
        state.readiness = CloseReadiness::Absent;
    }
    events
        .try_send(Event::Availability {
            generation,
            state: value,
        })
        .map_err(|_| ClientError::QueueClosed)
}
fn emit(
    state: &Arc<Mutex<State>>,
    events: &Sender<Event>,
    event: Event,
) -> Result<(), ClientError> {
    {
        let mut state = state.lock().unwrap_or_else(|e| e.into_inner());
        match event {
            Event::Response { request, .. } => state.snapshot.request = Some(request),
            Event::Cancelled { .. } | Event::Forced { .. } => {
                state.snapshot.request = None;
                state.readiness = CloseReadiness::Absent;
            }
            Event::Availability { .. } => {}
        }
    }
    events.try_send(event).map_err(|_| ClientError::QueueClosed)
}
async fn run(
    state: Arc<Mutex<State>>,
    stop: Receiver<()>,
    events: Sender<Event>,
    startup_id: String,
) {
    let mut generation = 0u64;
    loop {
        if stop.is_closed() || stop.try_recv().is_ok() {
            break;
        }
        let Some(next) = generation.checked_add(1) else {
            break;
        };
        generation = next;
        if availability(&state, &events, generation, Availability::Starting).is_err() {
            break;
        }
        // Do not cancel this future from outside: its scoped teardown must
        // unregister the captured path. Setup and each I/O step are bounded;
        // the registered event loop observes stop directly.
        let outcome = registration(&state, &stop, &events, &startup_id, generation).await;
        if outcome == Ok(()) {
            break;
        }
        let previous = state
            .lock()
            .unwrap_or_else(|e| e.into_inner())
            .snapshot
            .availability;
        let unavailable = if previous == Availability::Registered {
            Availability::ServiceLost
        } else {
            Availability::Unavailable
        };
        if availability(&state, &events, generation, unavailable).is_err() {
            break;
        }
        if future::race(
            async {
                _ = stop.recv().await;
                true
            },
            async {
                Timer::after(RETRY_DELAY).await;
                false
            },
        )
        .await
        {
            break;
        }
    }
    // Snapshot changes even when the bounded notification queue has overflowed.
    _ = availability(&state, &events, generation, Availability::Stopped);
    events.close();
}

async fn registration(
    state: &Arc<Mutex<State>>,
    stop: &Receiver<()>,
    events: &Sender<Event>,
    startup_id: &str,
    generation: u64,
) -> Result<(), ClientError> {
    let builder = zbus::connection::Builder::session()
        .map_err(|_| ClientError::BusUnavailable)?
        .max_queued(QUEUE_CAPACITY);
    let connection = timeout(CONNECT_TIMEOUT, builder.build()).await?;
    let result = run_registration(&connection, state, stop, events, startup_id, generation).await;
    // Never leave our private bus connection behind after error or teardown.
    _ = timeout(CALL_TIMEOUT, connection.close()).await;
    result
}

async fn run_registration(
    connection: &Connection,
    state: &Arc<Mutex<State>>,
    stop: &Receiver<()>,
    events: &Sender<Event>,
    startup_id: &str,
    generation: u64,
) -> Result<(), ClientError> {
    let dbus = timeout(CALL_TIMEOUT, zbus::fdo::DBusProxy::new(connection)).await?;
    let service = SERVICE
        .try_into()
        .map_err(|_| ClientError::BusUnavailable)?;
    let owner = timeout(CALL_TIMEOUT, dbus.get_name_owner(service)).await?;
    // Watch the well-known service before RegisterClient. Native calls/signals
    // are pinned to its unique owner, so a replacement service never receives
    // the former client's response or UnregisterClient.
    let watched = timeout(
        CALL_TIMEOUT,
        Proxy::new(connection, SERVICE, MANAGER_PATH, SERVICE),
    )
    .await?;
    let mut owners = timeout(CALL_TIMEOUT, watched.receive_owner_changed()).await?;
    let manager = timeout(
        CALL_TIMEOUT,
        Proxy::new(connection, owner.as_str(), MANAGER_PATH, SERVICE),
    )
    .await?;
    // Subscribe before registration: signals arriving with the method reply
    // cannot fall into a subscribe-after-register gap. Filter the returned own
    // path below; ignore other clients sharing the same manager connection.
    let rule = MatchRule::builder()
        .msg_type(Type::Signal)
        .sender(owner.as_str())
        .map_err(|_| ClientError::BusUnavailable)?
        .interface(PRIVATE)
        .map_err(|_| ClientError::BusUnavailable)?
        .build();
    let mut signals = timeout(
        CALL_TIMEOUT,
        MessageStream::for_match_rule(rule, connection, Some(QUEUE_CAPACITY)),
    )
    .await?;
    let path: OwnedObjectPath = timeout(
        CALL_TIMEOUT,
        manager.call("RegisterClient", &(APP_ID, startup_id)),
    )
    .await?;
    let client = timeout(
        CALL_TIMEOUT,
        Proxy::new(connection, owner.as_str(), path.as_str(), PRIVATE),
    )
    .await;
    let mut policy = Policy::new(generation);
    let result = async {
        let client = client?;
        // A service switch during setup invalidates the newly received path.
        let current = timeout(
            CALL_TIMEOUT,
            dbus.get_name_owner(
                SERVICE
                    .try_into()
                    .map_err(|_| ClientError::BusUnavailable)?,
            ),
        )
        .await?;
        if current != owner {
            return Err(ClientError::BusUnavailable);
        }
        availability(state, events, generation, Availability::Registered)?;
        enum Input {
            Stop,
            Lost,
            Message(Option<Result<Message, zbus::Error>>),
        }
        loop {
            let input = future::race(
                async {
                    _ = stop.recv().await;
                    Input::Stop
                },
                future::race(
                    async {
                        _ = owners.next().await;
                        Input::Lost
                    },
                    async { Input::Message(signals.next().await) },
                ),
            )
            .await;
            let message = match input {
                Input::Stop => return Ok(()),
                Input::Lost | Input::Message(None | Some(Err(_))) => {
                    return Err(ClientError::BusUnavailable);
                }
                Input::Message(Some(Ok(message))) => message,
            };
            if message.header().path().map(|p| p.as_str()) != Some(path.as_str()) {
                continue;
            }
            let Some(signal) = decode(&message)? else {
                continue;
            };
            let readiness = state.lock().unwrap_or_else(|e| e.into_inner()).readiness;
            let (reply, event) = policy.signal(signal, readiness);
            if let Some(event) = event {
                emit(state, events, event)?;
            }
            if let Some(reply) = reply {
                // No UI or helper work precedes the response. 450ms timeout
                // fits the documented 1-second QueryEndSession requirement.
                let _: () = timeout(
                    CALL_TIMEOUT,
                    client.call("EndSessionResponse", &(reply.is_ok, reply.reason)),
                )
                .await?;
                emit(
                    state,
                    events,
                    Event::Response {
                        request: reply.request,
                        is_ok: reply.is_ok,
                    },
                )?;
            }
        }
    }
    .await;
    if let Some(event) = policy.lost() {
        _ = emit(state, events, event);
    }
    // Exact registration, same unique owner, bounded teardown. If GNOME has
    // already disappeared, a failed reply is not treated as an unregister ACK.
    let _: Result<(), ClientError> =
        timeout(CALL_TIMEOUT, manager.call("UnregisterClient", &(&path,))).await;
    result
}
fn decode(message: &Message) -> Result<Option<Signal>, ClientError> {
    let header = message.header();
    let member = header.member().map(|m| m.as_str());
    let signal = match member {
        Some("QueryEndSession") => Signal::Query(
            message
                .body()
                .deserialize::<u32>()
                .map_err(|_| ClientError::BusUnavailable)?,
        ),
        Some("EndSession") => Signal::End(
            message
                .body()
                .deserialize::<u32>()
                .map_err(|_| ClientError::BusUnavailable)?,
        ),
        Some("CancelEndSession") => {
            message
                .body()
                .deserialize::<()>()
                .map_err(|_| ClientError::BusUnavailable)?;
            Signal::Cancel
        }
        Some("Stop") => {
            message
                .body()
                .deserialize::<()>()
                .map_err(|_| ClientError::BusUnavailable)?;
            Signal::Stop
        }
        _ => return Ok(None),
    };
    Ok(Some(signal))
}

#[cfg(test)]
mod tests {
    use super::*;
    #[test]
    fn actual_signal_decoder_uses_unsigned_flags_and_empty_cancel_stop() {
        let query = Message::signal(
            "/org/gnome/SessionManager/Client1",
            PRIVATE,
            "QueryEndSession",
        )
        .unwrap()
        .build(&1u32)
        .unwrap();
        assert_eq!(decode(&query), Ok(Some(Signal::Query(1))));
        let bad = Message::signal(
            "/org/gnome/SessionManager/Client1",
            PRIVATE,
            "QueryEndSession",
        )
        .unwrap()
        .build(&"1")
        .unwrap();
        assert_eq!(decode(&bad), Err(ClientError::BusUnavailable));
        let cancel = Message::signal(
            "/org/gnome/SessionManager/Client1",
            PRIVATE,
            "CancelEndSession",
        )
        .unwrap()
        .build(&())
        .unwrap();
        assert_eq!(decode(&cancel), Ok(Some(Signal::Cancel)));
    }
    #[test]
    fn common_readiness_owner_survives_client_teardown_move_and_rejects_old_registration() {
        let state = Arc::new(Mutex::new(State::default()));
        let publisher = ReadinessPublisher {
            state: Arc::clone(&state),
        };
        let (events, _receiver) = async_channel::bounded(8);
        availability(&state, &events, 4, Availability::Registered).unwrap();
        let token = super::super::CommonCloseToken(8);
        assert!(publisher.set(4, CloseReadiness::Ready(token)));
        let retained = publisher.clone();
        drop(publisher);
        assert!(retained.set(4, CloseReadiness::Waiting(token)));
        availability(&state, &events, 5, Availability::Registered).unwrap();
        assert!(!retained.set(4, CloseReadiness::Ready(token)));
        assert_eq!(state.lock().unwrap().readiness, CloseReadiness::Absent);
        availability(&state, &events, 5, Availability::ServiceLost).unwrap();
        assert!(!retained.set(5, CloseReadiness::Ready(token)));
    }
    #[test]
    fn overflow_closes_the_adapter_instead_of_silently_dropping_cancellation() {
        let state = Arc::new(Mutex::new(State::default()));
        let (tx, _rx) = async_channel::bounded(1);
        availability(&state, &tx, 1, Availability::Registered).unwrap();
        assert_eq!(
            availability(&state, &tx, 1, Availability::ServiceLost),
            Err(ClientError::QueueClosed)
        );
        assert_eq!(
            state.lock().unwrap().snapshot.availability,
            Availability::ServiceLost
        );
        assert_eq!(state.lock().unwrap().readiness, CloseReadiness::Absent);
    }
}

#[cfg(all(test, unix))]
#[path = "gnome_tests.rs"]
mod protocol_tests;
