//! Explicit, disposable Task 2 probes. Ordinary startup never enters this module.
use super::*;
use serde::Deserialize;
use std::{
    fs::{self, File, OpenOptions},
    io::{Read, Write},
    path::{Path, PathBuf},
    time::Instant,
};

const PREFIX: &str = "dbeer-feasibility-";
const SQL_FIXTURE: &str =
    "SELECT 'probe \u{1f600} e\u{301}' AS synthetic;\r\n-- No database connection\n";
const MAX_REQUEST: u64 = 4096;

#[derive(Clone, Deserialize)]
#[serde(deny_unknown_fields)]
struct Request {
    version: u32,
    root: PathBuf,
    token: String,
    account: String,
}

fn private_path(path: &Path, directory: bool) -> Result<(), ()> {
    let metadata = fs::symlink_metadata(path).map_err(|_| ())?;
    if metadata.file_type().is_symlink()
        || (if directory {
            !metadata.is_dir()
        } else {
            !metadata.is_file()
        })
    {
        return Err(());
    }
    #[cfg(unix)]
    {
        use std::os::unix::fs::MetadataExt;
        unsafe extern "C" {
            fn geteuid() -> u32;
        }
        if metadata.uid() != unsafe { geteuid() } || metadata.mode() & 0o077 != 0 {
            return Err(());
        }
    }
    #[cfg(windows)]
    {
        use std::os::windows::fs::MetadataExt;
        if metadata.file_attributes() & 0x400 != 0 {
            return Err(());
        }
    }
    Ok(())
}

impl Request {
    fn load(path: &Path) -> Result<Self, ()> {
        private_path(path, false)?;
        if !path.is_absolute()
            || path.file_name().and_then(|s| s.to_str()) != Some("probe-request.json")
            || fs::symlink_metadata(path)
                .map_err(|_| ())?
                .file_type()
                .is_symlink()
            || fs::metadata(path).map_err(|_| ())?.len() > MAX_REQUEST
        {
            return Err(());
        }
        let mut bytes = Vec::new();
        File::open(path)
            .map_err(|_| ())?
            .take(MAX_REQUEST + 1)
            .read_to_end(&mut bytes)
            .map_err(|_| ())?;
        if bytes.len() as u64 > MAX_REQUEST {
            return Err(());
        }
        let request: Self = serde_json::from_slice(&bytes).map_err(|_| ())?;
        request.validate()?;
        if path.parent().and_then(|p| p.canonicalize().ok())
            != Some(request.root.canonicalize().map_err(|_| ())?)
        {
            return Err(());
        }
        #[cfg(windows)]
        {
            // The Python launcher creates/verifies an owner-only ACL, then binds
            // this child to that root/token. Refuse standalone unbound requests.
            let expected = std::env::var_os("DBEER_FEASIBILITY_ROOT").ok_or(())?;
            if Path::new(&expected).canonicalize().map_err(|_| ())?
                != request.root.canonicalize().map_err(|_| ())?
                || std::env::var("DBEER_FEASIBILITY_TOKEN").map_err(|_| ())? != request.token
            {
                return Err(());
            }
        }
        Ok(request)
    }

    fn validate(&self) -> Result<(), ()> {
        if self.version != 1
            || self.token.len() != 32
            || !self
                .token
                .bytes()
                .all(|c| c.is_ascii_hexdigit() && !c.is_ascii_uppercase())
            || self.account != format!("{PREFIX}{}", self.token)
            || !self.root.is_absolute()
            || self.root.parent().is_none()
        {
            return Err(());
        }
        private_path(&self.root, true)?;
        private_path(&self.root.join("fixtures"), true)?;
        // Reject symlink/reparse ancestors rather than comparing Windows verbatim
        // canonical path syntax with Python's unprefixed request representation.
        for ancestor in self.root.ancestors() {
            let metadata = fs::symlink_metadata(ancestor).map_err(|_| ())?;
            if metadata.file_type().is_symlink() {
                return Err(());
            }
            #[cfg(windows)]
            {
                use std::os::windows::fs::MetadataExt;
                if metadata.file_attributes() & 0x400 != 0 {
                    return Err(());
                }
            }
        }
        Ok(())
    }

