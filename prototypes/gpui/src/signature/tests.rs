//! Prepared production Workspace callbacks; execute only at final integration.
use super::{Invocation, PopupAction};
use crate::{CommandId, CommandOrigin, DocumentId, Workspace, completion, signature_view};
use gpui_kit::{AppContext, Context, Focusable, TestAppContext, Window, test::TestWindowExt};
use std::time::Duration;
mod connected;

fn focused(this: &mut Workspace, window: &mut Window, cx: &mut Context<Workspace>) -> DocumentId {
    let tab = &this.tabs[this.active];
    let id = tab.id;
    tab.editor.update(cx, |state, cx| {
        state.set_value("SELECT f(", window, cx);
        state.set_selected_range(9..9, cx);
        state.focus(window, cx);
    });
    id
}

#[gpui::test]
fn pending_escape_caret_focus_context_close_and_overflow_keep_retained_editor(
    cx: &mut TestAppContext,
) {
    let (handle, view) = crate::workspace_tests::workspace(cx);
    cx.update_window(handle, |_, window, cx| {
        view.update(cx, |this, cx| {
            let id = focused(this, window, cx);
            let editor = this.tabs[this.active].editor.clone();
            let revision = editor.read(cx).accessibility_document_revision();
            this.start_signatures(id, Invocation::Manual, window, cx);
            assert!(this.signatures.pending);
            let old_epoch = this.signatures.epoch;
            assert!(this.signature_escape(false, window, cx));
            assert!(this.signatures.task.is_none());
            assert!(!this.signatures.pending);
            this.refresh_signatures(window, cx);
            assert!(
                this.signatures.task.is_none(),
                "Escape revived the same snapshot."
            );
            this.start_signatures(id, Invocation::Manual, window, cx);
            assert!(this.signatures.pending);
            assert_ne!(this.signatures.epoch, old_epoch);
            let old_stamp = this.signatures.stamp.clone();
            editor.update(cx, |state, cx| {
                state.set_selected_range(0..0, cx);
                state.set_selected_range(9..9, cx);
            });
            this.refresh_signatures(window, cx);
            assert!(
                this.signatures.stamp != old_stamp,
                "Caret ABA reused the old owner."
            );
            assert_eq!(editor.read(cx).accessibility_document_revision(), revision);
            let epoch = this.signatures.epoch;
            let profile = this.tabs[this.active].profile.clone();
            this.profiles
                .iter_mut()
                .find(|p| p.id == profile)
                .unwrap()
                .service_generation += 1;
            this.refresh_signatures(window, cx);
            assert_ne!(this.signatures.epoch, epoch);
            let epoch = this.signatures.epoch;
            this.profiles
                .iter_mut()
                .find(|p| p.id == profile)
                .unwrap()
                .config = Some(crate::connections::ConnectionProfile::default());
            this.refresh_signatures(window, cx);
            assert_ne!(this.signatures.epoch, epoch);
            this.search.update(cx, |state, cx| state.focus(window, cx));
            this.refresh_signatures(window, cx);
            assert!(this.signatures.stamp.is_none());
            editor.update(cx, |state, cx| state.focus(window, cx));
            this.closing = true;
            this.start_signatures(id, Invocation::Manual, window, cx);
            assert!(this.signatures.task.is_none());
            this.closing = false;
            editor.update(cx, |state, cx| state.set_selected_range(3..6, cx));
            this.refresh_signatures(window, cx);
            assert!(this.signatures.stamp.is_none());
            assert_eq!(editor.read(cx).selected_range(), 3..6);
            editor.update(cx, |state, cx| state.set_selected_range(9..9, cx));
            this.signatures.epoch = Some(u64::MAX);
            this.start_signatures(id, Invocation::Manual, window, cx);
            assert!(this.signatures.epoch.is_none());
            assert!(this.signatures.task.is_none());
            assert_eq!(this.tabs[this.active].editor, editor);
            assert_eq!(editor.read(cx).value(), "SELECT f(");
            assert!(this.backend.is_none());
            assert!(this.tabs.iter().all(|tab| tab.session.is_none()));
        });
    })
    .unwrap();
}

