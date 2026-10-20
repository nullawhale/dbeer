//! One exact owned child, three bounded workers, and no database transport.
use super::{
    Error, Result,
    framing::{self, Framer},
};
use async_channel::{Receiver, Sender};
use serde_json::{Value, json};
use std::{
    collections::HashMap,
    ffi::{OsStr, OsString},
    io::{Read, Write},
    path::Path,
    process::{Child, Command, Stdio},
    sync::{
        Arc, Mutex, MutexGuard, Weak,
        atomic::{AtomicBool, AtomicU64, AtomicUsize, Ordering},
    },
    thread::{self, JoinHandle},
    time::{Duration, Instant},
};

const MAX_PENDING: usize = 32;
const MAX_QUEUED_BYTES: usize = 8 * 1024 * 1024;
const MAX_NOTIFICATION_BYTES: usize = 8 * 1024 * 1024;
static NEXT_GENERATION: AtomicU64 = AtomicU64::new(1);

fn lock<T>(value: &Mutex<T>) -> MutexGuard<'_, T> {
    value.lock().unwrap_or_else(|poison| poison.into_inner())
}

/// Do not inherit PATH, HOME, database variables, loader overrides, proxy settings,
/// Go runtime options, or credentials. An absolute executable needs no PATH lookup.
/// Windows' loader and Go runtime require the OS directory and temp locations.
pub fn sanitized_environment(
    environment: impl IntoIterator<Item = (OsString, OsString)>,
    windows: bool,
) -> Vec<(OsString, OsString)> {
    let mut selected = HashMap::<String, OsString>::new();
    if windows {
        for (key, value) in environment {
            let Some(key) = key.to_str() else {
                continue;
            };
            let key = key.to_ascii_uppercase();
            if matches!(key.as_str(), "SYSTEMROOT" | "WINDIR" | "TEMP" | "TMP")
                && !value.is_empty()
                && value.len() <= 32_768
                && !value.to_string_lossy().contains('\0')
            {
                selected.entry(key).or_insert(value);
            }
        }
        if !selected.contains_key("SYSTEMROOT")
            && let Some(value) = selected.get("WINDIR").cloned()
        {
            selected.insert("SYSTEMROOT".into(), value);
        }
        if !selected.contains_key("WINDIR")
            && let Some(value) = selected.get("SYSTEMROOT").cloned()
        {
            selected.insert("WINDIR".into(), value);
        }
    }
    let mut result: Vec<_> = selected
        .into_iter()
        .map(|(k, v)| (OsString::from(k), v))
        .collect();
    // Stable, non-inherited locale. The service only parses UTF-8 editor input.
    result.push((OsString::from("LANG"), OsString::from("en_US.UTF-8")));
    result.push((OsString::from("LC_ALL"), OsString::from("en_US.UTF-8")));
    result.sort_by(|a, b| a.0.cmp(&b.0));
    result
}

struct Pending {
    response: Sender<Result<Value>>,
    deadline: Instant,
}
struct Notification {
    value: Value,
    bytes: usize,
}
#[derive(Default)]
struct State {
    pending: HashMap<u64, Pending>,
    notifications: HashMap<String, Notification>,
    notification_bytes: usize,
    failure: Option<Error>,
}
struct Shared {
    state: Mutex<State>,
    child: Mutex<Option<Child>>,
    writer: Sender<Vec<u8>>,
    control: Sender<Vec<u8>>,
    queued_bytes: AtomicUsize,
    closing: AtomicBool,
    next_id: AtomicU64,
}
impl Shared {
    fn failure(&self) -> Option<Error> {
        lock(&self.state).failure
    }

    fn fail(&self, error: Error) {
        let mut state = lock(&self.state);
        if state.failure.is_none() {
            state.failure = Some(error);
        }
        for (_, pending) in state.pending.drain() {
            let _ = pending.response.try_send(Err(error));
        }
        state.notifications.clear();
        state.notification_bytes = 0;
        drop(state);
        self.writer.close();
        self.control.close();
    }

