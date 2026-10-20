//! Prepared adapter cases; runtime execution is deferred to final integration.
use crate::restoration;
#[cfg(feature = "native-smoke")]
use gpui_kit::AppContext;
#[test]
fn optional_assistance_never_enters_restoration_dtos() {
    let document = restoration::StoredDocument {
        id: "opaque-doc".into(),
        title: "SQL".into(),
        text: "SELECT 1".into(),
        profile_id: Some("missing-profile".into()),
    };
    let encoded = serde_json::to_value(document).unwrap();
    for forbidden in [
        "assistance",
        "catalog",
        "session",
        "diagnostics",
        "process_generation",
        "capture",
    ] {
        assert!(encoded.get(forbidden).is_none());
    }
    assert_eq!(encoded["profileID"], "missing-profile");
}
#[cfg(feature = "native-smoke")]
#[gpui::test]
fn retained_source_context_rebind_and_size_fallback(cx: &mut gpui::TestAppContext) {
    let (window, workspace) = crate::workspace_tests::workspace(cx);
    cx.update_window(window, |_, window, cx| {
        workspace.update(cx, |this, cx| {
            let editor = this.tabs[0].editor.clone();
            let profile = this.tabs[0].profile.clone();
            this.sync_assistance(cx);
            let before = this.assistance.revision;
            this.tabs[0].generation += 1;
            this.sync_assistance(cx);
            assert!(this.assistance.revision > before);
            for index in 0..40 {
                this.add_sql_tab_for_profile(
                    format!("SQL {index}"),
                    "SELECT 1".into(),
                    profile.clone(),
                    window,
                    cx,
                );
            }
            assert_eq!(this.assistance.documents.len(), 32);
            assert!(
                this.assistance
                    .documents
                    .iter()
                    .any(|d| d.id == this.tabs[this.active].persistent_id)
            );
            assert_eq!(this.tabs[0].editor, editor);
            let active = this.active;
            let retained = this.tabs[active].editor.clone();
            retained.update(cx, |state, cx| {
                state.set_value("x".repeat(2 * 1024 * 1024 + 1), window, cx)
            });
            this.sync_assistance(cx);
            assert!(
                !this
                    .assistance
                    .documents
                    .iter()
                    .any(|d| d.id == this.tabs[active].persistent_id)
            );
            assert!(this.assistance_status().contains("size"));
            assert_eq!(this.tabs[active].editor, retained);
            assert!(this.tabs.iter().all(|t| t.session.is_none()));
            assert!(this.backend.is_none());
        });
    })
    .unwrap();
}

use super::runtime::{Availability, Document, Runtime};
use crate::language_service::{CatalogSnapshot, ContextKey, Dialect, DocumentCapture, Error};
use std::{
    sync::Arc,
    time::{Duration, Instant},
};
fn document(revision: u64) -> Document {
    Document {
        id: "retained".into(),
        source_revision: revision,
        source: Arc::from(format!("SELECT {revision}")),
        dialect: Dialect::PostgreSQL,
        context: ContextKey {
            profile_id: Some("opaque-missing-profile".into()),
            ..Default::default()
        },
        catalog: CatalogSnapshot::default(),
    }
}
fn captured(runtime: &Runtime) -> DocumentCapture {
    let deadline = Instant::now() + Duration::from_secs(5);
    loop {
        if let Some(capture) = runtime.capture("retained") {
            return capture;
        }
        assert!(Instant::now() < deadline, "Assistance did not synchronize.");
        std::thread::sleep(Duration::from_millis(5));
    }
}
#[test]
fn actor_coalesces_latest_edits_without_resending_catalog_and_preserves_source_revision() {
    let path = crate::language_service::tests::fake("record");
    let runtime = Runtime::start(path.clone());
    runtime.synchronize(1, vec![document(1)]);
    let old = captured(&runtime);
    for revision in 2..=250 {
        runtime.synchronize(revision, vec![document(revision)]);
    }
    assert!(!runtime.current(&old));
    let current = captured(&runtime);
    assert_eq!(current.editor_revision, Some(250));
    assert!(
        current.source() == "SELECT 250",
        "The newest source was not retained."
    );
    smol::block_on(runtime.finalize(vec!["retained".into()], true));
    let events = std::fs::read_to_string(format!("{}.events", path.display())).unwrap();
    assert_eq!(
        events
            .lines()
            .filter(|m| *m == "workspace/didChangeConfiguration")
            .count(),
        1
    );
    assert!(events.lines().any(|m| m == "textDocument/didClose"));
    assert!(
        !events
            .lines()
            .any(|m| m.contains("catalog") || m.contains("connect"))
    );
    assert!(runtime.capture("retained").is_none());
}
#[test]
fn newer_source_interrupts_inflight_completion_and_close_reopens_current_context() {
    let path = crate::language_service::tests::fake("gated-record");
    let runtime = Runtime::start(path.clone());
    runtime.synchronize(1, vec![document(1)]);
    let old = captured(&runtime);
    smol::block_on(async {
        let mut pending = Box::pin(runtime.completion(old.clone(), 8));
        assert!(smol::future::poll_once(&mut pending).await.is_none());
        let gate = PendingGate::entered(&path).await;
        runtime.synchronize(2, vec![document(2)]);
        let result = pending.await;
        assert!(
            matches!(result, Err(Error::Stale) | Err(Error::Cancelled)),
            "Unexpected completion error class: {:?}",
            result.as_ref().err()
        );
        gate.release();
        runtime.finalize(vec!["retained".into()], false).await;
    });
    assert!(runtime.take_resume());
    assert!(runtime.capture("retained").is_none());
    runtime.synchronize(3, vec![document(2)]);
    let reopened = captured(&runtime);
    assert!(
        reopened.source() == "SELECT 2",
        "Close recovery changed the source."
    );
    assert_ne!(reopened.uri, old.uri);
    assert_eq!(reopened.editor_revision, Some(2));
    smol::block_on(runtime.finalize(vec!["retained".into()], true));
}

