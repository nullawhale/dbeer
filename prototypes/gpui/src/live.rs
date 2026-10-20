//! SQL operation and helper session coordination. SQL semantics stay in Go.
use super::*;
use backend::{Connection, ExecutionPolicy, QueryEvent, QueryOutcome, TransactionStatus};
use connections::read_password;
use std::path::PathBuf;

#[derive(Clone)]
struct Execution {
    context: OperationContext,
    session: String,
    fragment: std::sync::Arc<sql::PreparedFragment>,
    assessment: backend::OperationAssessment,
    after: Option<close::CloseToken>,
    export: Option<backend::ExportRequest>,
}

struct RunOptions {
    after: Option<close::CloseToken>,
    bind_editor: bool,
    export: Option<backend::ExportRequest>,
}

pub(super) fn environment(value: &str) -> &'static str {
    match value {
        "production" => "Production",
        "staging" => "Staging",
        "development" => "Development",
        _ => "Unset",
    }
}
pub(super) fn transaction(value: TransactionStatus) -> String {
    match value {
        TransactionStatus::Idle => "idle",
        TransactionStatus::Transaction => "transaction",
        TransactionStatus::FailedTransaction => "failedTransaction",
    }
    .into()
}
pub(super) fn numeric_type(value: &str) -> bool {
    let value = value.to_ascii_lowercase();
    let base = value.split('(').next().unwrap_or("").trim();
    let base = base.strip_suffix(" unsigned").unwrap_or(base);
    matches!(
        base,
        "int"
            | "integer"
            | "int2"
            | "int4"
            | "int8"
            | "bigint"
            | "smallint"
            | "tinyint"
            | "mediumint"
            | "decimal"
            | "numeric"
            | "float"
            | "float4"
            | "float8"
            | "double"
            | "double precision"
            | "real"
    ) && !value.contains('[')
}
pub(super) fn connection(profile: &ConnectionProfile) -> std::result::Result<Connection, String> {
    Ok(Connection {
        engine: profile.engine.clone(),
        host: profile.host.clone(),
        port: profile.port,
        database: profile.database.clone(),
        user: profile.user.clone(),
        password: read_password(&profile.id).map_err(|e| e.to_string())?,
        ssl_mode: profile.ssl_mode.clone(),
        ssl_root_cert: profile.ssl_root_cert.clone(),
        policy: ExecutionPolicy {
            environment: if profile.environment == "unset" {
                "unspecified".into()
            } else {
                profile.environment.clone()
            },
            read_only: profile.readonly,
        },
    })
}
pub(super) async fn connect_saved(
    client: &BackendClient,
    profile: ConnectionProfile,
) -> std::result::Result<backend::ConnectionOutcome, backend::BackendError> {
    let expected_engine = profile.engine.clone();
    let settings = smol::unblock(move || connection(&profile))
        .await
        .map_err(|message| backend::BackendError {
            message,
            category: "credentials".into(),
            connected: false,
            outcome_unknown: false,
            sql_completed: false,
            sql_not_executed: false,
            export_publication: None,
            transaction_status: None,
            sql_state: None,
            error_position: None,
            result_sets: Vec::new(),
        })?;
    let result = client.connect(settings).await?;
    if result.engine != expected_engine
        || result.transaction_status != TransactionStatus::Idle
        || [
            "execute",
            "cancel",
            "transactions",
            "catalog",
            "operationAssessment",
            "executionPolicy",
        ]
        .iter()
        .any(|required| !result.capabilities.iter().any(|cap| cap == required))
    {
        let _ = client.disconnect(&result.session_id).await;
        return Err(backend::BackendError::transport(
            "Unexpected engine or transaction state in the connection response.",
        ));
    }
    Ok(result)
}
pub(super) fn helper_path() -> PathBuf {
    platform::helper_path()
}
pub(super) async fn collect(
    stream: backend::QueryStream,
) -> std::result::Result<QueryOutcome, backend::BackendError> {
    while let Ok(event) = stream.events.recv().await {
        if let QueryEvent::Finished(outcome) = event? {
            return Ok(outcome);
        }
    }
    Err(backend::BackendError::transport(
        "The helper closed the query stream.",
    ))
}

impl Workspace {
    pub(super) fn invalidate_dead_helper(&mut self) {
        let workspace_dead = self.backend.as_ref().is_some_and(|c| !c.is_alive());
        if workspace_dead {
            self.backend = None;
            self.catalog.selected = None;
            self.catalog.search.entries.clear();
        }
        for profile in &mut self.profiles {
            if let Some(client) = profile.session_client.as_ref().filter(|c| !c.is_alive()) {
                profile.loaded = false;
                profile.schemas.clear();
                if client.owned_process_exited() {
                    profile.session = None;
                    profile.session_settings = None;
                    profile.session_client = None;
                }
            }
        }
        for tab in &mut self.tabs {
            let dead = tab
                .session_client()
                .as_ref()
                .map_or(workspace_dead, |c| !c.is_alive());
            if !dead {
                continue;
            }
            if let Some(doc) = &mut tab.catalog_document
                && doc.loading
            {
                doc.loading = false;
                tab.error = true;
                tab.status = "Helper disconnected. Connect explicitly and Refresh to retry.".into();
            }
            // The original task still owns a guaranteed terminal. Never turn
            // cancel ACK, a replacement helper, or liveness loss into rollback.
            if tab.busy() && tab.task.is_some() {
                continue;
            }
            if let Some(context) = tab.operation.clone() {
                tab.end(&context, model::ExecutionState::Cancelled, 0);
            }
            if tab
                .session_client()
                .is_some_and(|c| c.owned_process_exited())
            {
                tab.retire_session();
            }
            if tab.transaction != "idle" {
                tab.uncertain = true;
                tab.status =
                    "Session lost. Verify the previous transaction outcome before retrying.".into();
            }
        }
    }
    pub(super) fn client(&mut self) -> std::result::Result<BackendClient, String> {
        self.invalidate_dead_helper();
        if self.backend.is_none() {
            self.backend = Some(BackendClient::spawn(helper_path()).map_err(|e| e.message)?);
        }
        Ok(self.backend.as_ref().unwrap().clone())
    }
    pub fn run_live(
        &mut self,
        id: DocumentId,
        override_sql: Option<String>,
        after: Option<close::CloseToken>,
        window: &mut Window,
        cx: &mut Context<Self>,
    ) {
        if (self.closing && !after.is_some_and(|token| self.resolving_close(token, id)))
            || window.has_active_dialog(cx)
        {
            return;
        }
        let Some(tab) = self.tabs.iter().find(|t| t.id == id) else {
            return;
        };
        if tab.busy() {
            return;
        }
        // Parsing precedes helper startup, credentials, connect and operation creation.
        let bind_editor = override_sql.is_none();
        let prepared = self
            .prepare_execution(id, override_sql, cx)
            .and_then(|fragment| {
                fragment.single_statement()?;
                Ok(fragment)
            });
        let fragment = match prepared {
            Ok(fragment) => fragment,
            Err(error) => {
                let tab = self.tabs.iter_mut().find(|t| t.id == id).unwrap();
                tab.clear_execution_marks();
                tab.execution_decoration.clear(cx);
                tab.status = error.into();
                tab.error = true;
                cx.notify();
                return;
            }
        };
        self.run_live_snapshot(
            id,
            std::sync::Arc::new(fragment),
            RunOptions {
                after,
                bind_editor,
                export: None,
            },
            window,
            cx,
        );
    }