    fn create(&self, name: &str) -> Result<File, ()> {
        let mut options = OpenOptions::new();
        options.write(true).create_new(true);
        #[cfg(unix)]
        {
            use std::os::unix::fs::OpenOptionsExt;
            options.mode(0o600);
        }
        options.open(self.root.join(name)).map_err(|_| ())
    }
}

fn selected_fixture(request: &Request, selected: &Path, save: bool) -> bool {
    // Inspect path identity only. Never open a selected file or write a destination.
    let expected_name = if save {
        "feasibility-save.sql"
    } else {
        "feasibility.sql"
    };
    let Ok(directory) = request.root.join("fixtures").canonicalize() else {
        return false;
    };
    selected.file_name().and_then(|name| name.to_str()) == Some(expected_name)
        && selected
            .parent()
            .and_then(|parent| parent.canonicalize().ok())
            .as_ref()
            == Some(&directory)
        && (save || selected.is_file())
        && !fs::symlink_metadata(selected).is_ok_and(|m| m.file_type().is_symlink())
}

#[cfg(any(test, target_os = "windows", target_os = "linux"))]
trait CredentialStore {
    fn read(&self, id: &str) -> Result<Option<String>, ()>;
    fn save(&self, id: &str, value: &str) -> Result<(), ()>;
}

#[cfg(any(test, target_os = "windows", target_os = "linux"))]
#[derive(Default, serde::Serialize, Deserialize)]
#[serde(deny_unknown_fields)]
struct CredentialResult {
    completed: bool,
    created: bool,
    read_back: bool,
    replaced: bool,
    cleanup_attempted: bool,
    cleanup_verified: bool,
    collision: bool,
    failed: bool,
}

#[cfg(any(test, target_os = "windows", target_os = "linux"))]
fn credential_roundtrip(
    store: &impl CredentialStore,
    account: &str,
    claim: impl FnOnce() -> Result<(), ()>,
) -> CredentialResult {
    let mut result = CredentialResult::default();
    if !valid_account(account) {
        result.failed = true;
        result.completed = true;
        return result;
    }
    match store.read(account) {
        Ok(None) => {}
        Ok(Some(_)) => {
            result.collision = true;
            result.completed = true;
            return result;
        }
        Err(()) => {
            result.failed = true;
            result.completed = true;
            return result;
        }
    }
    if claim().is_err() {
        result.failed = true;
        result.completed = true;
        return result;
    }
    let initial = format!("synthetic-initial:{account}");
    let replacement = format!("synthetic-replacement:{account}");
    // Cleanup also runs after a failed write: a native store can fail after mutation.
    let operation = (|| {
        store.save(account, &initial)?;
        result.created = true;
        result.read_back = store.read(account)?.as_deref() == Some(initial.as_str());
        if !result.read_back {
            return Err(());
        }
        store.save(account, &replacement)?;
        result.replaced = store.read(account)?.as_deref() == Some(replacement.as_str());
        if !result.replaced {
            return Err(());
        }
        Ok(())
    })();
    result.cleanup_attempted = true;
    result.cleanup_verified = cleanup_credential(store, account);
    result.failed = operation.is_err() || !result.cleanup_verified;
    result.completed = true;
    result
}

#[cfg(any(test, target_os = "windows", target_os = "linux"))]
pub(super) fn valid_account(account: &str) -> bool {
    account.strip_prefix(PREFIX).is_some_and(|token| {
        token.len() == 32
            && token
                .bytes()
                .all(|c| c.is_ascii_hexdigit() && !c.is_ascii_uppercase())
    })
}

#[cfg(any(test, target_os = "windows", target_os = "linux"))]
fn cleanup_credential(store: &impl CredentialStore, account: &str) -> bool {
    if !valid_account(account) {
        return false;
    }
    match store.read(account) {
        Ok(None) => true,
        Ok(Some(value))
            if value == format!("synthetic-initial:{account}")
                || value == format!("synthetic-replacement:{account}") =>
        {
            store.save(account, "").is_ok()
                && store.read(account).is_ok_and(|value| value.is_none())
        }
        _ => false, // Preserve collisions, including an existing empty credential.
    }
}