    fn enqueue(&self, frame: Vec<u8>, control: bool) -> Result<()> {
        if self.closing.load(Ordering::Acquire) {
            return Err(Error::Unavailable);
        }
        if let Some(error) = self.failure() {
            return Err(error);
        }
        let bytes = frame.len();
        // Compare/exchange keeps Rust 1.92 compatibility: fetch_update was
        // renamed/deprecated by the current development toolchain.
        let mut queued = self.queued_bytes.load(Ordering::Acquire);
        loop {
            if queued.saturating_add(bytes) > MAX_QUEUED_BYTES {
                return Err(Error::Backpressure);
            }
            match self.queued_bytes.compare_exchange_weak(
                queued,
                queued + bytes,
                Ordering::AcqRel,
                Ordering::Acquire,
            ) {
                Ok(_) => break,
                Err(current) => queued = current,
            }
        }
        let result = if control {
            self.control.try_send(frame)
        } else {
            self.writer.try_send(frame)
        };
        if result.is_err() {
            self.queued_bytes.fetch_sub(bytes, Ordering::AcqRel);
            return Err(Error::Backpressure);
        }
        Ok(())
    }

    fn cancel(&self, id: u64, error: Error) {
        let removed = lock(&self.state).pending.remove(&id);
        if let Some(pending) = removed {
            let _ = pending.response.try_send(Err(error));
            let frame = framing::encode(
                &json!({"jsonrpc":"2.0","method":"$/cancelRequest","params":{"id":id}}),
            );
            if frame.and_then(|frame| self.enqueue(frame, true)).is_err() {
                // Refuse the optional service rather than silently losing bounded
                // cancellation control behind a child that stopped reading.
                self.fail(Error::Backpressure);
            }
        }
    }

    fn receive(&self, body: Vec<u8>) -> Result<()> {
        // serde_json's recursion limit bounds nested peer-controlled structures.
        let message = framing::decode(&body)?;
        let object = message.as_object().ok_or(Error::InvalidMessage)?;
        if object.get("jsonrpc").and_then(Value::as_str) != Some("2.0") {
            return Err(Error::InvalidMessage);
        }
        if object.contains_key("id") {
            let id = object["id"]
                .as_u64()
                .filter(|id| *id > 0)
                .ok_or(Error::InvalidMessage)?;
            if object.contains_key("method")
                || object.contains_key("result") == object.contains_key("error")
            {
                return Err(Error::InvalidMessage);
            }
            let pending = lock(&self.state).pending.remove(&id);
            if let Some(pending) = pending {
                let result = if object.contains_key("error") {
                    Err(Error::Remote)
                } else {
                    Ok(object["result"].clone())
                };
                let _ = pending.response.try_send(result);
            }
            // Late replies to timed-out/cancelled requests cannot regain ownership.
            return Ok(());
        }
        let method = object
            .get("method")
            .and_then(Value::as_str)
            .ok_or(Error::InvalidMessage)?;
        if method != "textDocument/publishDiagnostics" {
            return Ok(());
        }
        let uri = object
            .get("params")
            .and_then(|v| v.get("uri"))
            .and_then(Value::as_str)
            .filter(|uri| !uri.is_empty() && uri.len() <= 4096)
            .ok_or(Error::InvalidMessage)?
            .to_owned();
        let mut state = lock(&self.state);
        if let Some(old) = state.notifications.remove(&uri) {
            state.notification_bytes -= old.bytes;
        }
        if state.notifications.len() >= 32
            || state.notification_bytes.saturating_add(body.len()) > MAX_NOTIFICATION_BYTES
        {
            return Err(Error::Limit);
        }
        state.notification_bytes += body.len();
        state.notifications.insert(
            uri,
            Notification {
                value: message,
                bytes: body.len(),
            },
        );
        Ok(())
    }

    /// Child::kill addresses the original OS child handle; no PID search or
    /// process-name termination can ever target another helper/session.
    fn stop_child(&self) {
        if let Some(mut child) = lock(&self.child).take() {
            match child.try_wait() {
                Ok(Some(_)) => {}
                _ => {
                    if child.kill().is_ok() {
                        let _ = child.wait();
                    } else {
                        let _ = child.try_wait();
                    }
                }
            }
        }
    }
}

struct Inner {
    shared: Arc<Shared>,
    workers: Mutex<Vec<JoinHandle<()>>>,
    generation: u64,
    _product_helper: Option<crate::product_identity::VerifiedHelper>,
}
impl Inner {
    fn stop(&self) {
        self.shared.closing.store(true, Ordering::Release);
        self.shared.fail(Error::Unavailable);
        self.shared.stop_child();
        for worker in lock(&self.workers).drain(..) {
            let _ = worker.join();
        }
    }
}
impl Drop for Inner {
    fn drop(&mut self) {
        self.stop();
    }
}

#[derive(Clone)]
pub(super) struct Transport {
    inner: Arc<Inner>,
}