    pub(super) fn run_live_prepared(
        &mut self,
        id: DocumentId,
        fragment: std::sync::Arc<sql::PreparedFragment>,
        after: Option<close::CloseToken>,
        window: &mut Window,
        cx: &mut Context<Self>,
    ) {
        self.run_live_snapshot(
            id,
            fragment,
            RunOptions {
                after,
                bind_editor: true,
                export: None,
            },
            window,
            cx,
        );
    }

    pub(super) fn run_live_export(
        &mut self,
        id: DocumentId,
        fragment: std::sync::Arc<sql::PreparedFragment>,
        export: backend::ExportRequest,
        window: &mut Window,
        cx: &mut Context<Self>,
    ) {
        if !self.run_file.as_ref().is_some_and(|flow| {
            flow.phase == run_file_view::Phase::Executing
                && flow.export.as_ref() == Some(&export)
                && flow.capture.document.as_ref().is_some_and(|d| d.id == id)
                && flow
                    .capture
                    .fragment
                    .as_ref()
                    .is_some_and(|f| std::sync::Arc::ptr_eq(f, &fragment))
        }) || run_to_file::validate(&fragment).is_err()
            || !export.valid()
        {
            return;
        }
        self.run_live_snapshot(
            id,
            fragment,
            RunOptions {
                after: None,
                bind_editor: true,
                export: Some(export),
            },
            window,
            cx,
        );
    }
    fn run_live_snapshot(
        &mut self,
        id: DocumentId,
        fragment: std::sync::Arc<sql::PreparedFragment>,
        options: RunOptions,
        window: &mut Window,
        cx: &mut Context<Self>,
    ) {
        let RunOptions {
            after,
            bind_editor,
            export,
        } = options;
        if (self.closing && !after.is_some_and(|token| self.resolving_close(token, id)))
            || window.has_active_dialog(cx)
            || (export.is_none() && self.run_file.is_some())
        {
            return;
        }
        let Some(tab) = self.tabs.iter().find(|t| t.id == id) else {
            return;
        };
        if tab.busy() {
            return;
        }
        let Some(settings) = self.profile(&tab.profile).config.clone() else {
            return;
        };
        if let Err(error) = scripts::validate(&fragment) {
            let tab = self.tabs.iter_mut().find(|t| t.id == id).unwrap();
            tab.status = error.into();
            tab.error = true;
            cx.notify();
            return;
        }
        // Never send a retained physical session to a replacement helper.
        let original_client = tab.session_client();
        let client = match if let Some(token) = after {
            self.close_resolution_client(token, id)
                .ok_or_else(|| "The original transaction helper is unavailable.".to_owned())
        } else if let Some(client) = original_client {
            if client.is_alive() {
                Ok(client)
            } else {
                Err("The original SQL session helper is unavailable. Disconnect explicitly before retrying.".to_owned())
            }
        } else if tab.session.is_some() {
            Err("The original physical SQL session helper cannot be identified. Disconnect explicitly before retrying.".to_owned())
        } else {
            self.client()
        } {
            Ok(client) => client,
            Err(error) => {
                if let Some(tab) = self.tabs.iter_mut().find(|t| t.id == id) {
                    tab.status = error.into();
                    tab.error = true;
                }
                cx.notify();
                return;
            }
        };
        let tab = self.tabs.iter_mut().find(|t| t.id == id).unwrap();
        let Some(context) = tab.begin(Some(settings.clone()), fragment.source().text().len())
        else {
            if !tab.busy() {
                Self::information(
                    "Disconnect this session before executing: its outcome is unknown or its connection settings changed.",
                    window,
                    cx,
                );
            }
            return;
        };
        tab.prepare_batch(fragment.clone());
        tab.execution_editor_bound = bind_editor;
        tab.execution_decoration.clear(cx);
        tab.operation_client = Some(client.clone());
        tab.status = "Preparing query...".into();
        tab.error = false;
        tab.resolving_close = after.is_some();
        // Swift close control COMMIT/ROLLBACK bypasses managed SQL history.
        tab.history_allowed = after.is_none();
        tab.retire_grid_contexts(cx);
        tab.grid = None;
        tab.result_sets.clear();
        tab.selected_result = 0;
        tab.task = Some(cx.spawn_in(window, async move |view, cx| {
            let mut current = context.clone();
            let result = async {
                // Revalidate original operation before handshake/credential work.
                if !view
                    .update_in(cx, |this, _, cx| this.operation_valid(&context, cx))
                    .unwrap_or(false)
                {
                    _ = view.update_in(cx, |this, _, cx| this.finish_cancelled(&context, cx));
                    return Ok(());
                }
                client.handshake().await?;
                let session = match &context.session {
                    Some(session) => session.clone(),
                    None => connect_saved(&client, settings).await?.session_id,
                };
                let attached = view
                    .update_in(cx, |this, _, cx| {
                        // Keep a newly opened session only for the owning operation.
                        // Source edits may cancel submission, but must not leak it.
                        let valid_profile = this
                            .profiles
                            .iter()
                            .any(|p| p.id == context.profile && p.config == context.settings);
                        let tab = this.tabs.iter_mut().find(|t| t.id == id)?;
                        let attached = valid_profile
                            .then(|| tab.attach(&context, session.clone()))
                            .flatten();
                        if attached.is_some() {
                            tab.own_session(client.clone());
                            this.refresh_connection_flags();
                            cx.notify();
                        }
                        attached
                    })
                    .ok()
                    .flatten();
                let Some(attached) = attached else {
                    if context.session.is_none() {
                        let _ = client.disconnect(&session).await;
                    }
                    _ = view.update_in(cx, |this, _, cx| this.finish_cancelled(&context, cx));
                    return Ok(());
                };
                current = attached.clone();
                let valid = view
                    .update_in(cx, |this, _, cx| this.operation_valid(&attached, cx))
                    .unwrap_or(false);
                if !valid {
                    _ = view.update_in(cx, |this, _, cx| this.finish_cancelled(&attached, cx));
                    return Ok(());
                }
                let operations = if let Some(export) = &export {
                    vec![backend::OperationRequest::Execute {
                        sql: fragment.statements()[0].sql().to_owned(),
                        export: Some(export.clone()),
                    }]
                } else {
                    scripts::operations(&fragment)
                };
                // Publish the assessment query identity synchronously so Stop addresses this original helper.
                let request = view
                    .update_in(cx, |this, _, cx| {
                        if !this.operation_valid(&attached, cx) {
                            return Ok(None);
                        }
                        let request = client.begin_assessment(&session, operations)?;
                        if let Some(tab) = this.tabs.iter_mut().find(|t| t.id == id) {
                            tab.query_id = Some(request.query_id.clone())
                        }
                        Ok::<_, backend::BackendError>(Some(request))
                    })
                    .ok()
                    .transpose()?
                    .flatten();
                let Some(request) = request else {
                    client.revoke_authorization(&session).await?;
                    _ = view.update_in(cx, |this, _, cx| this.finish_cancelled(&attached, cx));
                    return Ok(());
                };
                let assessment = request.finish().await?;
                _ = view.update_in(cx, |this, _, _| {
                    if let Some(tab) = this
                        .tabs
                        .iter_mut()
                        .find(|t| t.id == id && t.owns(&attached))
                    {
                        tab.query_id = None
                    }
                });
                let expected_policy = backend::ExecutionPolicy {
                    environment: context
                        .settings
                        .as_ref()
                        .map(|p| {
                            if p.environment == "unset" {
                                "unspecified".into()
                            } else {
                                p.environment.clone()
                            }
                        })
                        .unwrap_or_default(),
                    read_only: context.settings.as_ref().is_some_and(|p| p.readonly),
                };
                if assessment.policy != expected_policy
                    || scripts::classifications(&fragment, &assessment).is_err()
                {
                    return Err(backend::BackendError::transport(
                        "The helper assessed a different execution context.",
                    ));
                }
                let valid = view
                    .update_in(cx, |this, _, cx| this.operation_valid(&attached, cx))
                    .unwrap_or(false);
                if !valid {
                    client.revoke_authorization(&session).await?;
                    _ = view.update_in(cx, |this, _, cx| this.finish_cancelled(&attached, cx));
                    return Ok(());
                }
                if assessment.rejected() {
                    _ = view.update_in(cx, |this, _, cx| {
                        this.finish_cancelled(&attached, cx);
                        if let Some(tab) = this.tabs.iter_mut().find(|t| t.id == id) {
                            tab.error = true;
                            tab.status =
                                "Execution rejected by the helper policy (readonly).".into();
                        }
                    });
                    return Ok(());
                }
                let execution = Execution {
                    context: attached,
                    session,
                    fragment,
                    assessment: assessment.clone(),
                    after,
                    export,
                };
                if (bind_editor && execution.fragment.kind() == sql::FragmentKind::Script)
                    || assessment.requires_confirmation()
                    || assessment.operations.iter().any(|o| o.statements.len() > 1)
                {
                    _ = view.update_in(cx, |this, window, cx| {
                        let Some(tab) = this.tabs.iter_mut().find(|t| t.id == id) else {
                            return;
                        };
                        tab.task = None;
                        tab.phase = Some(model::OperationPhase::Reviewing);
                        tab.status = "Awaiting execution confirmation".into();
                        this.confirm_query(
                            execution,
                            assessment
                                .operations
                                .iter()
                                .flat_map(|o| &o.statements)
                                .map(|s| s.reason.as_str())
                                .filter(|s| !s.is_empty())
                                .collect::<Vec<_>>()
                                .join("; "),
                            window,
                            cx,
                        );
                    });
                } else {
                    execute(view.clone(), cx, execution, client.clone()).await?;
                }
                Ok::<_, backend::BackendError>(())
            }
            .await;
            if let Err(error) = result {
                _ = view.update_in(cx, |this, window, cx| {
                    this.fail_live(&current, error, window, cx);
                    if let Some(intent) = &after {
                        this.cancel_close(intent, window, cx);
                    }
                });
            } else if let Some(intent) = &after {
                _ =
                    view.update_in(cx, |this, window, cx| {
                        // Failed/stale preparation must leave a retryable form.
                        // Successful close continuation owns its own task/dialog.
                        if this
                            .close_flow
                            .as_ref()
                            .is_some_and(|flow| flow.token == *intent)
                            && !window.has_active_dialog(cx)
                            && this.tabs.iter().find(|t| t.id == id).is_some_and(|t| {
                                !t.busy() && (t.transaction != "idle" || t.uncertain)
                            })
                        {
                            this.cancel_close(intent, window, cx);
                        }
                    });
            }
        }));
        cx.notify();
    }
    fn confirm_query(
        &mut self,
        execution: Execution,
        reason: String,
        window: &mut Window,
        cx: &mut Context<Self>,
    ) {
        if window.has_active_dialog(cx) || !self.operation_valid(&execution.context, cx) {
            self.cancel_review(execution, window, cx);
            return;
        }
        let profile = execution
            .context
            .settings
            .as_ref()
            .expect("saved execution profile");
        let label = format!(
            "{} / {} / {}:{} / {} / {} / {} / readonly={}. Review the entire immutable SQL source. Return and Escape cancel.",
            profile.name,
            profile.engine,
            profile.host,
            profile.port,
            profile.database,
            profile.user,
            profile.environment,
            profile.readonly
        );
        let classified = scripts::classifications(&execution.fragment, &execution.assessment)
            .expect("validated assessment");
        let reasons = classified
            .iter()
            .map(|c| {
                format!(
                    "Statement {} / {} / bytes {}..{} / UTF-16 {}..{} / {}",
                    c.operation + 1,
                    c.kind,
                    c.range.start,
                    c.range.end,
                    c.utf16.start,
                    c.utf16.end,
                    c.reason
                )
            })
            .collect::<Vec<_>>()
            .join("\n");
        let preview = cx.new(|cx| {
            let mut state =
                controls::sql_editor_state(execution.fragment.source_sql().to_owned(), window, cx);
            let offset = execution.fragment.span().bytes().start;
            let decorations = classified
                .iter()
                .map(|c| {
                    let color = match c.kind.as_str() {
                        "read" => rgb(0x429668),
                        "write" => rgb(0xc78b27),
                        _ => rgb(0xca5555),
                    };
                    gpui_kit::component::input::RangeDecoration::new(
                        c.range.start - offset..c.range.end - offset,
                    )
                    .with_style(gpui_kit::component::input::RangeDecorationStyle::Fill)
                    .with_color(color.into())
                })
                .collect();
            state.create_range_decorations_collection(decorations, cx);
            state
        });
        let view = cx.entity().downgrade();
        let original = execution.context.clone();
        let guard =
            controls::review_guard(view.clone(), move |w, cx| w.operation_valid(&original, cx));
        window.open_dialog(cx, move |dialog, _, cx| {
            let accept = view.clone();
            let cancel = view.clone();
            let key_cancel = view.clone();
            let escape_cancel = view.clone();
            let cancelled = execution.clone();
            let key_execution = execution.clone();
            let escape_execution = execution.clone();
            let approved = execution.clone();
            let input_cancel = view.clone();
            let input_execution = execution.clone();
            dialog
                .title("Review entire SQL batch")
                .accessibility_label("Review entire SQL batch")
                .w(px(780.))
                .overlay_closable(false)
                .close_button(false)
                // GPUI Confirm is deliberately Cancel: explicit Run is required.
                .on_ok(move |_, window, cx| {
                    _ = key_cancel.update(cx, |this, cx| {
                        this.cancel_review(key_execution.clone(), window, cx)
                    });
                    true
                })
                .on_cancel(move |_, window, cx| {
                    _ = escape_cancel.update(cx, |this, cx| {
                        this.cancel_review(escape_execution.clone(), window, cx)
                    });
                    true
                })
                .child(label.clone())
                .child(reason.clone())
                .child(
                    div()
                        .id("script-classifications")
                        .max_h(px(120.))
                        .overflow_y_scroll()
                        .child(reasons.clone()),
                )
                .child(
                    div()
                        .capture_key_down(move |event, window, cx| {
                            if matches!(event.keystroke.key.as_str(), "enter" | "escape") {
                                cx.stop_propagation();
                                window.close_dialog(cx);
                                _ = input_cancel.update(cx, |this, cx| {
                                    this.cancel_review(input_execution.clone(), window, cx)
                                });
                            }
                        })
                        .child(
                            controls::preview_editor(&preview, cx)
                                .accessibility_guard(guard.clone())
                                .accessibility_id("dbeer-sql-batch-review")
                                .aria_label("Entire immutable SQL batch")
                                .readonly(true)
                                .h(px(260.)),
                        ),
                )
                .footer(
                    div()
                        .flex()
                        .justify_end()
                        .gap_2()
                        .child(Button::new("cancel-execution").label("Cancel").on_click(
                            move |_, window, cx| {
                                window.close_dialog(cx);
                                _ = cancel.update(cx, |this, cx| {
                                    this.cancel_review(cancelled.clone(), window, cx)
                                });
                            },
                        ))
                        .child(
                            Button::new("confirm-execution")
                                .label("Run Reviewed SQL")
                                .on_click(move |_, window, cx| {
                                    window.close_dialog(cx);
                                    _ = accept.update(cx, |this, cx| {
                                        if !this.operation_valid(&approved.context, cx) {
                                            this.cancel_review(approved.clone(), window, cx);
                                            return;
                                        }
                                        let Some(client) = this
                                            .tabs
                                            .iter()
                                            .find(|t| t.id == approved.context.document)
                                            .and_then(|t| t.operation_client.clone())
                                        else {
                                            this.finish_cancelled(&approved.context, cx);
                                            return;
                                        };
                                        let execution = approved.clone();
                                        let recovery = execution.after;
                                        let id = execution.context.document;
                                        let tab =
                                            this.tabs.iter_mut().find(|t| t.id == id).unwrap();
                                        tab.status = "Running reviewed batch...".into();
                                        tab.task =
                                            Some(cx.spawn_in(window, async move |view, cx| {
                                                let context = execution.context.clone();
                                                if let Err(error) =
                                                    execute(view.clone(), cx, execution, client)
                                                        .await
                                                {
                                                    _ = view.update_in(cx, |this, window, cx| {
                                                        this.fail_live(&context, error, window, cx);
                                                        if let Some(intent) = &recovery {
                                                            this.cancel_close(intent, window, cx);
                                                        }
                                                    });
                                                }
                                            }));
                                        cx.notify();
                                    });
                                }),
                        ),
                )
        });
        cx.notify();
    }