#[gpui::test]
fn owned_fake_signature_callbacks_and_common_completion_priority_preserve_undo(
    cx: &mut TestAppContext,
) {
    let path = signature_view::fixture("normal");
    let (handle, view) = crate::workspace_tests::workspace(cx);
    cx.update(crate::commands::install_keys);
    cx.update(|cx| cx.background_executor().allow_parking());
    cx.update_window(handle, |_, window, cx| {
        view.update(cx, |this, cx| {
            focused(this, window, cx);
            this.assistance_fixture(path.clone(), cx);
        });
    })
    .unwrap();
    crate::workspace_tests::await_workspace(cx, &view, |this| {
        this.assistance_process_generation(this.tabs[this.active].id)
            .is_some()
    });
    cx.update_window(handle, |_, window, cx| {
        view.update(cx, |this, cx| {
            let id = this.tabs[this.active].id;
            this.tabs[this.active].status = "Independent execution feedback".into();
            this.tabs[this.active].error = true;
            this.start_signatures(id, Invocation::Manual, window, cx);
        });
    })
    .unwrap();
    crate::workspace_tests::await_workspace(cx, &view, |this| !this.signatures.pending);
    cx.update_window(handle, |_, window, cx| {
        view.update(cx, |this, cx| {
            assert!(this.signature_overlay(window, cx).is_some());
            let id = this.signatures.popup.interaction_id().unwrap();
            assert!(this.signature_act(id, PopupAction::PreviousOverload, window, cx));
            let native = completion::selections(&this.tabs[this.active].editor, cx).unwrap();
            let mut popup = std::mem::take(&mut this.signatures.popup);
            assert_eq!(
                popup
                    .presentation(Some(&native), window, cx, |capture, cx| this
                        .assistance_capture_current(capture, cx))
                    .unwrap()
                    .selected_index(),
                0
            );
            this.signatures.popup = popup;
            assert_eq!(
                this.tabs[this.active].status,
                "Independent execution feedback"
            );
            assert!(this.tabs[this.active].error);
            let editor = this.tabs[this.active].editor.clone();
            let original = editor.read(cx).value();
            editor.update(cx, |state, cx| {
                state.set_selected_range(0..0, cx);
                state.set_selected_range(9..9, cx);
            });
            assert!(!this.signature_act(id, PopupAction::NextOverload, window, cx));
            assert_eq!(editor.read(cx).value(), original);
            assert_eq!(editor.read(cx).selected_range(), 9..9);
            this.command(CommandId::Complete, CommandOrigin::Menu, None, window, cx);
        });
    })
    .unwrap();
    crate::workspace_tests::await_workspace(cx, &view, |this| {
        !this.signatures.pending && this.signatures.popup.interaction_id().is_some()
    });
    // Completion has a separate asynchronous reply. Wait through the actual
    // presentation gate rather than inspecting a sibling module's internals.
    crate::workspace_tests::await_window(cx, handle, Duration::from_secs(10), |window, cx| {
        view.update(cx, |this, cx| this.completion_overlay(window, cx).is_some())
    });
    cx.update_window(handle, |_, window, cx| {
        let editor = view.read(cx).tabs[view.read(cx).active].editor.clone();
        let original = editor.read(cx).value();
        let selection = editor.read(cx).selected_range();
        window.render_frame(cx);
        window.press("tab", cx);
        assert_eq!(editor.read(cx).value(), "SELECT f(value");
        assert!(editor.focus_handle(cx).is_focused(window));
        window.press(&crate::platform::binding("z"), cx);
        assert_eq!(editor.read(cx).value(), original);
        assert_eq!(editor.read(cx).selected_range(), selection);
        view.update(cx, |this, cx| {
            this.dismiss_completion();
            this.dismiss_signatures();
            assert_eq!(this.tabs[this.active].editor, editor);
            assert!(this.backend.is_none());
            assert!(this.tabs.iter().all(|tab| tab.session.is_none()));
            this.refresh_signatures(window, cx);
            assert!(this.signature_escape(false, window, cx));
            this.refresh_signatures(window, cx);
            assert!(this.signatures.task.is_none());
        });
    })
    .unwrap();
    let methods = std::fs::read_to_string(path.with_extension("events")).unwrap();
    assert!(
        methods
            .lines()
            .any(|method| method == "textDocument/signatureHelp")
    );
    assert!(
        methods
            .lines()
            .any(|method| method == "textDocument/completion")
    );
    assert!(
        !methods
            .lines()
            .any(|method| method.contains("catalog") || method.contains("connect"))
    );
}

#[gpui::test]
fn optional_null_and_malformed_replies_settle_without_render_request_loops_or_execution_errors(
    cx: &mut TestAppContext,
) {
    for mode in ["null", "bad"] {
        let path = signature_view::fixture(mode);
        let (handle, view) = crate::workspace_tests::workspace(cx);
        cx.update(|cx| cx.background_executor().allow_parking());
        cx.update_window(handle, |_, window, cx| {
            view.update(cx, |this, cx| {
                focused(this, window, cx);
                this.assistance_fixture(path.clone(), cx);
                this.tabs[this.active].status = "Existing execution feedback".into();
                this.tabs[this.active].error = true;
            });
        })
        .unwrap();
        crate::workspace_tests::await_workspace(cx, &view, |this| {
            this.assistance_process_generation(this.tabs[this.active].id)
                .is_some()
        });
        cx.update_window(handle, |_, window, cx| {
            view.update(cx, |this, cx| {
                this.start_signatures(this.tabs[this.active].id, Invocation::Manual, window, cx)
            });
        })
        .unwrap();
        crate::workspace_tests::await_workspace(cx, &view, |this| !this.signatures.pending);
        cx.update_window(handle, |_, window, cx| {
            view.update(cx, |this, cx| {
                let epoch = this.signatures.epoch;
                for _ in 0..100 {
                    assert!(this.signature_overlay(window, cx).is_none());
                    assert_eq!(this.signatures.epoch, epoch);
                    assert!(!this.signatures.pending);
                }
                assert!(!this.signature_escape(false, window, cx));
                assert_eq!(this.tabs[this.active].status, "Existing execution feedback");
                assert!(this.tabs[this.active].error);
            });
        })
        .unwrap();
        let methods = std::fs::read_to_string(path.with_extension("events")).unwrap();
        assert_eq!(
            methods
                .lines()
                .filter(|method| *method == "textDocument/signatureHelp")
                .count(),
            1
        );
    }
}