#[test]
fn signature_actor_refuses_source_profile_catalog_and_same_text_generation_races() {
    let path = crate::signature_view::fixture("slow");
    let runtime = Runtime::start(path.clone());
    let mut initial = document(1);
    initial.source = Arc::from("SELECT f(");
    runtime.synchronize(1, vec![initial.clone()]);
    let old = captured(&runtime);
    let mut replacement = initial.clone();
    replacement.source_revision = 2; // Undo can restore identical bytes.
    smol::block_on(async {
        let (reply, ()) = smol::future::zip(runtime.signature_help(old.clone(), 9), async {
            smol::Timer::after(Duration::from_millis(10)).await;
            runtime.synchronize(2, vec![replacement.clone()]);
        })
        .await;
        assert!(matches!(reply, Err(Error::Stale) | Err(Error::Cancelled)));
    });
    let source = captured(&runtime);
    assert_eq!(source.editor_revision, Some(2));
    replacement.context.profile_id = Some("replacement-profile".into());
    replacement.context.settings_revision = 2;
    replacement.context.catalog_revision = 3;
    runtime.synchronize(3, vec![replacement]);
    assert!(!runtime.current(&source));
    let current = captured(&runtime);
    let help = smol::block_on(runtime.signature_help(current.clone(), 9))
        .unwrap()
        .unwrap();
    assert_eq!(help.active_signature, 1);
    assert_eq!(help.capture.context, current.context);
    assert_eq!(help.capture.editor_revision, Some(2));
    assert!(help.capture.source() == initial.source.as_ref());
    smol::block_on(runtime.finalize(vec!["retained".into()], true));
    let methods = std::fs::read_to_string(path.with_extension("events")).unwrap();
    assert_eq!(
        methods
            .lines()
            .filter(|m| *m == "workspace/didChangeConfiguration")
            .count(),
        2
    );
    assert!(
        !methods
            .lines()
            .any(|m| m.contains("connect") || m.contains("catalog"))
    );
}
#[test]
fn explicit_retry_replaces_only_owned_lsp_generation_and_window_shutdown_waits() {
    let path = crate::language_service::tests::fake("record");
    let runtime = Runtime::start(path.clone());
    runtime.synchronize(1, vec![document(1)]);
    let old = captured(&runtime);
    for _ in 0..250 {
        runtime.retry();
    }
    let deadline = Instant::now() + Duration::from_secs(5);
    loop {
        if runtime
            .capture("retained")
            .is_some_and(|c| c.process_generation != old.process_generation)
        {
            break;
        }
        assert!(Instant::now() < deadline);
        std::thread::sleep(Duration::from_millis(10));
    }
    assert!(!runtime.current(&old));
    smol::block_on(runtime.finalize(vec!["retained".into()], true));
    assert!(runtime.availability().1 == Availability::Stopped);
    let deadline = Instant::now() + Duration::from_secs(5);
    while !runtime.worker_finished() {
        assert!(
            Instant::now() < deadline,
            "The owned assistance worker did not finish."
        );
        std::thread::sleep(Duration::from_millis(5));
    }
    runtime.synchronize(2, vec![document(2)]);
    runtime.retry();
    smol::block_on(runtime.finalize(vec!["retained".into()], true));
    assert!(runtime.worker_finished() && runtime.capture("retained").is_none());
    assert!(runtime.availability().1 == Availability::Stopped);
    assert!(!std::path::Path::new(&format!("{}.owned", path.display())).exists());
}