    fn cancel_review(&mut self, execution: Execution, window: &mut Window, cx: &mut Context<Self>) {
        let Some(tab) = self
            .tabs
            .iter_mut()
            .find(|t| t.id == execution.context.document && t.owns(&execution.context))
        else {
            return;
        };
        let Some(client) = tab.operation_client.clone() else {
            self.finish_cancelled(&execution.context, cx);
            return;
        };
        tab.stop_requested = true;
        tab.phase = Some(model::OperationPhase::Cancelling);
        tab.status = "Cancelling unused batch authorization...".into();
        tab.task = Some(cx.spawn_in(window, async move |view, cx| {
            let result = client.revoke_authorization(&execution.session).await;
            _ = view.update_in(cx, |this, window, cx| {
                if let Err(error) = result {
                    this.fail_live(&execution.context, error, window, cx);
                } else {
                    this.finish_cancelled(&execution.context, cx);
                }
                if let Some(intent) = &execution.after {
                    this.cancel_close(intent, window, cx);
                }
            });
        }));
        cx.notify();
    }
    pub(super) fn finish_cancelled(&mut self, context: &OperationContext, cx: &mut Context<Self>) {
        if let Some(tab) = self.tabs.iter_mut().find(|t| t.id == context.document)
            && tab.end(context, model::ExecutionState::Cancelled, 0)
        {
            tab.task = None;
            tab.operation_client = None;
            tab.execution_decoration.clear(cx);
            tab.status = "Execution stopped. Remaining statements skipped.".into();
            self.record_statement_history(context, "Query cancelled", cx);
        }
        self.finish_run_file(context);
        cx.notify();
    }
    pub fn stop_live(&mut self, id: DocumentId, cx: &mut Context<Self>) {
        let Some(tab) = self.tabs.iter_mut().find(|t| t.id == id) else {
            return;
        };
        let Some(context) = tab.operation.clone() else {
            return;
        };
        tab.stop_requested = true;
        tab.phase = Some(model::OperationPhase::Cancelling);
        tab.status = "Cancellation requested. Waiting for the helper...".into();
        if let (Some(client), Some(session), Some(query)) = (
            tab.operation_client.clone(),
            tab.session.clone(),
            tab.query_id.clone(),
        ) {
            cx.spawn(
                async move |view, cx| match client.cancel(&session, &query).await {
                    Ok(outcome) => {
                        let _status = outcome.status;
                    }
                    Err(error) => {
                        _ = view.update(cx, |this, cx| {
                            if let Some(tab) = this.tabs.iter_mut().find(|t| {
                                t.id == id
                                    && t.owns(&context)
                                    && t.query_id.as_deref() == Some(&query)
                                    && !t.uncertain
                            }) {
                                tab.status = error.message.into();
                            }
                            cx.notify();
                        });
                    }
                },
            )
            .detach();
        } else if tab.task.is_none() {
            if let (Some(client), Some(session)) =
                (tab.operation_client.clone(), tab.session.clone())
            {
                tab.task = Some(cx.spawn(async move |view, cx| {
                    let result = client.revoke_authorization(&session).await;
                    _ = view.update(cx, |this, cx| {
                        // No submitted SQL here; a failed revocation retires the helper
                        // and retains the known transaction/unknown lock as appropriate.
                        if result.is_err() {
                            this.invalidate_dead_helper();
                        }
                        this.finish_cancelled(&context, cx);
                    });
                }));
            } else {
                self.finish_cancelled(&context, cx);
            }
        }
        cx.notify();
    }
    pub(super) fn fail_live(
        &mut self,
        context: &OperationContext,
        error: backend::BackendError,
        window: &mut Window,
        cx: &mut Context<Self>,
    ) {
        let valid = self.operation_source_valid(context, cx);
        let Some(tab) = self
            .tabs
            .iter_mut()
            .find(|t| t.id == context.document && t.owns(context))
        else {
            return;
        };
        let client_alive = tab
            .operation_client
            .as_ref()
            .is_none_or(BackendClient::is_alive);
        // Preparation/revocation may fail between terminals. Attribute that
        // failure to unsubmitted work, preserving the completed prefix exactly.
        if tab
            .executions
            .get(tab.active_execution)
            .is_some_and(|e| e.state == model::ExecutionState::Succeeded)
            && let Some(next) = tab
                .executions
                .iter()
                .position(|e| e.state == model::ExecutionState::Pending)
        {
            tab.active_execution = next;
            tab.selected_execution = next;
        }
        if let Some(export) = self
            .run_file
            .as_ref()
            .filter(|f| {
                f.operation.as_ref().is_some_and(|o| {
                    o.document == context.document && o.operation == context.operation
                })
            })
            .and_then(|f| f.export.clone())
        {
            tab.run_file_recovery = Some(run_to_file::Recovery {
                client: tab.operation_client.clone(),
                operation: context.operation,
                query: tab.query_id.clone(),
                session: tab.session.clone(),
                session_generation: context.session_generation,
                sql_completed: error.sql_completed,
                outcome_unknown: error.outcome_unknown,
                publication: if error.export_publication
                    == Some(backend::ExportPublication::Unknown)
                    || error.outcome_unknown
                {
                    run_to_file::Publication::Unknown
                } else {
                    run_to_file::Publication::NotPublished
                },
                export,
            });
        }
        tab.uncertain |= error.outcome_unknown;
        if let Some(tx) = error.transaction_status {
            tab.transaction = transaction(tx);
        }
        // Never invent an idle outcome when a connection disappears mid-transaction.
        if !error.connected && tab.transaction != "idle" && error.transaction_status.is_none() {
            tab.uncertain = true;
        }
        if !client_alive && tab.transaction != "idle" {
            tab.uncertain = true;
        }
        let state = if tab.uncertain {
            model::ExecutionState::Unknown
        } else if error.sql_not_executed {
            model::ExecutionState::Skipped
        } else if !valid && !tab.stop_requested {
            model::ExecutionState::Stale
        } else if error.category == "cancelled" || tab.stop_requested {
            model::ExecutionState::Cancelled
        } else {
            model::ExecutionState::Failed
        };
        let mapped = tab
            .execution_editor_bound
            .then_some(())
            .and(tab.execution_source.as_ref())
            .as_ref()
            .and_then(|fragment| fragment.statements().get(tab.active_execution))
            .and_then(|statement| {
                statement
                    .map_adapter_error(error.error_position)
                    .ok()
                    .flatten()
            });
        let count = error.result_sets.len();
        let duration_ms = tab
            .executions
            .get(tab.active_execution)
            .and_then(|e| e.started_at)
            .map_or(0., |start| start.elapsed().as_secs_f64() * 1000.);
        let row_count = error
            .result_sets
            .iter()
            .map(|set| set.row_count)
            .fold(0u64, u64::saturating_add);
        tab.record_statement(
            context,
            state,
            error.result_sets,
            model::ExecutionMetrics {
                duration_ms,
                row_count,
                truncated: false,
            },
            valid,
        );
        let active = tab.active_execution;
        if let Some(execution) = tab.executions.get_mut(active) {
            execution.failure = Some(error.message.clone());
            execution.error_position = mapped;
        }
        if valid {
            tab.error_position = mapped;
        }
        tab.end(context, state, count);
        tab.task = None;
        tab.operation_client = None;
        if tab
            .session_client()
            .is_some_and(|c| c.owned_process_exited())
        {
            tab.retire_session();
        }
        tab.error = true;
        tab.status = if tab.uncertain {
            "Outcome unknown. Verify the database; execution is blocked until disconnect.".into()
        } else if !valid {
            "Operation ended after the source or connection context changed; results discarded."
                .into()
        } else {
            format!(
                "{} [{}{}{}]",
                error.message,
                error.category,
                error
                    .sql_state
                    .as_ref()
                    .map(|s| format!(" / SQLSTATE {s}"))
                    .unwrap_or_default(),
                error
                    .error_position
                    .map(|p| format!(" / position {p}"))
                    .unwrap_or_default()
            )
            .into()
        };
        tab.execution_decoration.clear(cx);
        if valid && let Some(position) = mapped {
            let source = tab.execution_source.as_ref().unwrap().source();
            let end = source.text()[position.source.byte..]
                .chars()
                .next()
                .map_or(position.source.byte, |c| {
                    position.source.byte + c.len_utf8()
                });
            tab.execution_decoration.set(
                vec![
                    gpui_kit::component::input::RangeDecoration::new(position.source.byte..end)
                        .with_color(rgb(0xca5555).into()),
                ],
                cx,
            );
        }
        if error.sql_not_executed {
            tab.status="SQL was not executed. The export destination was unavailable, changed or unsupported. Review it before trying again.".into();
        }
        if error.sql_completed {
            tab.status = if error.export_publication == Some(backend::ExportPublication::Unknown) {
                "SQL completed. File publication is unverified; inspect the destination. Do not rerun SQL to recover the save.".into()
            } else {
                "SQL completed, but the file was not published. The previous destination was preserved. Do not rerun SQL to recover the save.".into()
            };
        }
        let history_outcome = restoration::failure_outcome(&error.category, tab.uncertain);
        self.finish_run_file(context);
        if !error.sql_not_executed {
            self.record_statement_history(context, history_outcome, cx);
        }
        self.render_live_result(context.document, window, cx);
        self.refresh_connection_flags();
        cx.notify();
    }
    /// Compatibility entry for single-operation callers and close resolution.
    pub(super) fn finish_live(
        &mut self,
        context: &OperationContext,
        outcome: QueryOutcome,
        window: &mut Window,
        cx: &mut Context<Self>,
    ) {
        self.record_live_statement(context, outcome, window, cx);
        self.end_live_batch(context, window, cx);
    }

