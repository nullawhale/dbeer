//! Common-command native chooser callbacks retain immutable original ownership.
use super::*;
use files::{CapturedDestination, FileBinding, FileError, OpenedSql, PreparedSave};
use std::{path::PathBuf, sync::Arc};

#[derive(Clone)]
struct FileSource {
    document: DocumentId,
    profile: ProfileId,
    profile_generation: u64,
    settings: Option<ConnectionProfile>,
    title: String,
    source_revision: u64,
    file_revision: u64,
    binding: Option<FileBinding>,
    source: Arc<str>,
}
/// No Debug: this immutable capture contains full editor text and user paths.
#[derive(Clone)]
pub(super) struct FileCapture {
    command: CommandId,
    profile: ProfileId,
    profile_generation: u64,
    settings: Option<ConnectionProfile>,
    source: Option<FileSource>,
}
pub(super) struct FileRequest {
    pub(super) token: u64,
    pub(super) cancelled: bool,
    capture: Arc<FileCapture>,
    target: Option<PathBuf>,
}
impl Workspace {
    pub(super) fn file_activity_target(&self) -> Option<(Option<DocumentId>, ProfileId)> {
        self.file_request.as_ref().map(|r| {
            (
                r.capture.source.as_ref().map(|s| s.document),
                r.capture.profile.clone(),
            )
        })
    }
    pub(super) fn capture_file(
        &self,
        command: CommandId,
        cx: &App,
    ) -> Result<FileCapture, &'static str> {
        let tab = self.tabs.get(self.active);
        let profile_id = if command == CommandId::OpenSql {
            self.profiles
                .get(self.selected_profile)
                .map(|p| p.id.clone())
                .unwrap_or_else(ProfileId::unbound)
        } else {
            tab.ok_or("The captured SQL document is no longer available.")?
                .profile
                .clone()
        };
        let profile = self.profile(&profile_id);
        Ok(FileCapture {
            command,
            profile: profile_id,
            profile_generation: profile.generation,
            settings: profile.config.clone(),
            source: tab
                .filter(|_| command != CommandId::OpenSql)
                .map(|tab| FileSource {
                    document: tab.id,
                    profile: tab.profile.clone(),
                    profile_generation: self.profile(&tab.profile).generation,
                    settings: self.profile(&tab.profile).config.clone(),
                    title: tab.title.clone(),
                    source_revision: tab.generation,
                    file_revision: tab.file.revision,
                    binding: tab.file.binding.clone(),
                    source: Arc::from(tab.editor.read(cx).value().as_ref()),
                }),
        })
    }
    pub(super) fn file_capture_valid(
        &self,
        capture: &FileCapture,
        exact_source: bool,
        cx: &App,
    ) -> bool {
        let profile = self.profile(&capture.profile);
        if profile.generation != capture.profile_generation || profile.config != capture.settings {
            return false;
        }
        capture.source.as_ref().is_none_or(|source| {
            self.tabs
                .iter()
                .find(|tab| tab.id == source.document)
                .is_some_and(|tab| {
                    tab.kind == model::DocumentKind::Sql
                        && tab.profile == source.profile
                        && self.profile(&source.profile).generation == source.profile_generation
                        && self.profile(&source.profile).config == source.settings
                        && tab.title == source.title
                        && tab.file.revision == source.file_revision
                        && tab.file.binding == source.binding
                        && (!exact_source
                            || (tab.generation == source.source_revision
                                && tab.editor.read(cx).value().as_ref() == source.source.as_ref()))
                })
        })
    }
    fn file_request_valid(&self, token: u64, cx: &App) -> bool {
        self.file_request.as_ref().is_some_and(|request| {
            !request.cancelled
                && (!self.closing || self.close_owns_activity(close::Activity::File(token)))
                && request.token == token
                && self.file_capture_valid(&request.capture, false, cx)
        })
    }
    fn end_file_request(
        &mut self,
        token: u64,
        error: Option<FileError>,
        window: &mut Window,
        cx: &mut Context<Self>,
    ) {
        if !self.file_request.as_ref().is_some_and(|r| r.token == token) {
            return;
        }
        self.file_request = None;
        self.file_task = None;
        if let Some(error) = error {
            Self::information(error.to_string(), window, cx);
        }
        cx.notify();
    }
    pub(super) fn start_file_command(
        &mut self,
        capture: Arc<FileCapture>,
        window: &mut Window,
        cx: &mut Context<Self>,
    ) {
        if self.closing
            || (self.file_request.is_some()
                || (self.export_request.is_some() || self.run_file.is_some()))
            || !self.file_capture_valid(&capture, true, cx)
        {
            return;
        }
        self.next_file_request += 1;
        let token = self.next_file_request;
        self.file_request = Some(FileRequest {
            cancelled: false,
            token,
            capture: capture.clone(),
            target: None,
        });
        if capture.command == CommandId::OpenSql {
            let selected = cx.prompt_for_paths(PathPromptOptions {
                files: true,
                directories: false,
                multiple: true,
                prompt: Some("Open SQL".into()),
            });
            self.file_task = Some(cx.spawn_in(window, async move |this, cx| {
                let paths = match selected.await {
                    Ok(Ok(Some(paths))) => paths,
                    Ok(Ok(None)) => {
                        _ = this.update_in(cx, |this, window, cx| {
                            this.end_file_request(token, None, window, cx)
                        });
                        return;
                    }
                    _ => {
                        _ = this.update_in(cx, |this, window, cx| {
                            this.end_file_request(token, Some(FileError::Read), window, cx)
                        });
                        return;
                    }
                };
                let valid = this
                    .update_in(cx, |this, _, cx| this.file_request_valid(token, cx))
                    .unwrap_or(false);
                if !valid {
                    _ = this.update_in(cx, |this, window, cx| {
                        this.end_file_request(token, None, window, cx)
                    });
                    return;
                }
                // Read each whole file before constructing that file's document.
                let opened = cx
                    .background_executor()
                    .spawn(async move {
                        paths
                            .iter()
                            .map(|path| files::open(path))
                            .collect::<Vec<_>>()
                    })
                    .await;
                _ = this.update_in(cx, |this, window, cx| {
                    this.finish_file_open(token, opened, window, cx)
                });
            }));
        } else if capture.command == CommandId::SaveSql
            && capture.source.as_ref().is_some_and(|s| s.binding.is_some())
        {
            let path = capture
                .source
                .as_ref()
                .unwrap()
                .binding
                .as_ref()
                .unwrap()
                .path
                .clone();
            self.prepare_file_save(token, path, None, window, cx);
        } else {
            let source = capture.source.as_ref().unwrap();
            let name = source
                .binding
                .as_ref()
                .map(FileBinding::title)
                .unwrap_or_else(|| format!("{}.sql", source.title));
            let directory = source
                .binding
                .as_ref()
                .and_then(|b| b.path.parent().map(|p| p.to_path_buf()))
                .unwrap_or_else(|| {
                    std::env::current_dir().unwrap_or_else(|_| std::env::temp_dir())
                });
            // GPUI uses the real platform Save dialog, including native overwrite
            // confirmation. The pinned chooser API exposes no file-type filters.
            let selected = cx.prompt_for_new_path(&directory, Some(&name));
            self.file_task = Some(cx.spawn_in(window, async move |this, cx| {
                let result = selected.await;
                _ = this.update_in(cx, |this, window, cx| {
                    if !this.file_request_valid(token, cx) {
                        this.end_file_request(token, None, window, cx);
                        return;
                    }
                    match result {
                        Ok(Ok(Some(path))) => {
                            // Retain the native overwrite decision's exact object
                            // or absence and parent before background scheduling.
                            let binding = this
                                .file_request
                                .as_ref()
                                .unwrap()
                                .capture
                                .source
                                .as_ref()
                                .unwrap()
                                .binding
                                .as_ref()
                                .filter(|binding| binding.matches_destination(&path));
                            let destination = match binding {
                                Some(binding) => {
                                    CapturedDestination::capture_for_binding(&path, binding)
                                }
                                None => CapturedDestination::capture(&path),
                            };
                            match destination {
                                Ok(destination) => this.prepare_file_save(
                                    token,
                                    path,
                                    Some(destination),
                                    window,
                                    cx,
                                ),
                                Err(error) => this.end_file_request(token, Some(error), window, cx),
                            }
                        }
                        Ok(Ok(None)) => this.end_file_request(token, None, window, cx),
                        _ => this.end_file_request(token, Some(FileError::Write), window, cx),
                    }
                });
            }));
        }
        cx.notify();
    }
    pub(super) fn finish_file_open(
        &mut self,
        token: u64,
        opened: Vec<Result<OpenedSql, FileError>>,
        window: &mut Window,
        cx: &mut Context<Self>,
    ) {
        if !self.file_request_valid(token, cx) {
            self.end_file_request(token, None, window, cx);
            return;
        }
        // A close cannot adopt newly opened documents after freezing its scope.
        // The chooser/read future is drained, then its result stays unpublished.
        if self.closing {
            self.end_file_request(token, None, window, cx);
            return;
        }
        let profile = self.file_request.as_ref().unwrap().capture.profile.clone();
        let mut error = None;
        for result in opened {
            match result {
                Ok(opened) => {
                    let title = opened.binding.title();
                    if let Some(id) = self.add_sql_tab_for_profile(
                        title,
                        opened.source.to_string(),
                        profile.clone(),
                        window,
                        cx,
                    ) {
                        let tab = self.tabs.iter_mut().find(|tab| tab.id == id).unwrap();
                        let revision = tab.generation;
                        tab.file
                            .record_saved(opened.binding, opened.source, revision);
                        tab.status =
                            "SQL file opened. Disconnected; no SQL has been executed.".into();
                    }
                }
                Err(e) => error = Some(e),
            }
        }
        self.schedule_documents(cx);
        self.end_file_request(token, error, window, cx);
    }
    fn prepare_file_save(
        &mut self,
        token: u64,
        path: PathBuf,
        destination: Option<CapturedDestination>,
        window: &mut Window,
        cx: &mut Context<Self>,
    ) {
        if !self.file_request_valid(token, cx) {
            self.end_file_request(token, None, window, cx);
            return;
        }
        self.file_request.as_mut().unwrap().target = Some(path.clone());
        let capture = self.file_request.as_ref().unwrap().capture.clone();
        let source = capture.source.as_ref().unwrap().clone();
        self.file_task = Some(cx.spawn_in(window, async move |this, cx| {
            let prepared = cx
                .background_executor()
                .spawn(async move {
                    if let Some(destination) = destination {
                        PreparedSave::prepare_captured(source.source, &path, &destination)
                    } else {
                        let expected = source
                            .binding
                            .as_ref()
                            .filter(|b| b.matches_destination(&path));
                        PreparedSave::prepare(source.source, &path, expected)
                    }
                })
                .await;
            _ = this.update_in(cx, |this, window, cx| {
                this.finish_file_save(token, prepared, window, cx)
            });
        }));
    }
    pub(super) fn finish_file_save(
        &mut self,
        token: u64,
        prepared: Result<PreparedSave, FileError>,
        window: &mut Window,
        cx: &mut Context<Self>,
    ) {
        // A stale result drops only its unpublished temporary. A current-source
        // edit is allowed: publish the captured source and leave newer text dirty.
        if !self.file_request_valid(token, cx) {
            self.end_file_request(token, None, window, cx);
            return;
        }
        let capture = self.file_request.as_ref().unwrap().capture.clone();
        let source = capture.source.as_ref().unwrap();
        let target = self.file_request.as_ref().unwrap().target.as_ref();
        let result = prepared.and_then(|prepared| {
            if !target.is_some_and(|target| prepared.matches_capture(&source.source, target)) {
                return Err(FileError::Changed);
            }
            prepared.publish()
        });
        match result {
            Ok(binding) => {
                let tab = self
                    .tabs
                    .iter_mut()
                    .find(|t| t.id == source.document)
                    .unwrap();
                tab.title = binding.title();
                tab.file
                    .record_saved(binding, source.source.clone(), source.source_revision);
                tab.status = if tab.file.dirty(tab.editor.read(cx).value().as_ref()) {
                    "Captured SQL saved. Newer editor changes remain unsaved."
                } else {
                    "SQL file saved."
                }
                .into();
                self.schedule_documents(cx);
                self.end_file_request(token, None, window, cx);
            }
            Err(error) => {
                #[cfg(windows)]
                if error == FileError::Uncertain
                    && let Some(tab) = self.tabs.iter_mut().find(|t| t.id == source.document)
                {
                    tab.file.publication_uncertain = true;
                    tab.file.revision += 1;
                }
                self.end_file_request(token, Some(error), window, cx);
            }
        }
    }
}

