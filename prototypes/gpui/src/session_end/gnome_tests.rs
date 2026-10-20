//! Prepared native-protocol case; never connects to the operator's session bus.
//! Run explicitly on a host with dbus-daemon at final integration.
use super::*;
use std::{
    io::{BufRead, BufReader},
    process::{Child, Command, Stdio},
};
const CLIENT_PATH: &str = "/org/gnome/SessionManager/ClientDBeerTest";

struct PrivateBus {
    child: Child,
    address: String,
}
impl PrivateBus {
    fn start() -> Self {
        let mut child = Command::new("dbus-daemon")
            .args(["--session", "--nofork", "--nopidfile", "--print-address=1"])
            .stdin(Stdio::null())
            .stdout(Stdio::piped())
            .stderr(Stdio::null())
            .spawn()
            .expect("isolated dbus-daemon is required; no operator session-bus fallback");
        let stdout = child.stdout.take().unwrap();
        let (tx, rx) = std::sync::mpsc::sync_channel(1);
        let reader = thread::spawn(move || {
            let mut address = String::new();
            let result = BufReader::new(stdout).read_line(&mut address);
            _ = tx.send((result, address));
        });
        let line = rx.recv_timeout(Duration::from_secs(3));
        if line.is_err() {
            _ = child.kill();
            _ = child.wait();
            _ = reader.join();
            panic!("owned private test bus did not become ready");
        }
        let (result, address) = line.unwrap();
        result.unwrap();
        _ = reader.join();
        let address = address.trim().to_owned();
        assert!(address.starts_with("unix:"));
        Self { child, address }
    }
}
impl Drop for PrivateBus {
    fn drop(&mut self) {
        _ = self.child.kill();
        _ = self.child.wait();
    }
}
struct FakeManager {
    registered: Sender<(String, String)>,
    unregistered: Sender<String>,
}
#[zbus::interface(name = "org.gnome.SessionManager")]
impl FakeManager {
    fn register_client(&self, app_id: &str, startup_id: &str) -> OwnedObjectPath {
        self.registered
            .try_send((app_id.to_owned(), startup_id.to_owned()))
            .unwrap();
        CLIENT_PATH.try_into().unwrap()
    }
    fn unregister_client(&self, client_id: OwnedObjectPath) {
        self.unregistered.try_send(client_id.to_string()).unwrap();
    }
}
struct FakeClient {
    replies: Sender<(bool, String)>,
}
#[zbus::interface(name = "org.gnome.SessionManager.ClientPrivate")]
impl FakeClient {
    fn end_session_response(&self, is_ok: bool, reason: &str) {
        self.replies.try_send((is_ok, reason.to_owned())).unwrap();
    }
}
async fn receive<T>(receiver: &Receiver<T>) -> T {
    timeout(Duration::from_secs(3), receiver.recv())
        .await
        .unwrap()
}

#[test]
#[ignore = "requires owned private dbus-daemon; execute explicitly at final integration"]
fn private_bus_real_registration_negative_reply_cancel_repeat_owner_loss_and_unregistration() {
    let bus = PrivateBus::start();
    smol::block_on(async {
        let (registered_tx, registered_rx) = async_channel::bounded(4);
        let (unregistered_tx, unregistered_rx) = async_channel::bounded(4);
        let (reply_tx, reply_rx) = async_channel::bounded(16);
        let service = timeout(
            CONNECT_TIMEOUT,
            zbus::connection::Builder::address(bus.address.as_str())
                .unwrap()
                .name(SERVICE)
                .unwrap()
                .serve_at(
                    MANAGER_PATH,
                    FakeManager {
                        registered: registered_tx,
                        unregistered: unregistered_tx,
                    },
                )
                .unwrap()
                .serve_at(CLIENT_PATH, FakeClient { replies: reply_tx })
                .unwrap()
                .build(),
        )
        .await
        .unwrap();
        let client = timeout(
            CONNECT_TIMEOUT,
            zbus::connection::Builder::address(bus.address.as_str())
                .unwrap()
                .build(),
        )
        .await
        .unwrap();
        let destination = client.unique_name().unwrap().to_owned();
        let state = Arc::new(Mutex::new(State::default()));
        let worker_state = Arc::clone(&state);
        let (_stop_tx, stop_rx) = async_channel::bounded(1);
        let (events_tx, events_rx) = async_channel::bounded(32);
        let task = smol::spawn(async move {
            run_registration(
                &client,
                &worker_state,
                &stop_rx,
                &events_tx,
                "fixture-start",
                71,
            )
            .await
        });
        assert_eq!(
            receive(&registered_rx).await,
            (APP_ID.into(), "fixture-start".into())
        );
        assert_eq!(
            receive(&events_rx).await,
            Event::Availability {
                generation: 71,
                state: Availability::Registered
            }
        );
        service
            .emit_signal(
                Some(&destination),
                CLIENT_PATH,
                PRIVATE,
                "QueryEndSession",
                &0u32,
            )
            .await
            .unwrap();
        assert_eq!(
            receive(&reply_rx).await,
            (false, super::super::REVIEW_REASON.into())
        );
        let first = match receive(&events_rx).await {
            Event::Response {
                request,
                is_ok: false,
            } => request,
            event => panic!("unexpected safe event {event:?}"),
        };
        service
            .emit_signal(
                Some(&destination),
                CLIENT_PATH,
                PRIVATE,
                "QueryEndSession",
                &0u32,
            )
            .await
            .unwrap();
        assert!(!receive(&reply_rx).await.0);
        let repeated = match receive(&events_rx).await {
            Event::Response { request, .. } => request,
            _ => panic!("response missing"),
        };
        assert_eq!(first.token, repeated.token);
        service
            .emit_signal(
                Some(&destination),
                CLIENT_PATH,
                PRIVATE,
                "CancelEndSession",
                &(),
            )
            .await
            .unwrap();
        assert_eq!(
            receive(&events_rx).await,
            Event::Cancelled { request: repeated }
        );
        assert_eq!(state.lock().unwrap().readiness, CloseReadiness::Absent);
        let common = super::super::CommonCloseToken(101);
        state.lock().unwrap().readiness = CloseReadiness::Waiting(common);
        service
            .emit_signal(
                Some(&destination),
                CLIENT_PATH,
                PRIVATE,
                "QueryEndSession",
                &0u32,
            )
            .await
            .unwrap();
        assert!(!receive(&reply_rx).await.0);
        let newer = match receive(&events_rx).await {
            Event::Response { request, .. } => request,
            _ => panic!("response missing"),
        };
        assert_ne!(first.token, newer.token);
        state.lock().unwrap().readiness = CloseReadiness::Ready(common);
        service
            .emit_signal(
                Some(&destination),
                CLIENT_PATH,
                PRIVATE,
                "EndSession",
                &0u32,
            )
            .await
            .unwrap();
        assert_eq!(receive(&reply_rx).await, (true, String::new()));
        let end = match receive(&events_rx).await {
            Event::Response {
                request,
                is_ok: true,
            } => request,
            _ => panic!("ready response missing"),
        };
        assert_eq!(newer.token, end.token);
        service.release_name(SERVICE).await.unwrap();
        assert_eq!(receive(&events_rx).await, Event::Cancelled { request: end });
        assert_eq!(receive(&unregistered_rx).await, CLIENT_PATH);
        assert_eq!(
            timeout(Duration::from_secs(3), async { Ok::<_, ()>(task.await) })
                .await
                .unwrap(),
            Err(ClientError::BusUnavailable)
        );
        _ = service.close().await;
    });
}
