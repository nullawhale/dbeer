//! Original-document Run to File chooser ownership; execution uses live.rs.
use super::*;
use std::{path::PathBuf, sync::Arc};
#[derive(Clone, Copy, PartialEq, Eq)]
pub(super) enum Phase {
    Review,
    Choosing,
    Capturing,
    Executing,
}
pub(super) struct Flow {
    pub(super) token: u64,
    pub(super) cancelled: bool,
    profile_generation: u64,
    pub(super) phase: Phase,
    pub(super) capture: Arc<commands::CommandCapture>,
    pub(super) format: exports::Format,
    pub(super) export: Option<backend::ExportRequest>,
    pub(super) operation: Option<OperationContext>,
}
struct Review {
    workspace: WeakEntity<Workspace>,
    token: u64,
    format: exports::Format,
    marker: Entity<InputState>,
    error: Option<&'static str>,
}
impl Render for Review {
    fn render(&mut self, _: &mut Window, cx: &mut Context<Self>) -> impl IntoElement {
        div().flex().flex_col().gap_3().child("Run exactly one SQL statement once and stream all rows to a private temporary file. The final file appears after successful SQL and file publication. A failed save never reruns SQL.")
  .when(self.format==exports::Format::Csv,|v|v.child("CSV supports one result set. SQL NULL uses this nonempty marker; a value collision fails the save after SQL finishes. Binary values use Base64.").child(Input::new(&self.marker).aria_label("CSV NULL marker")))
  .when_some(self.error,|v,e|v.child(e))
  .child(div().flex().gap_2().justify_end()
   .child(Button::new("cancel-run-file").label("Cancel").on_click(cx.listener(|this,_,window,cx|{_ = this.workspace.update(cx,|w,cx|w.cancel_run_file(this.token,cx));window.close_dialog(cx)})))
   .child(Button::new("choose-run-file").label("Choose Destination...").on_click(cx.listener(|this,_,window,cx|{
    let marker=this.marker.read(cx).value().to_string();
    if this.format==exports::Format::Csv && (marker.is_empty() || marker.len()>1024 || marker.contains('\0')) {this.error=Some("Choose a nonempty NULL marker of at most 1,024 UTF-8 bytes without NUL.");cx.notify();return}
    _=this.workspace.update(cx,|w,cx|w.choose_run_file(this.token,marker,window,cx));
   }))))
    }
}
impl Workspace {
    pub(super) fn start_run_file(
        &mut self,
        capture: commands::CommandCapture,
        window: &mut Window,
        cx: &mut Context<Self>,
    ) {
        if self.run_file.is_some() || !self.capture_valid(&capture, cx) {
            return;
        }
        let Some(fragment) = capture.fragment.as_ref() else {
            return;
        };
        if let Err(error) = run_to_file::validate(fragment) {
            if let Some(id) = capture.document.as_ref().map(|t| t.id)
                && let Some(tab) = self.tabs.iter_mut().find(|t| t.id == id)
            {
                tab.error = true;
                tab.status = error.into();
            }
            return;
        }
        let Some(original) = capture.document.as_ref() else {
            return;
        };
        if original.settings.is_none() {
            Self::information(
                "Run to File requires a saved database connection.",
                window,
                cx,
            );
            return;
        }
        let profile_generation = self
            .tabs
            .iter()
            .find(|t| t.id == original.id)
            .map(|t| self.profile(&t.profile).generation)
            .unwrap();
        self.next_run_file += 1;
        let token = self.next_run_file;
        let format = if capture.command == CommandId::RunToCsv {
            exports::Format::Csv
        } else {
            exports::Format::Json
        };
        self.run_file = Some(Flow {
            cancelled: false,
            token,
            profile_generation,
            phase: Phase::Review,
            capture: Arc::new(capture),
            format,
            export: None,
            operation: None,
        });
        let workspace = cx.entity().downgrade();
        let review = cx.new(|cx| Review {
            workspace: workspace.clone(),
            token,
            format,
            marker: cx.new(|cx| InputState::new(window, cx).default_value("\\N")),
            error: None,
        });
        window.open_dialog(cx, move |dialog, _, _| {
            let cancel = workspace.clone();
            let escape = workspace.clone();
            dialog
                .title("Run to File")
                .accessibility_label("Run to File")
                .overlay_closable(false)
                .close_button(false)
                .on_ok(move |_, window, cx| {
                    _ = cancel.update(cx, |w, cx| w.cancel_run_file(token, cx));
                    window.close_dialog(cx);
                    true
                })
                .on_cancel(move |_, _, cx| {
                    _ = escape.update(cx, |w, cx| w.cancel_run_file(token, cx));
                    true
                })
                .child(review.clone())
        });
        cx.notify();
    }
    pub(super) fn run_file_pending(&self, id: DocumentId) -> bool {
        self.run_file
            .as_ref()
            .is_some_and(|f| f.capture.document.as_ref().is_some_and(|d| d.id == id))
    }
    pub(super) fn stop_run_file_preparation(
        &mut self,
        id: DocumentId,
        cx: &mut Context<Self>,
    ) -> bool {
        let token = self
            .run_file
            .as_ref()
            .filter(|f| {
                f.phase != Phase::Executing
                    && f.capture.document.as_ref().is_some_and(|d| d.id == id)
            })
            .map(|f| f.token);
        if let Some(token) = token {
            self.cancel_run_file(token, cx);
            true
        } else {
            false
        }
    }
    pub(super) fn cancel_run_file(&mut self, token: u64, cx: &mut Context<Self>) {
        let Some(flow) = self.run_file.as_mut().filter(|f| f.token == token) else {
            return;
        };
        if flow.phase == Phase::Executing {
            return;
        }
        // Native chooser and destination-capture futures remain retained until
        // their original callback drains; cancellation only prevents publication.
        if matches!(flow.phase, Phase::Choosing | Phase::Capturing) {
            flow.cancelled = true;
            cx.notify();
        } else {
            self.retire_run_file_preparation(token, cx);
        }
    }
    fn retire_run_file_preparation(&mut self, token: u64, cx: &mut Context<Self>) {
        if self
            .run_file
            .as_ref()
            .is_some_and(|f| f.token == token && f.phase != Phase::Executing)
        {
            self.run_file = None;
            self.run_file_task = None;
            cx.notify();
        }
    }
    fn run_file_valid(&self, token: u64, cx: &App) -> bool {
        self.run_file.as_ref().is_some_and(|f| {
            f.token == token
                && !f.cancelled
                && self.capture_valid(&f.capture, cx)
                && f.capture.document.as_ref().is_some_and(|d| {
                    self.tabs.iter().find(|t| t.id == d.id).is_some_and(|t| {
                        self.profile(&t.profile).generation == f.profile_generation
                    })
                })
        })
    }
    fn choose_run_file(
        &mut self,
        token: u64,
        marker: String,
        window: &mut Window,
        cx: &mut Context<Self>,
    ) {
        if !self.run_file_valid(token, cx) {
            self.cancel_run_file(token, cx);
            window.close_dialog(cx);
            return;
        }
        let flow = self.run_file.as_mut().unwrap();
        if flow.phase != Phase::Review {
            return;
        }
        flow.phase = Phase::Choosing;
        let title = flow
            .capture
            .document
            .as_ref()
            .and_then(|d| self.tabs.iter().find(|t| t.id == d.id))
            .map(|t| t.title.replace(['/', '\\', '\0'], "_"))
            .unwrap_or_else(|| "Query".into());
        let name = format!("{title}.{}", flow.format.extension());
        window.close_dialog(cx);
        let selected = cx.prompt_for_new_path(
            &std::env::current_dir().unwrap_or_else(|_| std::env::temp_dir()),
            Some(&name),
        );
        self.run_file_task = Some(cx.spawn_in(window, async move |this, cx| {
            let selected = selected.await;
            _ = this.update_in(cx, |this, window, cx| {
                if !this.run_file_valid(token, cx) {
                    this.retire_run_file_preparation(token, cx);
                    return;
                }
                match selected {
                    Ok(Ok(Some(path))) => this.capture_run_file(token, path, marker, window, cx),
                    _ => this.retire_run_file_preparation(token, cx),
                }
            });
        }));
        cx.notify();
    }
    fn capture_run_file(
        &mut self,
        token: u64,
        path: PathBuf,
        marker: String,
        window: &mut Window,
        cx: &mut Context<Self>,
    ) {
        if !self.run_file_valid(token, cx) {
            self.cancel_run_file(token, cx);
            return;
        }
        let flow = self.run_file.as_mut().unwrap();
        if flow.phase != Phase::Choosing {
            return;
        }
        flow.phase = Phase::Capturing;
        self.run_file_task = Some(cx.spawn_in(window, async move |this, cx| {
            let chosen = path.clone();
            let stamp = cx
                .background_executor()
                .spawn(async move { run_to_file::capture_destination(&chosen) })
                .await;
            _ = this.update_in(cx, |this, window, cx| {
                if !this.run_file_valid(token, cx) {
                    this.retire_run_file_preparation(token, cx);
                    return;
                }
                let flow = this.run_file.as_mut().unwrap();
                if flow.phase != Phase::Capturing {
                    return;
                }
                let original = flow.capture.document.as_ref().unwrap();
                let id = original.id;
                match stamp {
                    Ok(destination) => {
                        if this.closing {
                            this.retire_run_file_preparation(token, cx);
                            return;
                        }
                        let Some(path) = path.to_str() else {
                            this.retire_run_file_preparation(token, cx);
                            return;
                        };
                        let export = backend::ExportRequest {
                            path: path.to_owned(),
                            format: if flow.format == exports::Format::Csv {
                                backend::ExportFormat::Csv
                            } else {
                                backend::ExportFormat::Json
                            },
                            null_marker: (flow.format == exports::Format::Csv).then_some(marker),
                            destination: Some(destination),
                        };
                        if !export.valid() {
                            this.retire_run_file_preparation(token, cx);
                            return;
                        }
                        flow.export = Some(export.clone());
                        flow.phase = Phase::Executing;
                        let fragment = flow.capture.fragment.as_ref().unwrap().clone();
                        this.run_live_export(id, fragment, export, window, cx);
                        if let Some(op) = this
                            .tabs
                            .iter()
                            .find(|t| t.id == id)
                            .and_then(|t| t.operation.clone())
                        {
                            if let Some(flow) = this.run_file.as_mut() {
                                flow.operation = Some(op)
                            }
                        } else {
                            this.run_file = None
                        }
                        this.run_file_task = None;
                    }
                    Err(error) => {
                        this.retire_run_file_preparation(token, cx);
                        if let Some(tab) = this.tabs.iter_mut().find(|t| t.id == id) {
                            tab.error = true;
                            tab.status = error.into()
                        }
                    }
                }
                cx.notify();
            });
        }));
    }
    pub(super) fn run_file_operation_valid(&self, context: &OperationContext) -> bool {
        self.run_file
            .as_ref()
            .filter(|f| {
                f.operation.as_ref().is_some_and(|op| {
                    op.document == context.document && op.operation == context.operation
                })
            })
            .is_none_or(|f| {
                self.profiles.iter().any(|p| {
                    p.id == context.profile
                        && p.generation == f.profile_generation
                        && p.config == context.settings
                })
            })
    }
    pub(super) fn finish_run_file(&mut self, context: &OperationContext) {
        if self.run_file.as_ref().is_some_and(|f| {
            f.operation.as_ref().is_some_and(|o| {
                o.document == context.document
                    && o.operation == context.operation
                    && o.session_generation == context.session_generation
            })
        }) {
            self.run_file = None;
            self.run_file_task = None
        }
    }
}
#[cfg(all(test, feature = "native-smoke"))]
mod tests;