    pub(super) fn record_live_statement(
        &mut self,
        context: &OperationContext,
        outcome: QueryOutcome,
        window: &mut Window,
        cx: &mut Context<Self>,
    ) {
        let valid = self.operation_source_valid(context, cx);
        let Some(tab) = self
            .tabs
            .iter_mut()
            .find(|t| t.id == context.document && t.owns(context))
        else {
            return;
        };
        let client_alive = tab
            .operation_client
            .as_ref()
            .is_none_or(BackendClient::is_alive);
        if outcome.export.is_some()
            && let Some(export) = self.run_file.as_ref().and_then(|f| f.export.clone())
        {
            tab.run_file_recovery = Some(run_to_file::Recovery {
                client: tab.operation_client.clone(),
                operation: context.operation,
                query: tab.query_id.clone(),
                session: tab.session.clone(),
                session_generation: context.session_generation,
                sql_completed: true,
                outcome_unknown: false,
                publication: run_to_file::Publication::Published,
                export,
            });
        }
        tab.transaction = transaction(outcome.transaction_status);
        if !client_alive && tab.transaction != "idle" {
            tab.uncertain = true;
        }
        let state = if tab.uncertain {
            model::ExecutionState::Unknown
        } else if tab.stop_requested && outcome.export.is_none() {
            model::ExecutionState::Cancelled
        } else if valid {
            model::ExecutionState::Succeeded
        } else {
            model::ExecutionState::Stale
        };
        tab.record_statement(
            context,
            state,
            outcome.result_sets,
            model::ExecutionMetrics {
                duration_ms: outcome.duration_ms,
                row_count: outcome.row_count,
                truncated: outcome.truncated,
            },
            valid,
        );
        tab.error = false;
        tab.phase = Some(model::OperationPhase::Preparing);
        tab.status = if valid {
            format!(
                "Statement {} / {} / {} rows / {:.1} ms / {}{} {}",
                tab.active_execution + 1,
                outcome.command_tag,
                outcome.row_count,
                outcome.duration_ms,
                tab.transaction,
                if outcome.truncated || tab.display_budget.truncated {
                    " / DISPLAY TRUNCATED"
                } else {
                    ""
                },
                outcome.display_notice
            )
            .into()
        } else if tab.stop_requested {
            "Stopped after terminal recovery. Remaining statements skipped.".into()
        } else {
            format!("Operation finished / {}. Source or connection context changed; current results discarded.", tab.transaction).into()
        };
        tab.execution_decoration.clear(cx);
        if !client_alive && tab.transaction != "idle" {
            tab.status = "Transaction session lost after completion. Verify the database before disconnecting.".into();
        }
        if let Some(export) = outcome.export {
            tab.status = format!(
                "SQL completed / {} rows exported as {} / {}. File published.{}",
                export.row_count,
                match export.format {
                    backend::ExportFormat::Json => "JSON",
                    backend::ExportFormat::Csv => "CSV",
                },
                tab.transaction,
                if !valid {
                    " Original source context changed; current results discarded."
                } else if tab.stop_requested {
                    " Stop arrived after publication."
                } else {
                    ""
                }
            )
            .into();
        }
        // Retire only after end_live_batch: changing the generation here would
        // prevent the authoritative operation from releasing its busy lock.
        let history_outcome = if tab.uncertain {
            "Unknown outcome"
        } else {
            "Completed"
        };
        self.record_statement_history(context, history_outcome, cx);
        self.render_live_result(context.document, window, cx);
        self.refresh_connection_flags();
        cx.notify();
    }