#[cfg(any(target_os = "windows", target_os = "linux"))]
#[derive(Deserialize)]
#[serde(deny_unknown_fields)]
struct Ownership {
    version: u32,
    token: String,
    account: String,
    pid: u32,
}

#[cfg(any(target_os = "windows", target_os = "linux"))]
fn claim_credential(request: &Request) -> Result<(), ()> {
    let mut file = request.create("credential-owned.pending")?;
    serde_json::to_writer(
        &mut file,
        &serde_json::json!({"version": 1, "token": request.token,
        "account": request.account, "pid": std::process::id()}),
    )
    .map_err(|_| ())?;
    file.sync_all().map_err(|_| ())?;
    drop(file);
    fs::hard_link(
        request.root.join("credential-owned.pending"),
        request.root.join("credential-owned.json"),
    )
    .map_err(|_| ())?;
    fs::remove_file(request.root.join("credential-owned.pending")).map_err(|_| ())?;
    #[cfg(unix)]
    {
        File::open(&request.root)
            .map_err(|_| ())?
            .sync_all()
            .map_err(|_| ())?;
    }
    Ok(())
}

#[cfg(any(target_os = "windows", target_os = "linux"))]
fn verify_ownership(request: &Request) -> Result<(), ()> {
    let path = request.root.join("credential-owned.json");
    private_path(&path, false)?;
    let mut bytes = Vec::new();
    File::open(&path)
        .map_err(|_| ())?
        .take(1025)
        .read_to_end(&mut bytes)
        .map_err(|_| ())?;
    if bytes.len() > 1024 {
        return Err(());
    }
    let claim: Ownership = serde_json::from_slice(&bytes).map_err(|_| ())?;
    if claim.version != 1
        || claim.token != request.token
        || claim.account != request.account
        || claim.pid == 0
    {
        return Err(());
    }
    Ok(())
}

#[cfg(any(target_os = "windows", target_os = "linux"))]
struct NativeStore;
#[cfg(any(target_os = "windows", target_os = "linux"))]
impl CredentialStore for NativeStore {
    fn read(&self, id: &str) -> Result<Option<String>, ()> {
        connections::feasibility_read_password(id).map_err(|_| ())
    }
    fn save(&self, id: &str, value: &str) -> Result<(), ()> {
        connections::feasibility_save_password(id, value).map_err(|_| ())
    }
}

#[cfg(any(target_os = "windows", target_os = "linux"))]
fn wait_for_identity(request: &Request) -> Result<(), ()> {
    let path = request
        .root
        .join(format!("credential-go-{}", std::process::id()));
    let deadline = Instant::now() + Duration::from_secs(5);
    while !path.exists() {
        if Instant::now() >= deadline {
            return Err(());
        }
        std::thread::sleep(Duration::from_millis(10));
    }
    private_path(&path, false)?;
    if fs::metadata(&path).map_err(|_| ())?.len() != 32 {
        return Err(());
    }
    let mut bytes = Vec::new();
    File::open(&path)
        .map_err(|_| ())?
        .take(33)
        .read_to_end(&mut bytes)
        .map_err(|_| ())?;
    if bytes != request.token.as_bytes() {
        return Err(());
    }
    Ok(())
}

