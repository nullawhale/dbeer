//! One worker owns every LanguageService clone and its final teardown.
use crate::language_service::{self as lsp, *};
use async_channel::{Receiver, Sender};
use std::{
    collections::{HashMap, HashSet, VecDeque},
    path::PathBuf,
    sync::{
        Arc, Mutex, MutexGuard,
        atomic::{AtomicBool, Ordering},
    },
    time::{Duration, Instant},
};

#[derive(Clone)]
pub(super) struct Document {
    pub id: String,
    pub source_revision: u64,
    pub source: Arc<str>,
    pub dialect: Dialect,
    pub context: ContextKey,
    pub catalog: CatalogSnapshot,
}
impl Document {
    fn matches(&self, capture: &DocumentCapture) -> bool {
        self.id == capture.document_id
            && capture.editor_revision == Some(self.source_revision)
            && self.context == capture.context
            && self.dialect == capture.dialect
            && self.source.as_ref() == capture.source()
    }
}
fn lock<T>(value: &Mutex<T>) -> MutexGuard<'_, T> {
    value.lock().unwrap_or_else(|p| p.into_inner())
}
#[derive(Clone, Copy, PartialEq, Eq)]
pub(super) enum Availability {
    Starting,
    Ready,
    Unavailable,
    Stopped,
}
struct Shared {
    inbox: Mutex<Inbox>,
    output: Mutex<Output>,
    wake: Sender<()>,
    stopping: AtomicBool,
    worker_alive: AtomicBool,
    #[cfg(test)]
    observed_wakes: std::sync::atomic::AtomicU64,
}
struct Inbox {
    revision: u64,
    documents: Vec<Document>,
    restart: bool,
    requests: VecDeque<Request>,
    finalization: Option<Finalize>,
}
struct Output {
    revision: u64,
    availability: Availability,
    captures: HashMap<String, DocumentCapture>,
    diagnostics: HashMap<String, DiagnosticsBatch>,
    resume: bool,
}
struct Owner {
    shared: Arc<Shared>,
}
impl Drop for Owner {
    fn drop(&mut self) {
        self.shared.stopping.store(true, Ordering::Release);
        let _ = self.shared.wake.try_send(());
    }
}
#[derive(Clone)]
pub(super) struct Runtime {
    owner: Arc<Owner>,
}
#[derive(Clone, Copy, PartialEq, Eq)]
enum RequestKind {
    Completion,
    Signature,
}
enum Request {
    Completion(DocumentCapture, usize, Sender<Result<CompletionBatch>>),
    Signature(
        DocumentCapture,
        usize,
        Sender<Result<Option<SignatureHelp>>>,
    ),
}
impl Request {
    fn kind(&self) -> RequestKind {
        match self {
            Self::Completion(..) => RequestKind::Completion,
            Self::Signature(..) => RequestKind::Signature,
        }
    }
    fn document_id(&self) -> &str {
        match self {
            Self::Completion(capture, ..) | Self::Signature(capture, ..) => &capture.document_id,
        }
    }
    fn same_kind(&self, other: &Self) -> bool {
        self.kind() == other.kind() && self.document_id() == other.document_id()
    }
}
struct Finalize {
    documents: Vec<String>,
    window: bool,
    reply: Sender<()>,
    captures: Vec<DocumentCapture>,
}
impl Runtime {
    pub fn start(path: PathBuf) -> Self {
        let (wake, receiver) = async_channel::bounded(1);
        let shared = Arc::new(Shared {
            inbox: Mutex::new(Inbox {
                revision: 0,
                documents: Vec::new(),
                restart: false,
                requests: VecDeque::new(),
                finalization: None,
            }),
            output: Mutex::new(Output {
                revision: 0,
                availability: Availability::Starting,
                captures: HashMap::new(),
                diagnostics: HashMap::new(),
                resume: false,
            }),
            wake,
            stopping: AtomicBool::new(false),
            worker_alive: AtomicBool::new(true),
            #[cfg(test)]
            observed_wakes: std::sync::atomic::AtomicU64::new(0),
        });
        let worker = shared.clone();
        if std::thread::Builder::new()
            .name("dbeer-assistance".into())
            .spawn(move || {
                struct Alive(Arc<Shared>);
                impl Drop for Alive {
                    fn drop(&mut self) {
                        self.0.worker_alive.store(false, Ordering::Release);
                    }
                }
                let _alive = Alive(worker.clone());
                worker_loop(path, worker, receiver)
            })
            .is_err()
        {
            shared.worker_alive.store(false, Ordering::Release);
            set_availability(&shared, Availability::Unavailable);
        }
        Self {
            owner: Arc::new(Owner { shared }),
        }
    }
    /// Replace one latest bounded snapshot. No queue, source parsing or DB work.
    pub fn synchronize(&self, revision: u64, documents: Vec<Document>) {
        let mut inbox = lock(&self.owner.shared.inbox);
        if inbox.revision == revision {
            return;
        }
        inbox.revision = revision;
        inbox.documents = documents;
        drop(inbox);
        let _ = self.owner.shared.wake.try_send(());
    }
    pub fn retry(&self) {
        let mut inbox = lock(&self.owner.shared.inbox);
        inbox.restart = true;
        drop(inbox);
        let _ = self.owner.shared.wake.try_send(());
    }
    #[cfg(test)]
    pub fn worker_finished(&self) -> bool {
        !self.owner.shared.worker_alive.load(Ordering::Acquire)
    }
    pub fn take_resume(&self) -> bool {
        std::mem::take(&mut lock(&self.owner.shared.output).resume)
    }
    pub fn availability(&self) -> (u64, Availability) {
        let output = lock(&self.owner.shared.output);
        (output.revision, output.availability)
    }
    pub fn capture(&self, id: &str) -> Option<DocumentCapture> {
        let capture = lock(&self.owner.shared.output).captures.get(id).cloned()?;
        self.current(&capture).then_some(capture)
    }
    pub fn current(&self, capture: &DocumentCapture) -> bool {
        let output = lock(&self.owner.shared.output);
        if output.availability != Availability::Ready
            || !output.captures.get(&capture.document_id).is_some_and(|c| {
                c.version == capture.version
                    && c.uri == capture.uri
                    && c.process_generation == capture.process_generation
            })
        {
            return false;
        }
        drop(output);
        lock(&self.owner.shared.inbox)
            .documents
            .iter()
            .any(|d| d.matches(capture))
    }
    #[cfg(test)]
    pub(super) fn wake_for_test(&self) {
        let _ = self.owner.shared.wake.try_send(());
    }
    #[cfg(test)]
    pub(super) fn observed_wakes_for_test(&self) -> u64 {
        self.owner.shared.observed_wakes.load(Ordering::SeqCst)
    }
    fn enqueue(&self, request: Request) -> Result<()> {
        let mut inbox = lock(&self.owner.shared.inbox);
        inbox.requests.retain(|old| !old.same_kind(&request));
        if inbox.requests.len() >= 16 {
            return Err(Error::Backpressure);
        }
        inbox.requests.push_back(request);
        drop(inbox);
        let _ = self.owner.shared.wake.try_send(());
        Ok(())
    }
    pub async fn completion(
        &self,
        capture: DocumentCapture,
        offset: usize,
    ) -> Result<CompletionBatch> {
        if !self.current(&capture) {
            return Err(Error::Stale);
        }
        let (reply, receive) = async_channel::bounded(1);
        self.enqueue(Request::Completion(capture.clone(), offset, reply))?;
        let result = receive.recv().await.map_err(|_| Error::Cancelled)?;
        if !self.current(&capture) {
            return Err(Error::Stale);
        }
        result
    }
    pub async fn signature_help(
        &self,
        capture: DocumentCapture,
        offset: usize,
    ) -> Result<Option<SignatureHelp>> {
        if !self.current(&capture) {
            return Err(Error::Stale);
        }
        let (reply, receive) = async_channel::bounded(1);
        self.enqueue(Request::Signature(capture.clone(), offset, reply))?;
        let result = receive.recv().await.map_err(|_| Error::Cancelled)?;
        if !self.current(&capture) {
            return Err(Error::Stale);
        }
        result
    }
    pub fn diagnostics(&self) -> Vec<DiagnosticsBatch> {
        lock(&self.owner.shared.output)
            .diagnostics
            .drain()
            .map(|(_, v)| v)
            .collect()
    }
    /// Completes only after didClose reaches stdin, or bounded owned teardown.
    /// Notifications have no protocol ACK. Optional failure never traps SQL close.
    pub fn finalize(
        &self,
        documents: Vec<String>,
        window: bool,
    ) -> impl std::future::Future<Output = ()> + 'static + use<> {
        let runtime = self.clone();
        let captures = lock(&self.owner.shared.output)
            .captures
            .values()
            .filter(|c| documents.contains(&c.document_id))
            .cloned()
            .collect();
        async move {
            let (reply, receive) = async_channel::bounded(1);
            {
                let mut inbox = lock(&runtime.owner.shared.inbox);
                inbox.restart = false;
                inbox.requests.clear();
                inbox.finalization = Some(Finalize {
                    documents,
                    window,
                    reply,
                    captures,
                });
            }
            let _ = runtime.owner.shared.wake.try_send(());
            // A failed worker start or panic must not trap an ordinary SQL close.
            smol::future::race(
                async {
                    let _ = receive.recv().await;
                },
                async {
                    while runtime.owner.shared.worker_alive.load(Ordering::Acquire) {
                        smol::Timer::after(Duration::from_millis(10)).await;
                    }
                },
            )
            .await;
        }
    }
}
fn set_availability(shared: &Shared, availability: Availability) {
    let mut output = lock(&shared.output);
    if output.availability != availability {
        output.availability = availability;
        output.revision += 1;
    }
    if availability != Availability::Ready {
        output.captures.clear();
        output.diagnostics.clear();
    }
}
fn start(path: &PathBuf) -> Option<LanguageService> {
    let service = LanguageService::spawn(path).ok()?;
    if smol::block_on(service.initialize()).is_err() {
        return None;
    }
    Some(service)
}
fn worker_loop(path: PathBuf, shared: Arc<Shared>, wake: Receiver<()>) {
    let mut service = start(&path);
    set_availability(
        &shared,
        if service.is_some() {
            Availability::Ready
        } else {
            Availability::Unavailable
        },
    );
    let mut synchronized = u64::MAX;
    let mut last_restart = Instant::now();
    let mut retry_requested = false;
    let mut closed_revision = None;
    let mut open_ids = HashSet::<String>::new();
    loop {
        if shared.stopping.load(Ordering::Acquire) {
            break;
        }
        while wake.try_recv().is_ok() {
            #[cfg(test)]
            shared.observed_wakes.fetch_add(1, Ordering::SeqCst);
        }
        let (revision, documents, mut restart, finalization) = {
            let mut inbox = lock(&shared.inbox);
            (
                inbox.revision,
                inbox.documents.clone(),
                std::mem::take(&mut inbox.restart),
                inbox.finalization.take(),
            )
        };
        if let Some(job) = finalization {
            restart = false;
            retry_requested = false;
            if let Some(current) = &service {
                let replaced = job.captures.iter().any(|c| !current.capture_current(c));
                for id in &job.documents {
                    current.close(id);
                    open_ids.remove(id);
                }
                let failed = smol::block_on(current.flush()).is_err();
                if failed || replaced || job.window {
                    smol::block_on(current.shutdown());
                    service = None;
                    open_ids.clear();
                    set_availability(
                        &shared,
                        if job.window {
                            Availability::Stopped
                        } else {
                            Availability::Unavailable
                        },
                    );
                }
            }
            let mut output = lock(&shared.output);
            for id in &job.documents {
                output.captures.remove(id);
                output.diagnostics.remove(id);
            }
            output.revision += 1;
            output.resume = true;
            drop(output);
            // A refused/cancelled close reopens the same source on the next sync.
            closed_revision = Some(revision);
            synchronized = u64::MAX;
            let _ = job.reply.try_send(());
            if job.window {
                // Window shutdown is terminal for this exact owned actor.
                break;
            }
        }
        if closed_revision.is_some_and(|closed| closed != revision) {
            // A newer synchronization after a refused document close resumes the
            // original actor. Stale close captures may have required teardown;
            // consume this boundary once, without retrying a failed service forever.
            closed_revision = None;
            if service.is_none() && lock(&shared.output).availability != Availability::Stopped {
                retry_requested = true;
            }
        }
        retry_requested |= restart;
        if retry_requested && last_restart.elapsed() >= Duration::from_secs(1) {
            retry_requested = false;
            if let Some(old) = service.take() {
                smol::block_on(old.shutdown());
            }
            set_availability(&shared, Availability::Starting);
            service = start(&path);
            set_availability(
                &shared,
                if service.is_some() {
                    Availability::Ready
                } else {
                    Availability::Unavailable
                },
            );
            last_restart = Instant::now();
            synchronized = u64::MAX;
            open_ids.clear();
        }
        if let Some(current) = &service {
            if !current.available() {
                set_availability(&shared, Availability::Unavailable);
            } else if synchronized != revision && closed_revision != Some(revision) {
                let previous: Vec<_> = open_ids.iter().cloned().collect();
                for id in previous {
                    if !documents.iter().any(|d| d.id == id) {
                        current.close(&id);
                        open_ids.remove(&id);
                    }
                }
                let mut captures = HashMap::new();
                let mut complete = true;
                for document in &documents {
                    let interrupted = {
                        let inbox = lock(&shared.inbox);
                        inbox.revision != revision || inbox.finalization.is_some() || inbox.restart
                    };
                    if interrupted || shared.stopping.load(Ordering::Acquire) {
                        complete = false;
                        break;
                    }
                    if let Ok(mut capture) = current.update(
                        &document.id,
                        document.source.clone(),
                        document.dialect,
                        document.context.clone(),
                        document.catalog.clone(),
                    ) {
                        capture.editor_revision = Some(document.source_revision);
                        captures.insert(document.id.clone(), capture);
                        open_ids.insert(document.id.clone());
                        // Catalog plus source can exceed 5 MiB per document.
                        // Drain each batch rather than overflow the 8 MiB writer.
                        if smol::block_on(current.flush()).is_err() {
                            complete = false;
                            break;
                        }
                    } else {
                        complete = false;
                        break;
                    }
                }
                if !complete && lock(&shared.inbox).revision == revision {
                    smol::block_on(current.shutdown());
                    open_ids.clear();
                    set_availability(&shared, Availability::Unavailable);
                }
                let mut output = lock(&shared.output);
                output.captures = captures;
                output.diagnostics.clear();
                output.revision += 1;
                synchronized = if complete { revision } else { u64::MAX };
            }
            let diagnostics = current.drain_diagnostics();
            if !diagnostics.is_empty() {
                let mut output = lock(&shared.output);
                for mut batch in diagnostics {
                    if let Some(capture) =
                        output.captures.get(&batch.capture.document_id).filter(|c| {
                            c.uri == batch.capture.uri && c.version == batch.capture.version
                        })
                    {
                        batch.capture.editor_revision = capture.editor_revision;
                        output
                            .diagnostics
                            .insert(batch.capture.document_id.clone(), batch);
                    }
                }
                output.revision += 1;
            }
        }
        let request = lock(&shared.inbox).requests.pop_front();
        if let Some(request) = request {
            let kind = request.kind();
            let document = request.document_id().to_owned();
            if let Some(current) = &service {
                match request {
                    Request::Completion(capture, offset, reply) => {
                        if !reply.is_closed() {
                            let result = smol::block_on(smol::future::race(
                                current.completion(&capture, offset),
                                interrupted(&shared, &wake, &reply, revision, kind, &document),
                            ));
                            let _ = reply.try_send(result);
                        }
                    }
                    Request::Signature(capture, offset, reply) => {
                        if !reply.is_closed() {
                            let result = smol::block_on(smol::future::race(
                                current.signature_help(&capture, offset),
                                interrupted(&shared, &wake, &reply, revision, kind, &document),
                            ));
                            let _ = reply.try_send(result);
                        }
                    }
                }
            }
            continue;
        }
        smol::block_on(smol::future::race(
            async {
                let _ = wake.recv().await;
            },
            async {
                smol::Timer::after(Duration::from_millis(25)).await;
            },
        ));
    }
    if let Some(service) = service {
        smol::block_on(service.shutdown());
    }
    set_availability(&shared, Availability::Stopped);
}
async fn interrupted<T, U>(
    shared: &Shared,
    wake: &Receiver<()>,
    reply: &Sender<U>,
    revision: u64,
    kind: RequestKind,
    document: &str,
) -> lsp::Result<T> {
    loop {
        if reply.is_closed() {
            return Err(Error::Cancelled);
        }
        let replaced = {
            let inbox = lock(&shared.inbox);
            inbox.revision != revision
                || inbox.finalization.is_some()
                || inbox.restart
                || inbox
                    .requests
                    .iter()
                    .any(|next| next.kind() == kind && next.document_id() == document)
        };
        if replaced || shared.stopping.load(Ordering::Acquire) {
            return Err(Error::Stale);
        }
        // Wake is a coalesced notification, not evidence of replacement. Keep
        // racing the same LSP future when its own enqueue or a sibling request
        // wakes the actor; source/lifecycle/newer-kind authority is read above.
        smol::future::race(
            async {
                let _ = wake.recv().await;
                #[cfg(test)]
                shared.observed_wakes.fetch_add(1, Ordering::SeqCst);
            },
            async {
                smol::Timer::after(Duration::from_millis(10)).await;
            },
        )
        .await;
    }
}