/// Dropping the pending future cancels the exact request. There is no detached
/// timeout task or thread per keystroke/request.
pub struct Request {
    id: u64,
    shared: Weak<Shared>,
    response: Receiver<Result<Value>>,
}
impl Request {
    pub async fn finish(self) -> Result<Value> {
        self.response.recv().await.map_err(|_| Error::Unavailable)?
    }
    pub fn cancel(&self) {
        if let Some(shared) = self.shared.upgrade() {
            shared.cancel(self.id, Error::Cancelled);
        }
    }
}
impl Drop for Request {
    fn drop(&mut self) {
        self.cancel();
    }
}

impl Transport {
    /// Spawn is filesystem/process work. Call on an executor worker, never from
    /// the GPUI render/input thread. Arguments cannot be supplied by UI text.
    pub(super) fn spawn(path: impl AsRef<Path>) -> Result<Self> {
        let path = path.as_ref();
        if !path.is_absolute() || !path.is_file() {
            return Err(Error::Unavailable);
        }
        let mut product_helper =
            crate::product_identity::prepare_helper(path).map_err(|_| Error::Unavailable)?;
        let execution_path = if let Some(verified) = product_helper.as_mut() {
            verified.verify().map_err(|_| Error::Unavailable)?;
            verified.execution_path()
        } else {
            path.to_owned()
        };
        let mut command = Command::new(execution_path);
        command
            .arg(OsStr::new("--language-server"))
            .env_clear()
            .envs(sanitized_environment(
                std::env::vars_os(),
                cfg!(target_os = "windows"),
            ))
            .stdin(Stdio::piped())
            .stdout(Stdio::piped())
            .stderr(Stdio::null());
        // The offline service cannot use a working-directory executable search.
        if let Some(parent) = path.parent() {
            command.current_dir(parent);
        }
        #[cfg(target_os = "windows")]
        {
            use std::os::windows::process::CommandExt;
            command.creation_flags(0x0800_0000); // CREATE_NO_WINDOW
        }
        let mut child = command.spawn().map_err(|_| Error::Unavailable)?;
        if product_helper
            .as_mut()
            .is_some_and(|verified| verified.verify().is_err())
        {
            _ = child.kill();
            _ = child.wait();
            return Err(Error::Unavailable);
        }
        let (Some(mut input), Some(mut output)) = (child.stdin.take(), child.stdout.take()) else {
            let _ = child.kill();
            let _ = child.wait();
            return Err(Error::Unavailable);
        };
        let (writer, writes) = async_channel::bounded(32);
        let (control, controls) = async_channel::bounded(64);
        let shared = Arc::new(Shared {
            state: Mutex::new(State::default()),
            child: Mutex::new(Some(child)),
            writer,
            control,
            queued_bytes: AtomicUsize::new(0),
            closing: AtomicBool::new(false),
            next_id: AtomicU64::new(1),
        });
        let transport = Self {
            inner: Arc::new(Inner {
                shared: shared.clone(),
                workers: Mutex::new(Vec::new()),
                generation: NEXT_GENERATION.fetch_add(1, Ordering::Relaxed),
                _product_helper: product_helper,
            }),
        };
        let writer_shared = shared.clone();
        transport.worker("dbeer-lsp-input", move || {
            loop {
                let frame = match controls.try_recv() {
                    Ok(frame) => frame,
                    Err(_) => {
                        match smol::block_on(smol::future::race(controls.recv(), writes.recv())) {
                            Ok(frame) => frame,
                            Err(_) => break,
                        }
                    }
                };
                if writer_shared.closing.load(Ordering::Acquire)
                    || writer_shared.failure().is_some()
                {
                    break;
                }
                let bytes = frame.len();
                let result = input.write_all(&frame).and_then(|()| input.flush());
                writer_shared
                    .queued_bytes
                    .fetch_sub(bytes, Ordering::AcqRel);
                if result.is_err() {
                    writer_shared.fail(Error::Unavailable);
                    break;
                }
            }
        })?;
        let reader_shared = shared.clone();
        transport.worker("dbeer-lsp-output", move || {
            let mut framer = Framer::default();
            let result = (|| -> Result<()> {
                let mut bytes = [0; framing::READ_CHUNK];
                loop {
                    let count = match output.read(&mut bytes) {
                        Ok(count) => count,
                        Err(error) if error.kind() == std::io::ErrorKind::Interrupted => continue,
                        Err(_) => return Err(Error::Unavailable),
                    };
                    if count == 0 {
                        return framer.finish();
                    }
                    for body in framer.append(&bytes[..count])? {
                        reader_shared.receive(body)?;
                    }
                    if reader_shared.closing.load(Ordering::Acquire) {
                        return Ok(());
                    }
                }
            })();
            reader_shared.fail(result.err().unwrap_or(Error::Unavailable));
        })?;
        transport.worker("dbeer-lsp-lifecycle", move || {
            loop {
                if shared.closing.load(Ordering::Acquire) || shared.failure().is_some() {
                    shared.stop_child();
                    break;
                }
                let exited = lock(&shared.child)
                    .as_mut()
                    .is_none_or(|child| !matches!(child.try_wait(), Ok(None)));
                if exited {
                    shared.fail(Error::Unavailable);
                    shared.stop_child();
                    break;
                }
                let now = Instant::now();
                let expired: Vec<_> = lock(&shared.state)
                    .pending
                    .iter()
                    .filter_map(|(id, pending)| (now >= pending.deadline).then_some(*id))
                    .collect();
                for id in expired {
                    shared.cancel(id, Error::Timeout);
                }
                thread::sleep(Duration::from_millis(10));
            }
        })?;
        Ok(transport)
    }