fn credential_worker(request: &Request, cleanup: bool) -> Result<(), ()> {
    // Refuse Mac Keychain even in a Mac development probe build.
    #[cfg(not(any(target_os = "windows", target_os = "linux")))]
    {
        let _ = (request, cleanup);
        Err(())
    }
    #[cfg(any(target_os = "windows", target_os = "linux"))]
    {
        let name = if cleanup {
            format!("credential-cleanup-{}.json", std::process::id())
        } else {
            "credential-probe.json".into()
        };
        // Establish a fresh output before touching the native store.
        let mut file = request.create(&name)?;
        wait_for_identity(request)?;
        let result = if cleanup {
            let owned = verify_ownership(request).is_ok();
            let verified = owned && cleanup_credential(&NativeStore, &request.account);
            CredentialResult {
                completed: true,
                cleanup_attempted: owned,
                cleanup_verified: verified,
                failed: !verified,
                ..Default::default()
            }
        } else {
            credential_roundtrip(&NativeStore, &request.account, || claim_credential(request))
        };
        serde_json::to_writer(
            &mut file,
            &serde_json::json!({"version": 1,
            "pid": std::process::id(), "native_acceptance": "not-run", "result": result}),
        )
        .map_err(|_| ())?;
        file.sync_all().map_err(|_| ())?;
        if result.failed || result.collision {
            Err(())
        } else {
            Ok(())
        }
    }
}

pub(super) fn dispatch() -> bool {
    let args: Vec<_> = std::env::args_os().skip(1).collect();
    if !args
        .iter()
        .any(|arg| arg.to_string_lossy().starts_with("--feasibility-"))
    {
        return false;
    }
    let parsed = (|| {
        if args.len() != 2 {
            return Err(());
        }
        let request = Request::load(Path::new(&args[1]))?;
        match args[0].to_str() {
            Some("--feasibility-probe") => {
                run_ui(request, false)?;
                Ok(())
            }
            Some("--feasibility-dev-smoke") if cfg!(target_os = "macos") => {
                run_ui(request, true)?;
                Ok(())
            }
            Some("--feasibility-credential-probe") => credential_worker(&request, false),
            Some("--feasibility-credential-cleanup") => credential_worker(&request, true),
            _ => Err(()),
        }
    })();
    if parsed.is_err() {
        eprintln!(
            "The disposable feasibility operation failed or was refused; inspect its bounded outcome report."
        );
        std::process::exit(2);
    }
    true
}

fn synthetic_grid() -> demo::QueryResult {
    let original = DemoTable::Products.rows();
    let rows = (0..1000)
        .map(|index| {
            let mut row = original[index % original.len()].clone();
            row[0] = demo::Cell::Number((index + 1).to_string());
            row
        })
        .collect();
    demo::QueryResult {
        columns: DemoTable::Products.columns(),
        rows,
    }
}

struct Probe {
    request: Request,
    editor: Entity<EditorState>,
    grid: Entity<TableState<ResultGrid>>,
    event_file: File,
    event_count: usize,
    status: SharedString,
    dialog_busy: bool,
    finished: bool,
}

impl Probe {
    fn new(
        request: Request,
        event_file: File,
        window: &mut Window,
        cx: &mut Context<Self>,
    ) -> Self {
        let editor = cx.new(|cx| {
            EditorState::new(window, cx)
                .language("sql")
                .default_value(SQL_FIXTURE)
        });
        let grid = cx.new(|cx| TableState::new(ResultGrid::new(synthetic_grid()), window, cx));
        editor.update(cx, |editor, cx| editor.focus(window, cx));
        Self {
            request,
            editor,
            grid,
            event_file,
            event_count: 0,
            status: "Disposable native probe; no database or saved profiles are loaded.".into(),
            dialog_busy: false,
            finished: false,
        }
    }

    fn event(&mut self, kind: &str, facts: serde_json::Value) {
        if self.event_count >= 256 {
            self.status = "Probe event limit reached; finish this run.".into();
            return;
        }
        let event = serde_json::json!({"kind": kind, "pid": std::process::id(), "facts": facts});
        if serde_json::to_writer(&mut self.event_file, &event).is_ok()
            && self.event_file.write_all(b"\n").is_ok()
            && self.event_file.sync_all().is_ok()
        {
            self.event_count += 1;
        } else {
            self.status = "Probe evidence could not be written.".into();
        }
    }