    pub(super) fn end_live_batch(
        &mut self,
        context: &OperationContext,
        window: &mut Window,
        cx: &mut Context<Self>,
    ) {
        let Some(tab) = self
            .tabs
            .iter_mut()
            .find(|t| t.id == context.document && t.owns(context))
        else {
            return;
        };
        let state = tab.executions[tab.active_execution].state;
        let count = tab.result_sets.len();
        let client_alive = tab
            .operation_client
            .as_ref()
            .is_none_or(BackendClient::is_alive);
        tab.end(context, state, count);
        tab.task = None;
        tab.operation_client = None;
        tab.execution_decoration.clear(cx);
        if !client_alive
            && tab
                .session_client()
                .is_some_and(|c| c.owned_process_exited())
        {
            tab.retire_session();
        }
        if tab.executions.len() > 1 {
            let completed = tab
                .executions
                .iter()
                .filter(|e| e.state == model::ExecutionState::Succeeded)
                .count();
            let elapsed: f64 = tab.executions.iter().map(|e| e.duration_ms).sum();
            let rows: u64 = tab
                .executions
                .iter()
                .map(|e| e.row_count)
                .fold(0u64, u64::saturating_add);
            tab.status = format!(
                "Script: {completed}/{} completed / {rows} rows / {elapsed:.1} ms / {}{}{}",
                tab.executions.len(),
                tab.transaction,
                if tab.display_budget.truncated {
                    " / DISPLAY TRUNCATED"
                } else {
                    ""
                },
                if tab.uncertain {
                    " / OUTCOME UNKNOWN"
                } else if tab.stop_requested {
                    " / STOPPED"
                } else {
                    ""
                }
            )
            .into();
        }
        self.finish_run_file(context);
        self.render_live_result(context.document, window, cx);
        self.refresh_connection_flags();
        cx.notify();
    }