#[cfg(all(test, feature = "native-smoke"))]
mod tests {
    use super::{FileCapture, FileRequest};
    use crate::{
        CloseIntent, CommandId, CommandOrigin, ConnectionProfile, Workspace, apply_theme, close,
        files,
    };
    use files::PreparedSave;
    use gpui_kit::component::ThemeMode;
    use gpui_kit::{
        AnyWindowHandle, AppContext, Entity, TestAppContext, WindowOptions, init, open_window,
    };
    use std::{
        fs,
        path::{Path, PathBuf},
        sync::Arc,
    };
    struct Fixture(PathBuf);
    impl Fixture {
        fn new() -> Self {
            let root = PathBuf::from(env!("CARGO_MANIFEST_DIR"))
                .join("../../build/gpui/file-ui-tests")
                .join(ConnectionProfile::new().id);
            fs::create_dir_all(&root).unwrap();
            Self(fs::canonicalize(root).unwrap())
        }
    }
    impl Drop for Fixture {
        fn drop(&mut self) {
            _ = fs::remove_dir_all(&self.0);
        }
    }
    fn workspace(cx: &mut TestAppContext) -> (AnyWindowHandle, Entity<Workspace>) {
        cx.update(|cx| {
            init(cx);
            apply_theme(ThemeMode::Dark, None, cx);
            let (handle, view) = open_window(WindowOptions::default(), cx, |window, cx| {
                cx.new(|cx| {
                    Workspace::new(
                        None,
                        crate::product_identity::StartupPolicy::new(
                            crate::product_identity::Platform::MacDevelopment,
                            true,
                        ),
                        window,
                        cx,
                    )
                })
            })
            .unwrap();
            handle
                .update(cx, |_, window, cx| {
                    close::install_window_guard(&view, window, cx)
                })
                .unwrap();
            (handle, view)
        })
    }
    fn local_save_workspace(
        cx: &mut TestAppContext,
        original: Option<&Path>,
    ) -> (AnyWindowHandle, Entity<Workspace>) {
        let (window, view) = crate::workspace_tests::workspace_with_policy(
            cx,
            crate::product_identity::StartupPolicy::new(
                crate::product_identity::Platform::Linux,
                true,
            ),
        );
        cx.update_window(window, |_, window, cx| {
            view.update(cx, |this, cx| {
                if let Some(original) = original {
                    let opened = files::open(original).unwrap();
                    this.tabs[0].title = opened.binding.title();
                    this.tabs[0]
                        .file
                        .record_saved(opened.binding, opened.source, 0);
                }
                this.tabs[0].editor.update(cx, |editor, cx| {
                    editor.set_value("captured local text\r\n", window, cx)
                });
            })
        })
        .unwrap();
        cx.run_until_parked();
        (window, view)
    }
    fn begin_local_save(
        cx: &mut TestAppContext,
        window: AnyWindowHandle,
        view: &Entity<Workspace>,
        command: CommandId,
    ) -> FileCapture {
        cx.update_window(window, |_, window, cx| {
            view.update(cx, |this, cx| {
                let capture = this.capture_file(command, cx).unwrap();
                this.command(command, CommandOrigin::Menu, None, window, cx);
                assert!(this.file_request.is_some());
                capture
            })
        })
        .unwrap()
    }
    fn choose_and_pause_before_preparation(
        cx: &mut TestAppContext,
        view: &Entity<Workspace>,
        path: &Path,
    ) {
        assert!(cx.did_prompt_for_new_path());
        cx.simulate_new_path_selection(|_| Some(path.to_path_buf()));
        // One tick runs at most one task. Stop as soon as the actual native
        // continuation captures its target; the save task has not been polled,
        // so its background preparation cannot run before the test mutation.
        for _ in 0..1_000 {
            if cx.update(|cx| {
                view.read(cx)
                    .file_request
                    .as_ref()
                    .is_some_and(|request| request.target.as_deref() == Some(path))
            }) {
                return;
            }
            assert!(cx.dispatcher.tick(false), "native chooser did not continue");
        }
        panic!("native chooser did not retain its target");
    }
    fn assert_local_save_refused(
        cx: &mut TestAppContext,
        view: &Entity<Workspace>,
        capture: &FileCapture,
    ) {
        cx.update(|cx| {
            let this = view.read(cx);
            assert!(this.file_request.is_none() && this.file_task.is_none());
            assert!(this.file_capture_valid(capture, true, cx));
            assert!(this.profiles.is_empty() && this.backend.is_none());
            assert!(this.tabs.iter().all(|tab| {
                tab.session.is_none()
                    && tab.operation.is_none()
                    && tab.executions.is_empty()
                    && tab.result_sets.is_empty()
                    && !tab.file.publication_uncertain
            }));
        });
    }
    fn assert_no_file_temporaries(directory: &Path) {
        assert!(fs::read_dir(directory).unwrap().all(|entry| {
            !entry
                .unwrap()
                .file_name()
                .to_string_lossy()
                .starts_with(".dbeer-sql-")
        }));
    }
    #[gpui_kit::test]
    fn native_first_save_and_save_as_refuse_appeared_destination_before_background_preparation(
        cx: &mut TestAppContext,
    ) {
        for command in [CommandId::SaveSql, CommandId::SaveSqlAs] {
            let fixture = Fixture::new();
            let original = fixture.0.join("bound.sql");
            let target = fixture.0.join("chosen.sql");
            fs::write(&original, "original bound bytes\r\n").unwrap();
            let bound = (command == CommandId::SaveSqlAs).then_some(original.as_path());
            let (window, view) = local_save_workspace(cx, bound);
            let capture = begin_local_save(cx, window, &view, command);
            choose_and_pause_before_preparation(cx, &view, &target);
            assert!(!target.exists());
            assert_no_file_temporaries(&fixture.0);
            fs::write(&target, "foreign appeared bytes\r\n").unwrap();
            let foreign = files::open(&target).unwrap().binding;
            cx.run_until_parked();
            assert_local_save_refused(cx, &view, &capture);
            assert!(files::open(&target).unwrap().binding == foreign);
            assert_eq!(fs::read(&target).unwrap(), b"foreign appeared bytes\r\n");
            assert_eq!(fs::read(&original).unwrap(), b"original bound bytes\r\n");
            assert_no_file_temporaries(&fixture.0);
        }
    }
    #[gpui_kit::test]
    fn native_first_save_and_save_as_refuse_edited_or_replaced_destination_before_background(
        cx: &mut TestAppContext,
    ) {
        for command in [CommandId::SaveSql, CommandId::SaveSqlAs] {
            for replace in [false, true] {
                let fixture = Fixture::new();
                let original = fixture.0.join("bound.sql");
                let target = fixture.0.join("chosen.sql");
                let detached = fixture.0.join("retained-chosen.sql");
                fs::write(&original, "original bound bytes\r\n").unwrap();
                fs::write(&target, "chooser accepted bytes\r\n").unwrap();
                let chosen = files::open(&target).unwrap().binding;
                let bound = (command == CommandId::SaveSqlAs).then_some(original.as_path());
                let (window, view) = local_save_workspace(cx, bound);
                let capture = begin_local_save(cx, window, &view, command);
                choose_and_pause_before_preparation(cx, &view, &target);
                assert_no_file_temporaries(&fixture.0);
                if replace {
                    fs::rename(&target, &detached).unwrap();
                }
                fs::write(&target, "foreign changed bytes\r\n").unwrap();
                let foreign = files::open(&target).unwrap().binding;
                assert!(foreign != chosen);
                cx.run_until_parked();
                assert_local_save_refused(cx, &view, &capture);
                assert!(files::open(&target).unwrap().binding == foreign);
                assert_eq!(fs::read(&target).unwrap(), b"foreign changed bytes\r\n");
                assert_eq!(fs::read(&original).unwrap(), b"original bound bytes\r\n");
                if replace {
                    assert_eq!(fs::read(&detached).unwrap(), b"chooser accepted bytes\r\n");
                }
                assert_no_file_temporaries(&fixture.0);
            }
        }
    }
    #[cfg(unix)]
    #[gpui_kit::test]
    fn native_chooser_refuses_replaced_parent_before_background_preparation(
        cx: &mut TestAppContext,
    ) {
        // First Save captures absence; Save As covers both a different existing
        // destination and the original binding while retaining its older bytes.
        for route in 0..3 {
            let fixture = Fixture::new();
            let parent = fixture.0.join("chosen-parent");
            let retained = fixture.0.join("retained-parent");
            fs::create_dir(&parent).unwrap();
            let target = parent.join("chosen.sql");
            let original = if route == 2 {
                target.clone()
            } else {
                fixture.0.join("bound.sql")
            };
            fs::write(&original, "original bound bytes\r\n").unwrap();
            if route == 1 {
                fs::write(&target, "chooser accepted bytes\r\n").unwrap();
            }
            let command = if route == 0 {
                CommandId::SaveSql
            } else {
                CommandId::SaveSqlAs
            };
            let (window, view) =
                local_save_workspace(cx, (route != 0).then_some(original.as_path()));
            let capture = begin_local_save(cx, window, &view, command);
            choose_and_pause_before_preparation(cx, &view, &target);
            fs::rename(&parent, &retained).unwrap();
            fs::create_dir(&parent).unwrap();
            fs::write(&target, "foreign parent bytes\r\n").unwrap();
            let foreign = files::open(&target).unwrap().binding;
            cx.run_until_parked();
            assert_local_save_refused(cx, &view, &capture);
            assert!(files::open(&target).unwrap().binding == foreign);
            assert_eq!(fs::read(&target).unwrap(), b"foreign parent bytes\r\n");
            if route == 0 {
                assert!(!retained.join("chosen.sql").exists());
            } else {
                assert_eq!(
                    fs::read(retained.join("chosen.sql")).unwrap(),
                    if route == 1 {
                        b"chooser accepted bytes\r\n".as_slice()
                    } else {
                        b"original bound bytes\r\n".as_slice()
                    }
                );
            }
            assert_no_file_temporaries(&parent);
            assert_no_file_temporaries(&retained);
            assert_no_file_temporaries(&fixture.0);
        }
    }
    #[gpui_kit::test]
    fn native_unchanged_first_save_and_save_as_publish_only_the_captured_source(
        cx: &mut TestAppContext,
    ) {
        for route in 0..4 {
            let fixture = Fixture::new();
            let original = fixture.0.join("bound.sql");
            fs::write(&original, "original bound bytes\r\n").unwrap();
            let target = if route == 3 {
                original.clone()
            } else {
                fixture.0.join("chosen.sql")
            };
            if route == 2 {
                fs::write(&target, "chooser accepted bytes\r\n").unwrap();
            }
            let command = if route == 0 {
                CommandId::SaveSql
            } else {
                CommandId::SaveSqlAs
            };
            let (window, view) =
                local_save_workspace(cx, (route != 0).then_some(original.as_path()));
            let capture = begin_local_save(cx, window, &view, command);
            choose_and_pause_before_preparation(cx, &view, &target);
            assert_no_file_temporaries(&fixture.0);
            cx.run_until_parked();
            assert_eq!(fs::read(&target).unwrap(), b"captured local text\r\n");
            cx.update(|cx| {
                let this = view.read(cx);
                let source = capture.source.as_ref().unwrap();
                let tab = this
                    .tabs
                    .iter()
                    .find(|tab| tab.id == source.document)
                    .unwrap();
                assert!(tab.file.binding.as_ref().unwrap().path == target);
                assert_eq!(tab.file.revision, source.file_revision + 1);
                assert_eq!(tab.file.saved_source_revision, Some(source.source_revision));
                assert!(tab.file.saved_source.as_deref() == Some(source.source.as_ref()));
                assert!(!tab.file.dirty(tab.editor.read(cx).value().as_ref()));
                assert!(this.file_request.is_none() && this.backend.is_none());
                assert!(this.profiles.is_empty() && tab.session.is_none());
                assert!(tab.operation.is_none() && tab.executions.is_empty());
            });
            if route != 3 {
                assert_eq!(fs::read(&original).unwrap(), b"original bound bytes\r\n");
            }
            assert_no_file_temporaries(&fixture.0);
        }
    }
    #[gpui_kit::test]
    fn native_bound_save_and_same_binding_save_as_refuse_external_changes(cx: &mut TestAppContext) {
        for command in [CommandId::SaveSql, CommandId::SaveSqlAs] {
            let fixture = Fixture::new();
            let original = fixture.0.join("bound.sql");
            fs::write(&original, "original bound bytes\r\n").unwrap();
            let (window, view) = local_save_workspace(cx, Some(&original));
            let capture = begin_local_save(cx, window, &view, command);
            if command == CommandId::SaveSqlAs {
                choose_and_pause_before_preparation(cx, &view, &original);
            } else {
                assert!(!cx.did_prompt_for_new_path());
            }
            fs::write(&original, "foreign bound edit\r\n").unwrap();
            let foreign = files::open(&original).unwrap().binding;
            cx.run_until_parked();
            assert_local_save_refused(cx, &view, &capture);
            assert!(files::open(&original).unwrap().binding == foreign);
            assert_eq!(fs::read(&original).unwrap(), b"foreign bound edit\r\n");
            assert_no_file_temporaries(&fixture.0);
        }
    }
    #[gpui_kit::test]
    fn native_same_binding_save_as_refuses_edit_before_chooser_completion(cx: &mut TestAppContext) {
        let fixture = Fixture::new();
        let original = fixture.0.join("bound.sql");
        fs::write(&original, "original bound bytes\r\n").unwrap();
        let (window, view) = local_save_workspace(cx, Some(&original));
        let capture = begin_local_save(cx, window, &view, CommandId::SaveSqlAs);
        fs::write(&original, "foreign pre-chooser edit\r\n").unwrap();
        let foreign = files::open(&original).unwrap().binding;
        assert!(cx.did_prompt_for_new_path());
        cx.simulate_new_path_selection(|_| Some(original.clone()));
        cx.run_until_parked();
        assert_local_save_refused(cx, &view, &capture);
        assert!(files::open(&original).unwrap().binding == foreign);
        assert_eq!(
            fs::read(&original).unwrap(),
            b"foreign pre-chooser edit\r\n"
        );
        assert_no_file_temporaries(&fixture.0);
    }
    #[gpui_kit::test]
    fn common_menu_save_uses_original_document_and_source_across_picker_focus_and_edits(
        cx: &mut TestAppContext,
    ) {
        let fixture = Fixture::new();
        let path = fixture.0.join("caf\u{e9} \u{1f642}.sql");
        let (window, view) = workspace(cx);
        let (first, original) = cx
            .update_window(window, |_, window, cx| {
                view.update(cx, |this, cx| {
                    let first = this.tabs[0].id;
                    let original = this.tabs[0].editor.read(cx).value().to_string();
                    let capture = this
                        .capture_command(
                            CommandId::SaveSqlAs,
                            CommandOrigin::Menu,
                            None,
                            window,
                            cx,
                        )
                        .unwrap();
                    this.add_sql_tab("Other.sql".into(), "SELECT 'other';".into(), window, cx);
                    this.dispatch_command(capture, window, cx);
                    let editor = this.tabs[0].editor.clone();
                    editor.update(cx, |state, cx| {
                        state.set_value("SELECT 'newer';", window, cx)
                    });
                    (first, original)
                })
            })
            .unwrap();
        assert!(cx.did_prompt_for_new_path());
        cx.simulate_new_path_selection(|_| Some(path.clone()));
        cx.run_until_parked();
        assert_eq!(fs::read_to_string(&path).unwrap(), original);
        cx.update(|cx| {
            let this = view.read(cx);
            let first = this.tabs.iter().find(|tab| tab.id == first).unwrap();
            assert_eq!(first.title, "caf\u{e9} \u{1f642}.sql");
            assert!(first.file.dirty(first.editor.read(cx).value().as_ref()));
            assert_eq!(first.file.saved_source.as_deref(), Some(original.as_str()));
            assert!(this.tabs[1].file.binding.is_none());
            assert_eq!(
                this.tabs[1].editor.read(cx).value().as_ref(),
                "SELECT 'other';"
            );
            assert!((this.file_request.is_none() && this.export_request.is_none()));
            assert!(this.backend.is_none());
        });
    }
    #[gpui_kit::test]
    fn native_save_cancel_keeps_binding_title_bytes_and_close_request_waits_for_file_operation(
        cx: &mut TestAppContext,
    ) {
        let fixture = Fixture::new();
        let path = fixture.0.join("original.sql");
        fs::write(&path, "original\r\n").unwrap();
        let (window, view) = workspace(cx);
        cx.update_window(window, |_, window, cx| {
            view.update(cx, |this, cx| {
                let opened = files::open(&path).unwrap();
                this.tabs[0].title = opened.binding.title();
                this.tabs[0]
                    .file
                    .record_saved(opened.binding, opened.source, 0);
                this.command(
                    CommandId::SaveSqlAs,
                    CommandOrigin::Shortcut,
                    None,
                    window,
                    cx,
                );
                let token = this.file_request.as_ref().unwrap().token;
                this.command(
                    CommandId::SaveSqlAs,
                    CommandOrigin::Button,
                    None,
                    window,
                    cx,
                );
                assert_eq!(this.file_request.as_ref().unwrap().token, token);
                this.request_close(CloseIntent::Tab(this.tabs[0].id), window, cx);
                assert!(this.closing && this.close_flow.is_some());
                let close = this.close_flow.as_ref().unwrap().token;
                this.cancel_close(&close, window, cx);
                assert_eq!(this.file_request.as_ref().unwrap().token, token);
                assert_eq!(this.tabs.len(), 1);
            })
        })
        .unwrap();
        cx.simulate_new_path_selection(|_| None);
        cx.run_until_parked();
        cx.update(|cx| {
            let this = view.read(cx);
            assert_eq!(this.tabs[0].title, "original.sql");
            assert_eq!(this.tabs[0].file.revision, 1);
            assert!(this.tabs[0].file.binding.as_ref().unwrap().path == path);
            assert!((this.file_request.is_none() && this.export_request.is_none()));
        });
        assert_eq!(fs::read_to_string(path).unwrap(), "original\r\n");
    }
    #[gpui_kit::test]
    fn native_multi_open_refuses_invalid_utf8_without_partial_document_and_uses_original_profile(
        cx: &mut TestAppContext,
    ) {
        let fixture = Fixture::new();
        let valid = fixture.0.join("Unicode \u{1f642}.sql");
        let invalid = fixture.0.join("invalid.sql");
        let sql = "SELECT '\u{1f642}';\r\n";
        fs::write(&valid, format!("\u{feff}{sql}")).unwrap();
        fs::write(&invalid, [0xff, 0xfe]).unwrap();
        let (window, view) = workspace(cx);
        let profile = cx
            .update_window(window, |_, window, cx| {
                view.update(cx, |this, cx| {
                    let profile = this.profiles[this.selected_profile].id.clone();
                    this.command(
                        CommandId::OpenSql,
                        CommandOrigin::Shortcut,
                        None,
                        window,
                        cx,
                    );
                    this.selected_profile = 1;
                    profile
                })
            })
            .unwrap();
        assert!(cx.did_prompt_for_paths());
        cx.simulate_path_prompt_response(|options| {
            assert!(options.files && options.multiple && !options.directories);
            Some(vec![valid.clone(), invalid])
        });
        cx.run_until_parked();
        cx.update(|cx| {
            let this = view.read(cx);
            assert_eq!(this.tabs.len(), 2);
            let opened = &this.tabs[1];
            assert!(opened.profile == profile);
            assert_eq!(opened.editor.read(cx).value().as_ref(), sql);
            assert_eq!(opened.title, "Unicode \u{1f642}.sql");
            assert!(!opened.file.dirty(sql));
            assert!(opened.session.is_none());
            assert!(opened.operation.is_none());
            assert!(opened.executions.is_empty());
            assert!(this.backend.is_none());
        });
    }
    #[gpui_kit::test]
    fn native_callback_after_document_removal_or_profile_change_cannot_write_or_reopen(
        cx: &mut TestAppContext,
    ) {
        let fixture = Fixture::new();
        let path = fixture.0.join("never-created.sql");
        let (window, view) = workspace(cx);
        cx.update_window(window, |_, window, cx| {
            view.update(cx, |this, cx| {
                this.command(
                    CommandId::SaveSqlAs,
                    CommandOrigin::Button,
                    None,
                    window,
                    cx,
                );
                this.close_tab(0, window, cx); // Simulate an independently removed origin.
            })
        })
        .unwrap();
        cx.simulate_new_path_selection(|_| Some(path.clone()));
        cx.run_until_parked();
        assert!(!path.exists());
        cx.update_window(window, |_, window, cx| {
            view.update(cx, |this, cx| {
                assert_eq!(this.tabs.len(), 1);
                assert!(this.tabs[0].file.binding.is_none());
                this.command(
                    CommandId::SaveSqlAs,
                    CommandOrigin::Button,
                    None,
                    window,
                    cx,
                );
                this.profiles[this.selected_profile].generation += 1;
            })
        })
        .unwrap();
        cx.simulate_new_path_selection(|_| Some(path.clone()));
        cx.run_until_parked();
        assert!(!path.exists());
        assert!(cx.update(|cx| view.read(cx).file_request.is_none()));
    }
    #[gpui_kit::test]
    fn stale_prepared_completion_cleans_temp_without_retargeting_or_overwriting_newer_request(
        cx: &mut TestAppContext,
    ) {
        let fixture = Fixture::new();
        let path = fixture.0.join("original.sql");
        fs::write(&path, "original").unwrap();
        let (window, view) = workspace(cx);
        cx.update_window(window, |_, window, cx| {
            view.update(cx, |this, cx| {
                let capture = Arc::new(this.capture_file(CommandId::SaveSqlAs, cx).unwrap());
                this.next_file_request += 1;
                let old = this.next_file_request;
                this.file_request = Some(FileRequest {
                    cancelled: false,
                    token: old,
                    capture: capture.clone(),
                    target: Some(path.clone()),
                });
                let prepared = PreparedSave::prepare(Arc::from("captured"), &path, None).unwrap();
                this.next_file_request += 1;
                let new = this.next_file_request;
                this.file_request = Some(FileRequest {
                    cancelled: false,
                    token: new,
                    capture,
                    target: Some(path.clone()),
                });
                this.finish_file_save(old, Ok(prepared), window, cx);
                assert_eq!(this.file_request.as_ref().unwrap().token, new);
                assert!(this.tabs[0].file.binding.is_none());
                assert_eq!(fs::read_to_string(&path).unwrap(), "original");
                this.closing = true;
                this.finish_file_save(
                    new,
                    PreparedSave::prepare(Arc::from("must not publish"), &path, None),
                    window,
                    cx,
                );
                assert_eq!(fs::read_to_string(&path).unwrap(), "original");
                assert!((this.file_request.is_none() && this.export_request.is_none()));
            })
        })
        .unwrap();
        assert_eq!(fs::read_dir(&fixture.0).unwrap().count(), 1);
    }
    #[gpui_kit::test]
    fn prepared_save_keeps_original_binding_on_error_and_source_changes_keep_captured_revision(
        cx: &mut TestAppContext,
    ) {
        let fixture = Fixture::new();
        let original = fixture.0.join("original.sql");
        let other = fixture.0.join("other.sql");
        fs::write(&original, "original").unwrap();
        fs::write(&other, "external").unwrap();
        let (window, view) = workspace(cx);
        cx.update_window(window, |_, window, cx| {
            view.update(cx, |this, cx| {
                let opened = files::open(&original).unwrap();
                this.tabs[0].title = opened.binding.title();
                this.tabs[0]
                    .file
                    .record_saved(opened.binding, opened.source, 0);
                let capture = Arc::new(this.capture_file(CommandId::SaveSqlAs, cx).unwrap());
                this.next_file_request += 1;
                let token = this.next_file_request;
                let source = capture.source.as_ref().unwrap().source.clone();
                this.file_request = Some(FileRequest {
                    cancelled: false,
                    token,
                    capture,
                    target: Some(other.clone()),
                });
                let prepared = PreparedSave::prepare(source, &other, None).unwrap();
                fs::write(&other, "external newer").unwrap();
                this.finish_file_save(token, Ok(prepared), window, cx);
                assert_eq!(this.tabs[0].title, "original.sql");
                assert!(this.tabs[0].file.binding.as_ref().unwrap().path == original);
                assert_eq!(this.tabs[0].file.revision, 1);
                assert_eq!(fs::read_to_string(&other).unwrap(), "external newer");
            })
        })
        .unwrap();
        assert_eq!(fs::read_to_string(original).unwrap(), "original");
    }
    #[gpui_kit::test]
    fn bound_save_uses_captured_source_without_another_picker_and_keeps_exact_utf8(
        cx: &mut TestAppContext,
    ) {
        let fixture = Fixture::new();
        let path = fixture.0.join("bound \u{1f642}.sql");
        fs::write(&path, "original\r\n").unwrap();
        let (window, view) = workspace(cx);
        cx.update_window(window, |_, window, cx| {
            view.update(cx, |this, cx| {
                let opened = files::open(&path).unwrap();
                this.tabs[0].title = opened.binding.title();
                this.tabs[0]
                    .file
                    .record_saved(opened.binding, opened.source, 0);
                this.tabs[0].editor.update(cx, |state, cx| {
                    state.set_value("SELECT 'caf\u{e9}\u{1f642}';\r\n", window, cx)
                });
            })
        })
        .unwrap();
        cx.run_until_parked();
        cx.update_window(window, |_, window, cx| {
            view.update(cx, |this, cx| {
                this.command(
                    CommandId::SaveSql,
                    CommandOrigin::Shortcut,
                    None,
                    window,
                    cx,
                )
            })
        })
        .unwrap();
        assert!(!cx.did_prompt_for_new_path());
        cx.run_until_parked();
        assert_eq!(
            fs::read_to_string(&path).unwrap(),
            "SELECT 'caf\u{e9}\u{1f642}';\r\n"
        );
        cx.update(|cx| {
            let this = view.read(cx);
            assert!((this.file_request.is_none() && this.export_request.is_none()));
            assert!(
                !this.tabs[0]
                    .file
                    .dirty(this.tabs[0].editor.read(cx).value().as_ref())
            );
            assert_eq!(this.tabs[0].file.revision, 2);
        });
    }
    #[gpui_kit::test]
    fn fresh_product_local_files_preserve_large_source_without_connection_authority(
        cx: &mut TestAppContext,
    ) {
        let fixture = Fixture::new();
        let path = fixture.0.join("large.sql");
        let saved_as = fixture.0.join("saved-as.sql");
        let source = format!("-- {}\r\nSELECT 1;", "x".repeat(8 * 1024 * 1024 + 1));
        fs::write(&path, &source).unwrap();
        let (window, view) = crate::workspace_tests::workspace_with_policy(
            cx,
            crate::product_identity::StartupPolicy::new(
                crate::product_identity::Platform::Linux,
                true,
            ),
        );
        cx.update_window(window, |_, window, cx| {
            view.update(cx, |this, cx| {
                assert!(this.profiles.is_empty());
                this.command(CommandId::OpenSql, CommandOrigin::Menu, None, window, cx);
            })
        })
        .unwrap();
        assert!(cx.did_prompt_for_paths());
        cx.simulate_path_prompt_response(|_| Some(vec![path.clone()]));
        cx.run_until_parked();
        cx.update_window(window, |_, window, cx| {
            view.update(cx, |this, cx| {
                assert_eq!(
                    this.tabs[this.active].editor.read(cx).value().as_ref(),
                    source
                );
                assert_eq!(
                    this.tabs[this.active].profile,
                    crate::model::ProfileId::unbound()
                );
                assert!(this.tabs.iter().all(|tab| tab.session.is_none()));
                this.command(CommandId::SaveSql, CommandOrigin::Menu, None, window, cx);
            })
        })
        .unwrap();
        assert!(!cx.did_prompt_for_new_path());
        cx.run_until_parked();
        cx.update_window(window, |_, window, cx| {
            view.update(cx, |this, cx| {
                this.command(CommandId::SaveSqlAs, CommandOrigin::Menu, None, window, cx);
            })
        })
        .unwrap();
        assert!(cx.did_prompt_for_new_path());
        cx.simulate_new_path_selection(|_| Some(saved_as.clone()));
        cx.run_until_parked();
        assert_eq!(fs::read(&saved_as).unwrap(), source.as_bytes());
        cx.update(|cx| {
            let this = view.read(cx);
            assert!(this.backend.is_none());
            let owner = crate::instance::DataDirectory::acquire(&fixture.0.join("workspace-owner"))
                .unwrap();
            let store = crate::restoration::WorkspaceStore::new(owner.clone());
            store.load().unwrap();
            store.reserve(this.document_snapshot(cx)).commit().unwrap();
            let restored = crate::restoration::WorkspaceStore::new(owner)
                .load()
                .unwrap();
            assert_eq!(restored.documents.last().unwrap().text, source);
            assert_eq!(restored.documents.last().unwrap().profile_id, None);
        });
    }
    #[gpui_kit::test]
    fn unbound_and_missing_profile_save_prompt_and_open_from_non_sql_documents(
        cx: &mut TestAppContext,
    ) {
        let fixture = Fixture::new();
        let path = fixture.0.join("manual-recovery.sql");
        let opened = fixture.0.join("opened.sql");
        fs::write(&opened, "SELECT 'local';\r\n").unwrap();
        let (window, view) = crate::workspace_tests::workspace_with_policy(
            cx,
            crate::product_identity::StartupPolicy::new(
                crate::product_identity::Platform::Linux,
                true,
            ),
        );
        for missing in [false, true] {
            cx.update_window(window, |_, window, cx| {
                view.update(cx, |this, cx| {
                    if missing {
                        this.tabs[this.active].profile =
                            crate::model::ProfileId("missing-synthetic-profile".into());
                        this.tabs[this.active].file = Default::default();
                    }
                    this.command(CommandId::SaveSql, CommandOrigin::Menu, None, window, cx);
                })
            })
            .unwrap();
            assert!(cx.did_prompt_for_new_path());
            cx.simulate_new_path_selection(|_| Some(path.clone()));
            cx.run_until_parked();
            assert!(path.is_file());
        }
        cx.update_window(window, |_, window, cx| {
            view.update(cx, |this, cx| {
                this.tabs[this.active].kind = crate::model::DocumentKind::Inspection {
                    schema: "synthetic".into(),
                    object: "object".into(),
                    object_kind: "view".into(),
                    identity: None,
                };
                this.command(CommandId::OpenSql, CommandOrigin::Menu, None, window, cx);
            })
        })
        .unwrap();
        assert!(cx.did_prompt_for_paths());
        cx.simulate_path_prompt_response(|_| Some(vec![opened.clone()]));
        cx.run_until_parked();
        cx.update(|cx| {
            let this = view.read(cx);
            assert_eq!(
                this.tabs[this.active].editor.read(cx).value(),
                "SELECT 'local';\r\n"
            );
            assert!(this.backend.is_none() && this.tabs.iter().all(|tab| tab.session.is_none()));
        });
    }
}