    fn capture(&mut self, window: &mut Window, cx: &mut Context<Self>) {
        let started = Instant::now();
        let table = self.grid.read(cx);
        let rows = table.visible_range().rows().clone();
        let cols = table.visible_range().cols().clone();
        let quads = window.painted_quads().len();
        let pixels = window
            .render_to_image()
            .ok()
            .map(|image| (image.width(), image.height()));
        self.event(
            "scene-grid-facts",
            serde_json::json!({
                "total_rows": table.delegate().total_count(), "visible_row_start": rows.start,
                "visible_row_end": rows.end, "visible_column_start": cols.start,
                "visible_column_end": cols.end, "painted_quad_count": quads,
                "scene_readback_supported": pixels.is_some(), "scene_pixels": pixels,
                "capture_elapsed_ms": started.elapsed().as_millis() as u64,
                "native_acceptance": "not-run"
            }),
        );
        self.status = "Scene and grid facts captured; native observations still required.".into();
        cx.notify();
    }

    fn clipboard(&mut self, cx: &mut Context<Self>) {
        let Some(original) = cx.read_from_clipboard() else {
            self.event(
                "clipboard",
                serde_json::json!({"outcome": "not-run-no-readable-original"}),
            );
            self.status = "Clipboard unchanged: no readable original item to restore.".into();
            cx.notify();
            return;
        };
        let marker = format!("DBeer feasibility marker {} \u{1f600}", self.request.token);
        cx.write_to_clipboard(ClipboardItem::new_string(marker.clone()));
        let matched = cx
            .read_from_clipboard()
            .and_then(|item| item.text())
            .as_deref()
            == Some(marker.as_str());
        // Restore only when the marker is still ours; never overwrite a concurrent update.
        let restore_requested = matched;
        if restore_requested {
            cx.write_to_clipboard(original.clone());
        }
        let restored = restore_requested && cx.read_from_clipboard().as_ref() == Some(&original);
        self.event(
            "clipboard",
            serde_json::json!({"marker_matched": matched,
            "restore_requested": restore_requested, "restored_item_matched": restored,
            "native_acceptance": "not-run"}),
        );
        self.status = "Clipboard probe recorded; verify external paste separately.".into();
        cx.notify();
    }

    fn dialog(&mut self, save: bool, cx: &mut Context<Self>) {
        if self.dialog_busy {
            return;
        }
        self.dialog_busy = true;
        let directory = self.request.root.join("fixtures");
        let open = (!save).then(|| {
            cx.prompt_for_paths(PathPromptOptions {
                files: true,
                directories: false,
                multiple: false,
                prompt: Some("Choose only fixtures/feasibility.sql in this probe run".into()),
            })
        });
        let save_path =
            save.then(|| cx.prompt_for_new_path(&directory, Some("feasibility-save.sql")));
        self.event("dialog-requested", serde_json::json!({"save": save}));
        cx.spawn(async move |this, cx| {
            let operation = async {
                if let Some(receiver) = open {
                    receiver
                        .await
                        .map_err(|_| ())?
                        .map_err(|_| ())
                        .map(|paths| {
                            paths.and_then(|mut paths| (paths.len() == 1).then(|| paths.remove(0)))
                        })
                } else if let Some(receiver) = save_path {
                    receiver.await.map_err(|_| ())?.map_err(|_| ())
                } else {
                    Err(())
                }
            };
            let selected = smol::future::race(operation, async {
                smol::Timer::after(Duration::from_secs(30)).await;
                Err(())
            })
            .await;
            _ = this.update(cx, |this, cx| {
                let outcome = match selected {
                    Ok(Some(path)) if selected_fixture(&this.request, &path, save) => {
                        "fixture-selected"
                    }
                    Ok(Some(_)) => "outside-fixture-rejected",
                    Ok(None) => "cancelled",
                    Err(()) => "error-or-timeout",
                };
                this.event(
                    "dialog-result",
                    serde_json::json!({"save": save, "outcome": outcome,
                    "selected_file_read": false, "destination_written": false}),
                );
                this.dialog_busy = false;
                this.status =
                    "Native chooser result recorded; no selected file was read or written.".into();
                cx.notify();
            });
        })
        .detach();
        cx.notify();
    }