struct PendingGate(std::path::PathBuf);
impl PendingGate {
    async fn entered(path: &std::path::Path) -> Self {
        let gate = Self(path.to_owned());
        let deadline = Instant::now() + Duration::from_secs(5);
        while !std::path::Path::new(&format!("{}.entered", path.display())).exists() {
            assert!(
                Instant::now() < deadline,
                "The original helper did not enter its held reply."
            );
            smol::Timer::after(Duration::from_millis(5)).await;
        }
        gate
    }
    fn release(&self) {
        std::fs::write(format!("{}.release", self.0.display()), b"release").unwrap();
    }
}
impl Drop for PendingGate {
    fn drop(&mut self) {
        self.release();
    }
}
async fn await_observed_wake(runtime: &Runtime, before: u64) {
    let deadline = Instant::now() + Duration::from_secs(5);
    while runtime.observed_wakes_for_test() <= before {
        assert!(
            Instant::now() < deadline,
            "The actor did not inspect the owned wake."
        );
        smol::Timer::after(Duration::from_millis(5)).await;
    }
}
fn method_count(path: &std::path::Path, method: &str) -> usize {
    std::fs::read_to_string(format!("{}.events", path.display()))
        .unwrap()
        .lines()
        .filter(|value| *value == method)
        .count()
}
fn assert_actor_reaped(runtime: &Runtime, path: &std::path::Path) {
    let deadline = Instant::now() + Duration::from_secs(5);
    while !runtime.worker_finished() {
        assert!(
            Instant::now() < deadline,
            "The original LSP actor did not finish."
        );
        std::thread::sleep(Duration::from_millis(5));
    }
    assert!(runtime.capture("retained").is_none());
    assert!(!std::path::Path::new(&format!("{}.owned", path.display())).exists());
}

#[test]
fn own_and_sibling_wakes_preserve_the_same_inflight_request_without_resubmission() {
    let path = crate::language_service::tests::fake("gated-record");
    let runtime = Runtime::start(path.clone());
    runtime.synchronize(1, vec![document(1)]);
    let capture = captured(&runtime);
    smol::block_on(async {
        let mut completion = Box::pin(runtime.completion(capture.clone(), 8));
        assert!(smol::future::poll_once(&mut completion).await.is_none());
        let gate = PendingGate::entered(&path).await;
        let before = runtime.observed_wakes_for_test();
        let mut signature = Box::pin(runtime.signature_help(capture.clone(), 8));
        assert!(smol::future::poll_once(&mut signature).await.is_none());
        runtime.wake_for_test();
        await_observed_wake(&runtime, before).await;
        // The helper cannot reply before release, and the actor has inspected
        // the real coalesced wake while retaining this exact completion future.
        assert!(smol::future::poll_once(&mut completion).await.is_none());
        gate.release();
        let (completion, signature) = smol::future::zip(completion, signature).await;
        assert!(completion.is_ok());
        assert!(signature.is_ok_and(|value| value.is_none()));
        runtime.finalize(vec!["retained".into()], true).await;
    });
    assert_actor_reaped(&runtime, &path);
    assert_eq!(method_count(&path, "textDocument/completion"), 1);
    assert_eq!(method_count(&path, "textDocument/signatureHelp"), 1);
    assert_eq!(method_count(&path, "$/cancelRequest"), 0);
}

#[test]
fn newer_same_kind_cancels_only_the_original_request_without_retrying_either() {
    let path = crate::language_service::tests::fake("gated-record");
    let runtime = Runtime::start(path.clone());
    runtime.synchronize(1, vec![document(1)]);
    let capture = captured(&runtime);
    smol::block_on(async {
        let mut old = Box::pin(runtime.completion(capture.clone(), 8));
        assert!(smol::future::poll_once(&mut old).await.is_none());
        let gate = PendingGate::entered(&path).await;
        let mut newest = Box::pin(runtime.completion(capture.clone(), 8));
        assert!(smol::future::poll_once(&mut newest).await.is_none());
        // Replacement must cancel the original even with its reply held.
        assert!(matches!(
            old.await,
            Err(Error::Stale) | Err(Error::Cancelled)
        ));
        gate.release();
        assert!(newest.await.is_ok());
        runtime.finalize(vec!["retained".into()], true).await;
    });
    assert_actor_reaped(&runtime, &path);
    assert_eq!(method_count(&path, "textDocument/completion"), 2);
    assert_eq!(method_count(&path, "$/cancelRequest"), 1);
}

#[test]
fn dropped_reply_and_window_close_cancel_the_original_inflight_request_and_reap() {
    for close in [false, true] {
        let path = crate::language_service::tests::fake("gated-record");
        let runtime = Runtime::start(path.clone());
        runtime.synchronize(1, vec![document(1)]);
        let capture = captured(&runtime);
        smol::block_on(async {
            let mut reply = Box::pin(runtime.completion(capture.clone(), 8));
            assert!(smol::future::poll_once(&mut reply).await.is_none());
            let gate = PendingGate::entered(&path).await;
            if close {
                let mut finalization = Box::pin(runtime.finalize(vec!["retained".into()], true));
                let _ = smol::future::poll_once(&mut finalization).await;
                assert!(matches!(
                    reply.await,
                    Err(Error::Stale) | Err(Error::Cancelled)
                ));
                gate.release();
                finalization.await;
            } else {
                let before = runtime.observed_wakes_for_test();
                drop(reply);
                runtime.wake_for_test();
                await_observed_wake(&runtime, before).await;
                gate.release();
                // Dropping only the original completion receiver leaves its
                // sibling valid, without submitting another completion.
                assert!(runtime.signature_help(capture.clone(), 8).await.is_ok());
                runtime.finalize(vec!["retained".into()], true).await;
            }
        });
        assert_actor_reaped(&runtime, &path);
        assert_eq!(method_count(&path, "textDocument/completion"), 1);
        assert_eq!(method_count(&path, "$/cancelRequest"), 1);
    }
}