    fn worker(&self, name: &str, work: impl FnOnce() + Send + 'static) -> Result<()> {
        match thread::Builder::new().name(name.into()).spawn(work) {
            Ok(worker) => {
                lock(&self.inner.workers).push(worker);
                Ok(())
            }
            Err(_) => {
                self.inner.stop();
                Err(Error::Unavailable)
            }
        }
    }

    pub(super) fn generation(&self) -> u64 {
        self.inner.generation
    }
    pub(super) fn available(&self) -> bool {
        !self.inner.shared.closing.load(Ordering::Acquire) && self.inner.shared.failure().is_none()
    }
    pub(super) fn notify_batch(&self, messages: &[Value]) -> Result<()> {
        let mut bytes = Vec::new();
        for message in messages {
            let frame = framing::encode(message)?;
            if bytes.len().saturating_add(frame.len()) > MAX_QUEUED_BYTES {
                return Err(Error::Backpressure);
            }
            bytes.extend(frame);
        }
        self.inner.shared.enqueue(bytes, false)
    }
    pub(super) fn request(
        &self,
        method: &str,
        params: Value,
        timeout: Duration,
    ) -> Result<Request> {
        if timeout.is_zero() || timeout > Duration::from_secs(30) {
            return Err(Error::Limit);
        }
        let shared = &self.inner.shared;
        let id = shared.next_id.fetch_add(1, Ordering::Relaxed);
        if id > i32::MAX as u64 {
            shared.fail(Error::Limit);
            return Err(Error::Limit);
        }
        let frame =
            framing::encode(&json!({"jsonrpc":"2.0","id":id,"method":method,"params":params}))?;
        let (response, receiver) = async_channel::bounded(1);
        {
            let mut state = lock(&shared.state);
            if let Some(error) = state.failure {
                return Err(error);
            }
            if state.pending.len() >= MAX_PENDING {
                return Err(Error::Backpressure);
            }
            state.pending.insert(
                id,
                Pending {
                    response,
                    deadline: Instant::now() + timeout,
                },
            );
        }
        if let Err(error) = shared.enqueue(frame, false) {
            lock(&shared.state).pending.remove(&id);
            return Err(error);
        }
        Ok(Request {
            id,
            shared: Arc::downgrade(shared),
            response: receiver,
        })
    }
    pub(super) fn notifications(&self) -> Vec<Value> {
        let mut state = lock(&self.inner.shared.state);
        state.notification_bytes = 0;
        state
            .notifications
            .drain()
            .map(|(_, notification)| notification.value)
            .collect()
    }
    /// A bounded stdin delivery barrier, including the active write/flush.
    /// LSP didClose is a notification and has no peer acknowledgment.
    pub(super) async fn flush(&self) -> Result<()> {
        let deadline = Instant::now() + Duration::from_millis(400);
        loop {
            if !self.available() {
                return Err(Error::Unavailable);
            }
            if self.inner.shared.queued_bytes.load(Ordering::Acquire) == 0 {
                return Ok(());
            }
            if Instant::now() >= deadline {
                return Err(Error::Timeout);
            }
            smol::Timer::after(Duration::from_millis(5)).await;
        }
    }

    pub(super) async fn shutdown(&self) {
        if self.available() {
            if let Ok(request) = self.request("shutdown", Value::Null, Duration::from_millis(400)) {
                let _ = request.finish().await;
            }
            let _ = self.notify_batch(&[json!({"jsonrpc":"2.0","method":"exit","params":null})]);
            smol::Timer::after(Duration::from_millis(25)).await;
        }
        self.inner.stop();
    }
}