    fn finish(&mut self) -> bool {
        if self.dialog_busy {
            return false;
        }
        if self.finished {
            return true;
        }
        let result = serde_json::json!({"version": 1, "pid": std::process::id(), "completed": true,
            "event_count": self.event_count, "grid_rows": 1000, "native_acceptance": "not-run"});
        let Ok(mut file) = self.request.create("probe-ui.json") else {
            return false;
        };
        if serde_json::to_writer(&mut file, &result).is_err() || file.sync_all().is_err() {
            return false;
        }
        self.finished = true;
        true
    }
}

impl Render for Probe {
    fn render(&mut self, _: &mut Window, cx: &mut Context<Self>) -> impl IntoElement {
        div()
            .size_full()
            .flex()
            .flex_col()
            .bg(cx.theme().background)
            .text_color(cx.theme().foreground)
            .child(TitleBar::new().child("DBeer native feasibility probe"))
            .child(
                div()
                    .flex()
                    .gap_2()
                    .p_2()
                    .child(
                        Button::new("probe-open")
                            .label("Open fixture")
                            .disabled(self.dialog_busy)
                            .on_click(cx.listener(|this, _, _, cx| this.dialog(false, cx))),
                    )
                    .child(
                        Button::new("probe-save")
                            .label("Save chooser only")
                            .disabled(self.dialog_busy)
                            .on_click(cx.listener(|this, _, _, cx| this.dialog(true, cx))),
                    )
                    .child(
                        Button::new("probe-clipboard")
                            .label("Clipboard marker")
                            .on_click(cx.listener(|this, _, _, cx| this.clipboard(cx))),
                    )
                    .child(
                        Button::new("probe-capture")
                            .label("Capture facts")
                            .on_click(cx.listener(|this, _, window, cx| this.capture(window, cx))),
                    )
                    .child(
                        Button::new("probe-bottom")
                            .label("Last row")
                            .on_click(cx.listener(|this, _, _, cx| {
                                this.grid.update(cx, |grid, cx| grid.scroll_to_row(999, cx))
                            })),
                    )
                    .child(
                        Button::new("probe-theme")
                            .label("Theme")
                            .on_click(|_, window, cx| {
                                apply_theme(
                                    if cx.theme().mode.is_dark() {
                                        ThemeMode::Light
                                    } else {
                                        ThemeMode::Dark
                                    },
                                    Some(window),
                                    cx,
                                )
                            }),
                    )
                    .child(
                        Button::new("probe-finish")
                            .label("Finish")
                            .disabled(self.dialog_busy)
                            .on_click(cx.listener(|this, _, _, cx| {
                                if this.finish() {
                                    cx.quit();
                                }
                            })),
                    ),
            )
            .child(
                div().h(px(190.)).p_2().child(
                    Editor::new(&self.editor)
                        .h_full()
                        .aria_label("Synthetic SQL feasibility editor"),
                ),
            )
            .child(
                div()
                    .flex_1()
                    .min_h_0()
                    .p_2()
                    .child(DataTable::new(&self.grid).small().stripe(true)),
            )
            .child(div().p_2().text_sm().child(self.status.clone()))
    }
}

fn run_ui(request: Request, development_smoke: bool) -> Result<(), ()> {
    let event_file = request.create("probe-events.jsonl")?;
    application().with_assets(assets::AllAssets).run(move |cx| {
        init(cx);
        apply_theme(ThemeMode::Dark, None, cx);
        let options = WindowOptions {
            window_bounds: Some(WindowBounds::Windowed(Bounds::centered(
                None,
                size(px(1280.), px(820.)),
                cx,
            ))),
            window_min_size: Some(size(px(950.), px(620.))),
            app_id: Some("dev.dbeer.feasibility".into()),
            ..TitleBar::window_options()
        };
        let (window, view) = open_window(options, cx, move |window, cx| {
            cx.new(|cx| Probe::new(request, event_file, window, cx))
        })
        .expect("Disposable feasibility window");
        if development_smoke {
            let probe = view.clone();
            _ = window.update(cx, |_, window, cx| {
                window
                    .spawn(cx, async move |cx| {
                        cx.background_executor()
                            .timer(Duration::from_millis(300))
                            .await;
                        _ = probe.update_in(cx, |this, window, cx| {
                            this.capture(window, cx);
                            this.grid.update(cx, |grid, cx| grid.scroll_to_row(999, cx));
                        });
                        cx.background_executor()
                            .timer(Duration::from_millis(300))
                            .await;
                        _ = probe.update_in(cx, |this, window, cx| {
                            this.capture(window, cx);
                            if this.finish() {
                                cx.quit();
                            }
                        });
                    })
                    .detach();
            });
        }
        let weak = view.downgrade();
        _ = window.update(cx, |_, window, cx| {
            window.on_window_should_close(cx, move |_, cx| {
                weak.update(cx, |this, _| this.finish()).unwrap_or(false)
            })
        });
        cx.on_window_closed(|cx, _| {
            if cx.windows().is_empty() {
                cx.quit();
            }
        })
        .detach();
        cx.activate(true);
    });
    Ok(())
}