    pub(super) fn navigate_execution_error(
        &mut self,
        id: DocumentId,
        window: &mut Window,
        cx: &mut Context<Self>,
    ) {
        let Some(index) = self.tabs.iter().position(|t| t.id == id) else {
            return;
        };
        let tab = &self.tabs[index];
        let Some(position) = tab.error_position else {
            return;
        };
        if tab
            .execution_source
            .as_ref()
            .is_none_or(|f| f.source().text() != tab.editor.read(cx).value().as_ref())
        {
            return;
        }
        self.active = index;
        self.tabs[index].editor.update(cx, |editor, cx| {
            editor.set_selected_range(position.source.byte..position.source.byte, cx);
            editor.focus(window, cx);
        });
        cx.notify();
    }
    pub fn cycle_result(&mut self, window: &mut Window, cx: &mut Context<Self>) {
        let tab = &mut self.tabs[self.active];
        if !tab.result_sets.is_empty() {
            tab.selected_result = (tab.selected_result + 1) % tab.result_sets.len();
            tab.selected_execution = tab
                .executions
                .iter()
                .position(|e| e.results.contains(&tab.selected_result))
                .unwrap_or(0);
        }
        let id = tab.id;
        self.render_live_result(id, window, cx);
        cx.notify();
    }
    pub(super) fn render_live_result(
        &mut self,
        id: DocumentId,
        window: &mut Window,
        cx: &mut Context<Self>,
    ) {
        let edit_target = self.tabs.iter().find(|t| t.id == id).and_then(|tab| {
            let doc = tab.catalog_document.as_ref()?;
            self.profile_index(&tab.profile)
                .and_then(|index| self.catalog_target(index, doc.target.node.clone()))
        });
        let policy_readonly = self.tabs.iter().find(|t| t.id == id).is_some_and(|t| {
            self.profile(&t.profile)
                .config
                .as_ref()
                .is_some_and(|p| p.readonly)
        });
        let Some(tab) = self.tabs.iter_mut().find(|t| t.id == id) else {
            return;
        };
        let table_context = tab.catalog_document.as_ref().and_then(|d| d.table.as_ref());
        let epoch = if table_context.is_some() {
            0
        } else {
            tab.executions.first().map(|e| e.operation).unwrap_or(1)
        };
        let key = (epoch, tab.selected_result);
        let snapshot = table_context.map(|t| t.snapshot).unwrap_or(epoch);
        let scope = table_context.map(|t| t.navigation.clone());
        let metadata = tab
            .catalog_document
            .as_ref()
            .map(|d| d.columns.clone())
            .unwrap_or_default();
        let reason = if let model::DocumentKind::Table { object_kind, .. } = &tab.kind {
            crate::grid_changes::readonly_reason(
                object_kind == "table",
                edit_target.is_some(),
                policy_readonly,
                &metadata,
            )
            .unwrap_or_default()
        } else {
            "Query results are read only.".into()
        };
        let selected_belongs = tab.executions.is_empty()
            || tab
                .executions
                .get(tab.selected_execution)
                .is_some_and(|e| e.results.contains(&tab.selected_result));
        if let Some(set) = tab
            .result_sets
            .get(tab.selected_result)
            .filter(|set| selected_belongs && !set.columns.is_empty())
        {
            let columns = set
                .columns
                .iter()
                .enumerate()
                .map(|(index, c)| demo::Column {
                    name: c.name.clone(),
                    data_type: if c.encoding.as_deref() == Some("base64") {
                        format!("{} / base64", c.native_type)
                    } else {
                        c.native_type.clone()
                    },
                    width: {
                        let max_value = set
                            .rows
                            .iter()
                            .filter_map(|row| row.get(index).and_then(|v| v.as_ref()))
                            .map(|v| v.chars().take(40).count())
                            .max()
                            .unwrap_or(0);
                        let max_value = max_value
                            + if c.encoding.as_deref() == Some("base64") {
                                7
                            } else {
                                0
                            };
                        let length = max_value
                            .max(c.name.chars().count())
                            .max(c.native_type.chars().count());
                        (length as f32 * 7.3 + 32.).clamp(90., 340.)
                    },
                })
                .collect();
            let rows = set
                .rows
                .iter()
                .map(|row| {
                    row.iter()
                        .zip(&set.columns)
                        .map(|(value, column)| match value {
                            None => demo::Cell::Null,
                            Some(v) if column.encoding.as_deref() == Some("base64") => {
                                demo::Cell::Binary(v.clone())
                            }
                            Some(v) if numeric_type(&column.native_type) => {
                                demo::Cell::Number(v.clone())
                            }
                            Some(v) => demo::Cell::Text(v.clone()),
                        })
                        .collect()
                })
                .collect();
            let mut grid = ResultGrid::new(demo::QueryResult { columns, rows });
            grid.bind(set.clone(), metadata, snapshot, scope, reason);
            grid.edit_owner = edit_target.map(|target| crate::changes_view::Owner {
                document: id,
                result: key,
                target,
                workspace: cx.entity().downgrade(),
            });
            grid.set_filter(&tab.filter.read(cx).value());
            let filter = tab.filter.read(cx).value();
            if let Some(existing) = tab.grid_views.get(&key) {
                existing.update(cx, |table, cx| {
                    if table.delegate().snapshot != snapshot
                        || table.delegate().original != grid.original
                    {
                        if table.delegate().has_drafts() {
                            return;
                        }
                        let compatible = table.delegate().same_schema(&grid);
                        table.delegate_mut().replace(grid);
                        if !compatible {
                            table
                                .horizontal_scroll_handle
                                .set_offset(Default::default());
                            table.scroll_to_row(0, cx);
                        }
                        table.clear_selection(cx);
                        table.refresh(cx);
                    }
                    table.delegate_mut().set_filter(&filter);
                    table.delegate_mut().sync_details(window, cx);
                    cx.notify();
                });
                tab.grid = Some(existing.clone());
            } else {
                let previous = tab
                    .grid_views
                    .iter()
                    .rev()
                    .find(|((_, result), _)| *result == key.1)
                    .map(|(_, grid)| grid.clone());
                if let Some(old) = &previous {
                    grid.inherit_presentation(old.read(cx).delegate());
                }
                let same_schema = previous
                    .as_ref()
                    .is_some_and(|old| grid.same_schema(old.read(cx).delegate()));
                let offset = previous
                    .as_ref()
                    .filter(|_| same_schema)
                    .map(|old| old.read(cx).horizontal_scroll_handle.offset());
                // New operations cannot retain the previous result's selection/entities.
                if epoch != 0 && tab.grid_views.keys().any(|(old, _)| *old != epoch) {
                    tab.grid_views.clear();
                    tab.grid_subscriptions.clear();
                }
                let entity = cx.new(|cx| {
                    let mut table = TableState::new(grid, window, cx)
                        .cell_selectable(false)
                        .row_selectable(false)
                        .col_selectable(false)
                        .row_header(false);
                    table.loop_selection = false;
                    if let Some(offset) = offset {
                        table.horizontal_scroll_handle.set_offset(offset);
                    }
                    table
                });
                tab.grid_subscriptions
                    .push(cx.observe(&entity, |_, _, cx| cx.notify()));
                tab.grid_subscriptions.push(cx.subscribe(
                    &entity,
                    |_, entity, event: &gpui_kit::component::table::TableEvent, cx| {
                        if let gpui_kit::component::table::TableEvent::ColumnWidthsChanged(widths) =
                            event
                        {
                            entity
                                .update(cx, |table, _| table.delegate_mut().widths_changed(widths));
                        }
                        cx.notify();
                    },
                ));
                tab.grid_views.insert(key, entity.clone());
                tab.grid = Some(entity);
            }
        } else {
            tab.grid = None;
        }
    }
}

