//! Captured loaded-result export. This workflow never calls the database/helper.
use super::*;
use exports::{ExportError, Format, PreparedExport};
use std::{path::PathBuf, sync::Arc};

#[derive(Clone)]
pub(super) struct ExportCapture {
    document: DocumentId,
    profile: ProfileId,
    profile_generation: u64,
    settings: Option<ConnectionProfile>,
    kind: model::DocumentKind,
    title: String,
    source_revision: u64,
    session_generation: u64,
    session: Option<String>,
    result: usize,
    execution: usize,
    grid: EntityId,
    snapshot: u64,
    draft_revision: u64,
    table_revision: Option<u64>,
    format: Format,
    loaded: Arc<backend::ResultSet>,
}
#[derive(Clone, Copy, PartialEq, Eq)]
enum Phase {
    Review,
    Choosing,
    Encoding,
    Writing,
}
pub(super) struct ExportRequest {
    phase: Phase,
    pub(super) token: u64,
    pub(super) cancelled: bool,
    capture: Arc<ExportCapture>,
    target: Option<PathBuf>,
    bytes: Option<Arc<str>>,
}
struct ExportReview {
    workspace: WeakEntity<Workspace>,
    token: u64,
    marker: Entity<InputState>,
    format: Format,
    disclosure: String,
    error: Option<String>,
}
impl ExportReview {
    fn cancel(&mut self, window: &mut Window, cx: &mut Context<Self>) {
        let owned = self
            .workspace
            .update(cx, |this, cx| {
                if !this
                    .export_request
                    .as_ref()
                    .is_some_and(|r| r.token == self.token && r.phase == Phase::Review)
                {
                    return false;
                }
                this.end_loaded_export(self.token, None, false, cx);
                true
            })
            .unwrap_or(false);
        if owned {
            window.close_dialog(cx);
        }
    }
    fn choose(&mut self, window: &mut Window, cx: &mut Context<Self>) {
        let marker = self.marker.read(cx).value().to_string();
        let result = self.workspace.update(cx, |this, cx| {
            this.choose_loaded_export(self.token, &marker, window, cx)
        });
        match result {
            Ok(Ok(())) => {}
            Ok(Err(error)) => self.error = Some(error.to_string()),
            Err(_) => window.close_dialog(cx),
        }
        cx.notify();
    }
}
impl Render for ExportReview {
    fn render(&mut self, _: &mut Window, cx: &mut Context<Self>) -> impl IntoElement {
        div().flex().flex_col().gap_3()
            .child(self.disclosure.clone())
            .when(self.format == Format::Csv, |content| content
                .child("SQL NULL uses this marker. It must not equal any loaded value. Binary values use Base64.")
                .child(Input::new(&self.marker)))
            .when_some(self.error.clone(), |content, error| content.child(div().text_color(cx.theme().danger).child(error)))
            .child(div().flex().gap_2().justify_end()
                .child(Button::new("cancel-loaded-export").label("Cancel").on_click(cx.listener(|this, _, window, cx| this.cancel(window, cx))))
                .child(Button::new("choose-loaded-export").label("Choose Destination...").on_click(cx.listener(|this, _, window, cx| this.choose(window, cx)))))
    }
}
impl Workspace {
    pub(super) fn export_activity_document(&self) -> Option<DocumentId> {
        self.export_request.as_ref().map(|r| r.capture.document)
    }
    /// A clean disconnected snapshot is valid: no live connection is required.
    /// This check deliberately ignores export_request itself, so an owner does
    /// not invalidate its own immutable capture after reserving the chooser.
    pub(super) fn loaded_export_snapshot_available(&self, id: DocumentId, cx: &App) -> bool {
        self.loaded_export_snapshot(id, cx).is_some()
    }
    fn loaded_export_snapshot(&self, id: DocumentId, cx: &App) -> Option<backend::ResultSet> {
        if self.closing
            || self.close_flow.is_some()
            || self.file_request.is_some()
            || self.transfer_task.is_some()
            || self.changes_preview.is_some()
        {
            return None;
        }
        let tab = self.tabs.iter().find(|t| t.id == id)?;
        if tab.busy() || tab.task.is_some() || tab.uncertain || tab.operation.is_some() {
            return None;
        }
        if matches!(tab.kind, model::DocumentKind::Table { .. }) {
            let doc = tab.catalog_document.as_ref()?;
            // Sibling work on the same object also makes confirmation ambiguous.
            if self
                .tabs
                .iter()
                .filter(|t| t.profile == tab.profile)
                .any(|t| {
                    t.catalog_document.as_ref().is_some_and(|other| {
                        other.target.node == doc.target.node
                            && (other.loading
                                || t.task.is_some()
                                || t.snapshot_locked()
                                || other.table.as_ref().is_some_and(|table| {
                                    table.pending.is_some() || table.locks.locked()
                                })
                                || t.grid_views
                                    .values()
                                    .any(|g| g.read(cx).delegate().has_drafts()))
                    })
                })
            {
                return None;
            }
            return self.confirmed_loaded_table_snapshot(id, cx);
        }
        let set = tab.result_sets.get(tab.selected_result)?;
        let grid = tab.grid.as_ref()?.read(cx).delegate();
        (grid.context_valid && !grid.has_drafts() && &grid.original == set).then(|| set.clone())
    }
    pub(super) fn capture_loaded_export(
        &self,
        format: Format,
        cx: &App,
    ) -> Result<ExportCapture, &'static str> {
        let tab = self
            .tabs
            .get(self.active)
            .ok_or("No loaded result is available.")?;
        let loaded = self.loaded_export_snapshot(tab.id, cx).ok_or(
            "Export requires an idle confirmed loaded snapshot without pending edits or recovery.",
        )?;
        exports::validate(&loaded)
            .map_err(|_| "The loaded result is invalid and could not be exported.")?;
        let grid = tab.grid.as_ref().unwrap();
        let profile = self.profile(&tab.profile);
        Ok(ExportCapture {
            document: tab.id,
            profile: tab.profile.clone(),
            profile_generation: profile.generation,
            settings: profile.config.clone(),
            kind: tab.kind.clone(),
            title: tab.title.clone(),
            source_revision: tab.generation,
            session_generation: tab.session_generation,
            session: tab.session.clone(),
            result: tab.selected_result,
            execution: tab.selected_execution,
            grid: grid.entity_id(),
            snapshot: grid.read(cx).delegate().snapshot,
            draft_revision: grid.read(cx).delegate().draft_revision(),
            table_revision: tab
                .catalog_document
                .as_ref()
                .and_then(|d| d.table.as_ref())
                .map(|t| t.revision),
            format,
            loaded: Arc::new(loaded),
        })
    }
    pub(super) fn loaded_export_capture_valid(&self, capture: &ExportCapture, cx: &App) -> bool {
        let Some(tab) = self.tabs.iter().find(|t| t.id == capture.document) else {
            return false;
        };
        self.profiles.iter().any(|p| {
            p.id == capture.profile
                && p.generation == capture.profile_generation
                && p.config == capture.settings
        }) && tab.profile == capture.profile
            && tab.kind == capture.kind
            && tab.title == capture.title
            && tab.generation == capture.source_revision
            && tab.session_generation == capture.session_generation
            && tab.session == capture.session
            && tab.selected_result == capture.result
            && tab.selected_execution == capture.execution
            && tab.grid.as_ref().is_some_and(|grid| {
                grid.entity_id() == capture.grid
                    && grid.read(cx).delegate().context_valid
                    && grid.read(cx).delegate().snapshot == capture.snapshot
                    && grid.read(cx).delegate().draft_revision() == capture.draft_revision
            })
            && tab
                .catalog_document
                .as_ref()
                .and_then(|d| d.table.as_ref())
                .map(|t| t.revision)
                == capture.table_revision
            && (if self.closing {
                self.export_request.as_ref().is_some_and(|r| {
                    !r.cancelled
                        && self.close_owns_activity(close::Activity::Export(r.token))
                        && Arc::ptr_eq(&r.capture.loaded, &capture.loaded)
                }) && !tab.busy()
                    && !tab.uncertain
                    && tab.result_sets.get(capture.result) == Some(capture.loaded.as_ref())
                    && tab
                        .grid
                        .as_ref()
                        .is_some_and(|g| !g.read(cx).delegate().has_drafts())
                    && tab
                        .catalog_document
                        .as_ref()
                        .and_then(|d| d.table.as_ref())
                        .is_none_or(|t| {
                            t.recovery == tables::ChangesRecovery::Ready && t.pending.is_none()
                        })
            } else {
                self.loaded_export_snapshot(capture.document, cx).as_ref()
                    == Some(capture.loaded.as_ref())
            })
    }
    fn loaded_export_valid(&self, token: u64, cx: &App) -> bool {
        self.export_request.as_ref().is_some_and(|r| {
            r.token == token && !r.cancelled && self.loaded_export_capture_valid(&r.capture, cx)
        })
    }
    pub(super) fn start_loaded_export(
        &mut self,
        capture: Arc<ExportCapture>,
        window: &mut Window,
        cx: &mut Context<Self>,
    ) {
        if (self.export_request.is_some() || self.run_file.is_some())
            || window.has_active_dialog(cx)
            || window.has_active_prompt()
            || !self.loaded_export_capture_valid(&capture, cx)
        {
            return;
        }
        self.next_export_request += 1;
        let token = self.next_export_request;
        self.export_request = Some(ExportRequest {
            cancelled: false,
            phase: Phase::Review,
            token,
            capture: capture.clone(),
            target: None,
            bytes: None,
        });
        let loaded = &capture.loaded;
        let disclosure = format!(
            "Export {} loaded physical rows in original order. Reported result count: {}. {} Local sort, filter and selection do not restrict this export. No SQL is run.",
            loaded.rows.len(),
            loaded.row_count,
            if loaded.truncated {
                "The result is truncated; unloaded rows are excluded."
            } else {
                "This exports the already loaded result only."
            }
        );
        let workspace = cx.entity().downgrade();
        let review = cx.new(|cx| ExportReview {
            workspace: workspace.clone(),
            token,
            marker: cx.new(|cx| {
                InputState::new(window, cx)
                    .default_value("\\N")
                    .placeholder("CSV NULL marker")
            }),
            format: capture.format,
            disclosure: disclosure.clone(),
            error: None,
        });
        window.open_dialog(cx, move |dialog, _, _| {
            let cancel = review.clone();
            let escape = review.clone();
            dialog
                .title("Export Loaded Result")
                .accessibility_label("Export Loaded Result")
                .w(px(600.))
                .overlay_closable(false)
                .close_button(false)
                .on_ok(move |_, window, cx| {
                    cancel.update(cx, |this, cx| this.cancel(window, cx));
                    true
                })
                .on_cancel(move |_, window, cx| {
                    escape.update(cx, |this, cx| this.cancel(window, cx));
                    true
                })
                .content({
                    let review = review.clone();
                    move |content, _, _| content.child(review.clone())
                })
        });
        cx.notify();
    }
    fn choose_loaded_export(
        &mut self,
        token: u64,
        marker: &str,
        window: &mut Window,
        cx: &mut Context<Self>,
    ) -> Result<(), ExportError> {
        if !self
            .export_request
            .as_ref()
            .is_some_and(|r| r.token == token && r.phase == Phase::Review)
        {
            return Ok(());
        }
        if !self.loaded_export_valid(token, cx) {
            window.close_dialog(cx);
            self.end_loaded_export(token, None, false, cx);
            return Ok(());
        }
        let capture = self.export_request.as_ref().unwrap().capture.clone();
        if capture.format == Format::Csv {
            exports::validate_marker(&capture.loaded, marker)?;
        }
        self.export_request.as_mut().unwrap().phase = Phase::Choosing;
        window.close_dialog(cx);
        let directory = std::env::current_dir().unwrap_or_else(|_| std::env::temp_dir());
        let name = capture
            .format
            .suggested_name(&capture.title, capture.loaded.rows.len());
        // GPUI's platform Save picker owns overwrite confirmation. It has no
        // extension/content-type filter; keep the exact confirmed path unchanged.
        let selected = cx.prompt_for_new_path(&directory, Some(&name));
        let marker = marker.to_owned();
        self.export_task = Some(cx.spawn_in(window, async move |this, cx| {
            let result = selected.await;
            _ = this.update_in(cx, |this, window, cx| {
                if !this.loaded_export_valid(token, cx) {
                    this.end_loaded_export(token, None, false, cx);
                    return;
                }
                match result {
                    Ok(Ok(Some(path))) => {
                        this.prepare_loaded_export(token, path, marker, window, cx)
                    }
                    Ok(Ok(None)) => this.end_loaded_export(token, None, false, cx),
                    _ => this.end_loaded_export(token, Some(ExportError::Write), false, cx),
                }
            });
        }));
        cx.notify();
        Ok(())
    }
    fn prepare_loaded_export(
        &mut self,
        token: u64,
        path: PathBuf,
        marker: String,
        window: &mut Window,
        cx: &mut Context<Self>,
    ) {
        if !self.loaded_export_valid(token, cx) {
            self.end_loaded_export(token, None, false, cx);
            return;
        }
        if !self
            .export_request
            .as_ref()
            .is_some_and(|r| r.phase == Phase::Choosing)
        {
            return;
        }
        let request = self.export_request.as_mut().unwrap();
        request.phase = Phase::Encoding;
        request.target = Some(path.clone());
        let capture = request.capture.clone();
        self.export_task = Some(cx.spawn_in(window, async move |this, cx| {
            let chosen = path.clone();
            let encoded = cx
                .background_executor()
                .spawn(async move {
                    let destination =
                        files::CapturedDestination::capture(&chosen).map_err(ExportError::from)?;
                    exports::encode(&capture.loaded, capture.format, &marker)
                        .map(|bytes| (bytes, destination))
                })
                .await;
            _ = this.update_in(cx, |this, window, cx| {
                if !this.loaded_export_valid(token, cx) {
                    this.end_loaded_export(token, None, false, cx);
                    return;
                }
                match encoded {
                    Ok((bytes, destination)) => {
                        this.write_loaded_export(token, path, bytes, destination, window, cx)
                    }
                    Err(error) => this.end_loaded_export(token, Some(error), false, cx),
                }
            });
        }));
    }
    fn write_loaded_export(
        &mut self,
        token: u64,
        path: PathBuf,
        bytes: Arc<str>,
        destination: files::CapturedDestination,
        window: &mut Window,
        cx: &mut Context<Self>,
    ) {
        if !self.loaded_export_valid(token, cx) {
            self.end_loaded_export(token, None, false, cx);
            return;
        }
        if !self
            .export_request
            .as_ref()
            .is_some_and(|r| r.phase == Phase::Encoding)
        {
            return;
        }
        self.export_request.as_mut().unwrap().phase = Phase::Writing;
        self.export_request.as_mut().unwrap().bytes = Some(bytes.clone());
        self.export_task = Some(cx.spawn_in(window, async move |this, cx| {
            let prepared = cx
                .background_executor()
                .spawn(async move { PreparedExport::prepare(bytes, &path, &destination) })
                .await;
            _ = this.update_in(cx, |this, _, cx| {
                this.finish_loaded_export(token, prepared, cx)
            });
        }));
    }
    fn finish_loaded_export(
        &mut self,
        token: u64,
        prepared: Result<PreparedExport, ExportError>,
        cx: &mut Context<Self>,
    ) {
        if !self.loaded_export_valid(token, cx) {
            self.end_loaded_export(token, None, false, cx);
            return;
        }
        let request = self.export_request.as_ref().unwrap();
        if request.phase != Phase::Writing {
            return;
        }
        let result = prepared.and_then(|p| {
            if !request
                .bytes
                .as_ref()
                .zip(request.target.as_ref())
                .is_some_and(|(bytes, path)| p.matches(bytes, path))
            {
                return Err(ExportError::Changed);
            }
            // No async boundary between this original-owner check and rename.
            p.publish()
        });
        let published = result.is_ok();
        self.end_loaded_export(token, result.err(), published, cx);
    }
    fn end_loaded_export(
        &mut self,
        token: u64,
        error: Option<ExportError>,
        published: bool,
        cx: &mut Context<Self>,
    ) {
        let Some(request) = self.export_request.as_ref().filter(|r| r.token == token) else {
            return;
        };
        let document = request.capture.document;
        let rows = request.capture.loaded.rows.len();
        let format = request.capture.format.extension().to_uppercase();
        if let Some(tab) = self.tabs.iter_mut().find(|t| t.id == document) {
            tab.status = error.map_or_else(
                || {
                    if published {
                        format!("Exported {rows} loaded rows as {format}. No SQL was run.").into()
                    } else {
                        "Loaded export cancelled. No SQL was run.".into()
                    }
                },
                |e| e.to_string().into(),
            );
            tab.error = error.is_some();
        }
        self.export_request = None;
        self.export_task = None;
        cx.notify();
    }
}

#[cfg(all(test, feature = "native-smoke"))]
mod tests;