#[cfg(test)]
mod tests {
    use super::{
        CredentialStore, MAX_REQUEST, Request, cleanup_credential, credential_roundtrip,
        selected_fixture, synthetic_grid,
    };
    use crate::demo;
    use std::{cell::RefCell, fs, path::PathBuf};

    const ACCOUNT: &str = "dbeer-feasibility-0123456789abcdef0123456789abcdef";
    #[derive(Default)]
    struct Store {
        value: RefCell<Option<String>>,
        writes: RefCell<usize>,
        fail_write_after_mutation: bool,
        fail_delete: bool,
    }
    impl CredentialStore for Store {
        fn read(&self, _: &str) -> Result<Option<String>, ()> {
            Ok(self.value.borrow().clone())
        }
        fn save(&self, _: &str, value: &str) -> Result<(), ()> {
            *self.writes.borrow_mut() += 1;
            if value.is_empty() && self.fail_delete {
                return Err(());
            }
            *self.value.borrow_mut() = if value.is_empty() {
                None
            } else {
                Some(value.into())
            };
            if !value.is_empty() && self.fail_write_after_mutation {
                Err(())
            } else {
                Ok(())
            }
        }
    }
    #[test]
    fn credential_roundtrip_deletes_only_reserved_account() {
        let store = Store::default();
        let result = credential_roundtrip(&store, ACCOUNT, || Ok(()));
        assert!(result.created && result.read_back && result.replaced && result.cleanup_verified);
        assert!(store.value.borrow().is_none());
        let invalid = credential_roundtrip(&store, "existing-production-profile", || Ok(()));
        assert!(invalid.failed);
        assert_eq!(*store.writes.borrow(), 3);
        assert!(!cleanup_credential(&store, "existing-production-profile"));
        assert_eq!(*store.writes.borrow(), 3);
    }
    #[test]
    fn failed_native_write_still_deletes_uncertain_item() {
        let store = Store {
            fail_write_after_mutation: true,
            ..Default::default()
        };
        let result = credential_roundtrip(&store, ACCOUNT, || Ok(()));
        assert!(result.failed && result.cleanup_attempted && result.cleanup_verified);
        assert!(store.value.borrow().is_none());
    }
    #[test]
    fn collision_is_never_overwritten_or_deleted() {
        let store = Store {
            value: RefCell::new(Some("existing-value".into())),
            ..Default::default()
        };
        let result = credential_roundtrip(&store, ACCOUNT, || Ok(()));
        assert!(result.collision && !result.cleanup_attempted);
        assert_eq!(*store.writes.borrow(), 0);
    }
    #[test]
    fn claim_failure_never_mutates_store_and_empty_collision_is_preserved() {
        let store = Store::default();
        let result = credential_roundtrip(&store, ACCOUNT, || Err(()));
        assert!(result.failed && !result.cleanup_attempted);
        assert_eq!(*store.writes.borrow(), 0);
        *store.value.borrow_mut() = Some(String::new());
        let result = credential_roundtrip(&store, ACCOUNT, || {
            panic!("Collision must not claim ownership")
        });
        assert!(result.collision && !result.cleanup_attempted);
        assert!(!cleanup_credential(&store, ACCOUNT));
        assert_eq!(*store.writes.borrow(), 0);
    }