async fn execute(
    view: WeakEntity<Workspace>,
    cx: &mut AsyncWindowContext,
    execution: Execution,
    client: BackendClient,
) -> std::result::Result<(), backend::BackendError> {
    let Execution {
        context,
        session,
        fragment,
        assessment,
        after,
        export,
    } = execution;
    for (index, statement) in fragment.statements().iter().enumerate() {
        // Validation, submission and active query identity are one UI turn. Edits,
        // Stop, tab changes and profile callbacks cannot interleave this capture.
        let stream = view
            .update_in(cx, |this, _, cx| {
                if !this.operation_valid(&context, cx) || !client.is_alive() {
                    return Ok(None);
                }
                let tab = this
                    .tabs
                    .iter_mut()
                    .find(|t| t.id == context.document)
                    .unwrap();
                tab.active_execution = index;
                let stream = if let Some(export) = &export {
                    client.run_to_file(
                        &session,
                        statement.sql().to_owned(),
                        export.clone(),
                        assessment.authorization.clone(),
                    )?
                } else {
                    client.execute_authorized(
                        &session,
                        statement.sql().to_owned(),
                        assessment.authorization.clone(),
                    )?
                };
                tab.started(&context, stream.query_id.clone());
                if tab.execution_editor_bound {
                    tab.execution_decoration.set(
                        vec![gpui_kit::component::input::RangeDecoration::new(
                            statement.span().bytes(),
                        )],
                        cx,
                    );
                }
                tab.status = format!(
                    "Running statement {} / {}...",
                    index + 1,
                    fragment.statements().len()
                )
                .into();
                cx.notify();
                Ok::<_, backend::BackendError>(Some(stream))
            })
            .ok()
            .transpose();
        let stream = match stream {
            Ok(stream) => stream.flatten(),
            Err(error) => {
                if client.is_alive() {
                    let _ = client.revoke_authorization(&session).await;
                }
                return Err(error);
            }
        };
        let Some(stream) = stream else {
            // No SQL submitted. Destroy any unconsumed batch grant before releasing
            // the operation lock; future commands cannot race grant revocation.
            client.revoke_authorization(&session).await?;
            _ = view.update_in(cx, |this, _, cx| this.finish_cancelled(&context, cx));
            return Ok(());
        };
        let mut terminal = false;
        while let Ok(event) = stream.events.recv().await {
            let event = match event {
                Ok(event) => event,
                Err(error) => {
                    if client.is_alive() {
                        let _ = client.revoke_authorization(&session).await;
                    }
                    return Err(error);
                }
            };
            match event {
                QueryEvent::ExportProgress {
                    result_index,
                    row_count,
                } => {
                    _=view.update_in(cx,|this,_,cx|{if let Some(tab)=this.tabs.iter_mut().find(|t|t.id==context.document && t.owns(&context)){tab.status=format!("Exporting result {} / {row_count} full rows streamed. Waiting for authoritative completion...",result_index+1).into();cx.notify()}});
                }
                QueryEvent::Started => {}
                QueryEvent::Chunk {
                    row_count,
                    result_index,
                } => {
                    _ = view.update_in(cx, |this, _, cx| {
                        if this.operation_valid(&context, cx)
                            && let Some(tab) =
                                this.tabs.iter_mut().find(|t| t.id == context.document)
                        {
                            tab.status = format!(
                                "Statement {} / result {}: {row_count} rows",
                                index + 1,
                                result_index + 1
                            )
                            .into();
                            cx.notify();
                        }
                    });
                }
                QueryEvent::Finished(outcome) => {
                    // Drained regardless of edits or Stop: authoritative transaction
                    // reconciliation always belongs to the original physical session.
                    _ = view.update_in(cx, |this, window, cx| {
                        if fragment.statements().len() == 1 {
                            this.finish_live(&context, outcome, window, cx);
                        } else {
                            this.record_live_statement(&context, outcome, window, cx);
                        }
                    });
                    terminal = true;
                    break;
                }
            }
        }
        if !terminal {
            let mut error = backend::BackendError::transport(
                "The helper closed the query stream before a terminal outcome.",
            );
            error.outcome_unknown = true;
            return Err(error);
        }
        let proceed = view
            .update_in(cx, |this, _, cx| {
                this.operation_valid(&context, cx) && client.is_alive()
            })
            .unwrap_or(false);
        if !proceed || index + 1 == fragment.statements().len() {
            if index + 1 < fragment.statements().len() {
                client.revoke_authorization(&session).await?;
            }
            _ = view.update_in(cx, |this, window, cx| {
                this.end_live_batch(&context, window, cx);
                if let Some(intent) = after {
                    if this
                        .tabs
                        .iter()
                        .find(|t| t.id == context.document)
                        .is_some_and(|t| !t.busy() && t.transaction == "idle" && !t.uncertain)
                    {
                        this.resume_close(intent, window, cx);
                    } else {
                        this.cancel_close(&intent, window, cx);
                    }
                }
            });
            return Ok(());
        }
    }
    Ok(())
}