    #[test]
    fn cleanup_failure_is_retained_without_values() {
        let store = Store {
            fail_delete: true,
            ..Default::default()
        };
        let result = credential_roundtrip(&store, ACCOUNT, || Ok(()));
        assert!(result.failed && result.cleanup_attempted && !result.cleanup_verified);
        let report = serde_json::to_string(&result).unwrap();
        assert!(!report.contains("synthetic"));
        assert!(!report.contains("replacement"));
    }
    #[test]
    fn grid_has_one_thousand_unique_rows_without_database() {
        let grid = synthetic_grid();
        assert_eq!(grid.rows.len(), 1000);
        assert_eq!(grid.rows[0][0], demo::Cell::Number("1".into()));
        assert_eq!(grid.rows[999][0], demo::Cell::Number("1000".into()));
        assert!(grid.rows.iter().all(|row| row.len() == grid.columns.len()));
    }
    #[test]
    fn chooser_rejects_outside_paths_and_never_reads_or_writes() {
        let base =
            PathBuf::from(env!("CARGO_MANIFEST_DIR")).join("../../build/gpui/probe-test-paths");
        fs::create_dir_all(&base).unwrap();
        let root = base.join(format!(
            "{}-{}",
            std::process::id(),
            std::time::SystemTime::now()
                .duration_since(std::time::UNIX_EPOCH)
                .unwrap()
                .as_nanos()
        ));
        fs::create_dir(&root).unwrap();
        fs::create_dir(root.join("fixtures")).unwrap();
        #[cfg(unix)]
        {
            use std::os::unix::fs::PermissionsExt;
            fs::set_permissions(&root, fs::Permissions::from_mode(0o700)).unwrap();
            fs::set_permissions(root.join("fixtures"), fs::Permissions::from_mode(0o700)).unwrap();
        }
        let root = root.canonicalize().unwrap();
        let request = Request {
            version: 1,
            root: root.clone(),
            token: "0123456789abcdef0123456789abcdef".into(),
            account: ACCOUNT.into(),
        };
        let original = root.join("fixtures/feasibility.sql");
        fs::write(&original, b"synthetic fixture").unwrap();
        assert!(selected_fixture(&request, &original, false));
        assert!(selected_fixture(
            &request,
            &root.join("fixtures/feasibility-save.sql"),
            true
        ));
        assert!(!selected_fixture(
            &request,
            &root.join("feasibility.sql"),
            false
        ));
        assert!(!root.join("fixtures/feasibility-save.sql").exists());
        assert_eq!(fs::read(&original).unwrap(), b"synthetic fixture");
        let request_path = root.join("probe-request.json");
        fs::write(
            &request_path,
            serde_json::to_vec(&serde_json::json!({"version": 1, "root": root,
            "token": "0123456789abcdef0123456789abcdef", "account": ACCOUNT}))
            .unwrap(),
        )
        .unwrap();
        #[cfg(unix)]
        {
            use std::os::unix::fs::PermissionsExt;
            fs::set_permissions(&request_path, fs::Permissions::from_mode(0o600)).unwrap();
        }
        #[cfg(not(windows))]
        assert!(Request::load(&request_path).is_ok());
        fs::write(&request_path, b"{\"version\":1,\"unexpected\":true}").unwrap();
        assert!(Request::load(&request_path).is_err());
        fs::write(&request_path, vec![b'x'; MAX_REQUEST as usize + 1]).unwrap();
        assert!(Request::load(&request_path).is_err());
        fs::remove_dir_all(&root).unwrap();
    }

    #[test]
    fn request_rejects_nonreserved_accounts_and_parent_roots() {
        let root = PathBuf::from(env!("CARGO_MANIFEST_DIR"))
            .canonicalize()
            .unwrap();
        let mut request = Request {
            version: 1,
            root,
            token: "0123456789abcdef0123456789abcdef".into(),
            account: ACCOUNT.into(),
        };
        request.account = "existing-production-profile".into();
        assert!(request.validate().is_err());
        request.account = ACCOUNT.into();
        request.root = PathBuf::from("relative");
        assert!(request.validate().is_err());
    }
}
