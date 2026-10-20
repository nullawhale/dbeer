//! Native choosers capture their original window, snapshots and preview entity.
use super::*;
use connections::ProfileError;
use gpui_kit::component::checkbox::Checkbox;
use transfer::{ImportedProfile, TransferError};

pub(super) struct TransferReview {
    store: ProfileStore,
    expected: Vec<ConnectionProfile>,
    rows: Vec<ImportedProfile>,
    active: bool,
    saving: bool,
    error: Option<String>,
    chooser: Option<Task<()>>,
    task: Option<Task<()>>,
    workspace: WeakEntity<Workspace>,
}
impl TransferReview {
    pub(super) fn is_active(&self) -> bool {
        self.active
    }
    fn cancel(&mut self, window: &mut Window, cx: &mut Context<Self>) {
        if !self.active || self.saving {
            return;
        }
        self.active = false;
        self.chooser = None;
        window.close_dialog(cx);
        cx.notify();
    }
    fn ready(&self) -> bool {
        self.active
            && !self.saving
            && self.chooser.is_none()
            && self.rows.iter().any(|p| p.selected)
            && !self.rows.iter().any(|p| p.selected && p.requires_ca())
    }
    fn apply_ca_selection(&mut self, id: &str, path: &std::path::Path) {
        if !self.active || self.saving {
            return;
        }
        if let Some(row) = self.rows.iter_mut().find(|row| row.profile.id == id) {
            self.error = row.remap_ca(path).err().map(|e| e.to_string());
        }
    }
    fn choose_ca(&mut self, id: String, window: &mut Window, cx: &mut Context<Self>) {
        if !self.active || self.saving || self.chooser.is_some() {
            return;
        }
        let selected = cx.prompt_for_paths(PathPromptOptions {
            files: true,
            directories: false,
            multiple: false,
            prompt: Some("Choose a trusted CA file; TLS mode stays unchanged".into()),
        });
        self.chooser = Some(cx.spawn_in(window, async move |this, cx| {
            let result = selected.await;
            _ = this.update_in(cx, |this, _, cx| {
                this.chooser = None;
                if !this.active || this.saving {
                    return;
                }
                match result {
                    Ok(Ok(Some(paths))) if paths.len() == 1 => {
                        this.apply_ca_selection(&id, &paths[0]);
                    }
                    Ok(Ok(None)) => {}
                    _ => {
                        this.error = Some("The CA certificate chooser could not be opened.".into())
                    }
                }
                cx.notify();
            });
        }));
        cx.notify();
    }
    fn import(&mut self, window: &mut Window, cx: &mut Context<Self>) {
        if !self.ready() {
            self.error = Some(TransferError::MissingCA.to_string());
            cx.notify();
            return;
        }
        self.saving = true;
        self.error = None;
        let store = self.store.clone();
        let expected = self.expected.clone();
        let rows = self.rows.clone();
        let workspace = self.workspace.clone();
        // Cancel is disabled during the single atomic publication. The dialog
        // remains until success/failure; dropping a task cannot cause a retry.
        self.task = Some(cx.spawn_in(window, async move |this, cx| {
            let result = cx
                .background_executor()
                .spawn(async move { store.import_profiles(&expected, &rows) })
                .await;
            _ = this.update_in(cx, |this, window, cx| {
                this.task = None;
                this.saving = false;
                let current = cx.entity();
                let owns_dialog = workspace
                    .update(cx, |workspace, _| {
                        workspace.transfer_review.as_ref() == Some(&current)
                    })
                    .unwrap_or(false);
                if !this.active || !owns_dialog {
                    return;
                }
                match result {
                    Ok(imported) => {
                        this.active = false;
                        _ = workspace.update(cx, |workspace, cx| {
                            workspace
                                .profiles
                                .extend(imported.into_iter().map(Profile::saved));
                            cx.notify();
                        });
                        window.close_dialog(cx);
                    }
                    Err(error) => this.error = Some(error.to_string()),
                }
                cx.notify();
            });
        }));
        cx.notify();
    }
}
impl Render for TransferReview {
    fn render(&mut self, _: &mut Window, cx: &mut Context<Self>) -> impl IntoElement {
        let disabled = self.saving || !self.active;
        let mut rows = div()
            .id("profile-transfer-rows")
            .max_h(px(380.))
            .overflow_y_scroll()
            .flex()
            .flex_col()
            .gap_3();
        for (index, row) in self.rows.iter().enumerate() {
            let id = row.profile.id.clone();
            let p = &row.profile;
            let missing = row.requires_ca();
            rows = rows.child(
                div()
                    .flex()
                    .flex_col()
                    .gap_1()
                    .child(
                        Checkbox::new(("import-select", index))
                            .label(p.name.clone())
                            .checked(row.selected)
                            .disabled(disabled)
                            .on_change(cx.listener(move |this, checked: &bool, _, cx| {
                                if this.active && !this.saving {
                                    this.rows[index].selected = *checked;
                                    cx.notify();
                                }
                            })),
                    )
                    .child(div().text_xs().child(format!(
                        "{} | {}@{}:{} | {} | {} | {} | readonly: {}",
                        p.display_engine(),
                        p.user,
                        p.host,
                        p.port,
                        p.database,
                        p.ssl_mode,
                        p.environment,
                        p.readonly
                    )))
                    .when_some(p.ssl_root_cert.clone(), |row, path| {
                        row.child(div().text_xs().child(format!("CA hint: {path}")))
                    })
                    .when(p.ssl_root_cert.is_some(), |row| {
                        row.child(
                            Button::new(("import-ca", index))
                                .small()
                                .label(if missing {
                                    "Choose missing/local CA..."
                                } else {
                                    "Replace CA..."
                                })
                                .disabled(disabled || self.chooser.is_some())
                                .on_click(cx.listener(move |this, _, window, cx| {
                                    this.choose_ca(id.clone(), window, cx)
                                })),
                        )
                    }),
            );
        }
        div().flex().flex_col().gap_3()
            .child("Review connection settings. Passwords and private keys are excluded. Imports create new disconnected profiles; existing profiles and passwords are preserved.")
            .child(div().flex().gap_2()
                .child(Button::new("import-all").small().label("Select All").disabled(disabled).on_click(cx.listener(|this, _, _, cx| { if this.active && !this.saving { for row in &mut this.rows { row.selected = true; } cx.notify(); } })))
                .child(Button::new("import-none").small().label("Select None").disabled(disabled).on_click(cx.listener(|this, _, _, cx| { if this.active && !this.saving { for row in &mut this.rows { row.selected = false; } cx.notify(); } }))))
            .child(rows)
            .when_some(self.error.clone(), |el, error| el.child(div().text_sm().child(error)))
            .child(div().flex().justify_end().gap_2()
                .child(Button::new("cancel-profile-import").label("Cancel").disabled(self.saving).on_click(cx.listener(Self::cancel_click)))
                .child(Button::new("confirm-profile-import").primary().label(if self.saving { "Importing..." } else { "Import Selected" }).disabled(!self.ready()).on_click(cx.listener(|this, _, window, cx| this.import(window, cx)))))
    }
}
impl TransferReview {
    fn cancel_click(&mut self, _: &ClickEvent, window: &mut Window, cx: &mut Context<Self>) {
        self.cancel(window, cx);
    }
}
impl Workspace {
    pub(super) fn import_profiles(&mut self, window: &mut Window, cx: &mut Context<Self>) {
        if self.closing || window.has_active_dialog(cx) || self.transfer_task.is_some() {
            return;
        }
        let Some(store) = self.profile_store.clone() else {
            return;
        };
        // Capture both library and visible profiles before opening the chooser.
        // Changes to originals invalidate review; newly added records are merged.
        let expected = self
            .profiles
            .iter()
            .filter_map(|p| p.config.clone())
            .collect::<Vec<_>>();
        let selected = cx.prompt_for_paths(PathPromptOptions {
            files: true,
            directories: false,
            multiple: false,
            prompt: Some("Import connection profiles".into()),
        });
        self.transfer_task = Some(cx.spawn_in(window, async move |this, cx| {
            let result = selected.await;
            let source = match result {
                Ok(Ok(Some(mut paths))) if paths.len() == 1 => Some(Ok(paths.remove(0))),
                Ok(Ok(None)) => None,
                _ => Some(Err(TransferError::Read)),
            };
            let Some(source) = source else {
                _ = this.update(cx, |this, _| this.transfer_task = None);
                return;
            };
            let result = cx
                .background_executor()
                .spawn(async move { source.and_then(|path| transfer::read_preview(&path)) })
                .await;
            _ = this.update_in(cx, |this, window, cx| {
                this.transfer_task = None;
                if this.closing || window.has_active_dialog(cx) {
                    return;
                }
                match result {
                    Ok(rows) => {
                        if expected.iter().any(|p| {
                            !this
                                .profiles
                                .iter()
                                .any(|current| current.config.as_ref() == Some(p))
                        }) {
                            Self::information(ProfileError::Conflict.to_string(), window, cx);
                            return;
                        }
                        this.show_import_review(store, expected, rows, window, cx);
                    }
                    Err(error) => Self::information(error.to_string(), window, cx),
                }
                cx.notify();
            });
        }));
    }
    fn show_import_review(
        &mut self,
        store: ProfileStore,
        expected: Vec<ConnectionProfile>,
        rows: Vec<ImportedProfile>,
        window: &mut Window,
        cx: &mut Context<Self>,
    ) {
        self.dismiss_completion();
        self.dismiss_signatures();
        if let Some(previous) = self.transfer_review.as_ref() {
            previous.update(cx, |previous, _| previous.active = false);
        }
        let workspace = cx.entity().downgrade();
        let review = cx.new(|_| TransferReview {
            store,
            expected,
            rows,
            active: true,
            saving: false,
            error: None,
            chooser: None,
            task: None,
            workspace,
        });
        self.transfer_review = Some(review.clone());
        window.open_dialog(cx, move |dialog, _, _| {
            dialog
                .title("Import Connections")
                .accessibility_label("Import Connections")
                .w(px(650.))
                .overlay_closable(false)
                .close_button(false)
                .keyboard(false)
                .content({
                    let review = review.clone();
                    move |content, _, _| content.child(review.clone())
                })
        });
    }
    pub(super) fn export_profiles(
        &mut self,
        id: Option<ProfileId>,
        window: &mut Window,
        cx: &mut Context<Self>,
    ) {
        if self.closing || window.has_active_dialog(cx) || self.transfer_task.is_some() {
            return;
        }
        let profiles = self
            .profiles
            .iter()
            .filter(|p| id.as_ref().is_none_or(|id| &p.id == id))
            .filter_map(|p| p.config.clone())
            .collect::<Vec<_>>();
        let bytes = match transfer::encode(&profiles) {
            Ok(bytes) => bytes,
            Err(error) => {
                Self::information(error.to_string(), window, cx);
                return;
            }
        };
        // Save callbacks use the immutable original export, never current selection.
        let directory = std::env::current_dir().unwrap_or_else(|_| std::env::temp_dir());
        let selected = cx.prompt_for_new_path(&directory, Some("dbeer-connections.json"));
        self.transfer_task = Some(cx.spawn_in(window, async move |this, cx| {
            let result = selected.await;
            let result = match result {
                Ok(Ok(Some(path))) => {
                    let capture = files::CapturedDestination::capture(&path);
                    match capture {
                        Ok(capture) => cx
                            .background_executor()
                            .spawn(async move { transfer::write_captured(&bytes, &path, &capture) })
                            .await,
                        Err(_) => Err(TransferError::Write),
                    }
                }
                Ok(Ok(None)) => Ok(()),
                _ => Err(TransferError::Write),
            };
            _ = this.update_in(cx, |this, window, cx| {
                this.transfer_task = None;
                if let Err(error) = result {
                    Self::information(error.to_string(), window, cx);
                }
                cx.notify();
            });
        }));
    }
}

#[cfg(all(test, feature = "native-smoke"))]
mod tests {
    use crate::{ConnectionProfile, ProfileStore, Workspace, apply_theme, transfer};
    use gpui_kit::component::{ThemeMode, WindowExt};
    use gpui_kit::test::TestWindowExt;
    use gpui_kit::{AppContext, TestAppContext, WindowOptions};
    use std::fs;
    use std::path::PathBuf;

    #[gpui_kit::test]
    fn review_selection_missing_ca_cancel_and_late_remap_preserve_the_original_library(
        cx: &mut TestAppContext,
    ) {
        let root = PathBuf::from(env!("CARGO_MANIFEST_DIR"))
            .join("../../build/gpui/transfer-ui-tests")
            .join(ConnectionProfile::new().id);
        let store = ProfileStore::acquire(root.join("connections.json")).unwrap();
        let original = ConnectionProfile::new();
        store.save(std::slice::from_ref(&original)).unwrap();
        let original_bytes = fs::read(root.join("connections.json")).unwrap();
        let mut rows =
            transfer::preview(&transfer::encode(&[original.clone(), original.clone()]).unwrap())
                .unwrap();
        rows[1].profile.ssl_root_cert = Some(root.join("missing.pem").to_str().unwrap().into());
        let pending_id = rows[1].profile.id.clone();
        let ca = root.join("public-ca.pem");
        fs::write(&ca, "public CA fixture").unwrap();
        let (window, workspace) = cx.update(|cx| {
            gpui_kit::init(cx);
            apply_theme(ThemeMode::Dark, None, cx);
            gpui_kit::open_window(WindowOptions::default(), cx, |window, cx| {
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
            .unwrap()
        });
        cx.update_window(window, |_, window, cx| {
            workspace.update(cx, |workspace, cx| {
                workspace.show_import_review(store.clone(), vec![original], rows, window, cx)
            });
            window.render_frame(cx);
            let review = workspace.read(cx).transfer_review.clone().unwrap();
            assert!(!review.read(cx).ready());
            window.click(("import-select", 1usize), cx);
            assert!(
                review.read(cx).ready(),
                "Unselected missing CA must not block another profile"
            );
            window.click("import-none", cx);
            assert!(!review.read(cx).ready());
            window.click("import-all", cx);
            assert!(!review.read(cx).ready());
            window.click("cancel-profile-import", cx);
            assert!(!window.has_active_dialog(cx));
            let before = review.read(cx).rows.clone();
            review.update(cx, |review, cx| {
                review.apply_ca_selection(&pending_id, &ca);
                review.import(window, cx);
            });
            assert_eq!(
                review.read(cx).rows,
                before,
                "Late chooser reply must not mutate a cancelled review"
            );
            assert!(!review.read(cx).active && review.read(cx).task.is_none());
            assert!(
                workspace
                    .read(cx)
                    .profiles
                    .iter()
                    .all(|p| p.session.is_none() && p.task.is_none())
            );
        })
        .unwrap();
        assert_eq!(
            fs::read(root.join("connections.json")).unwrap(),
            original_bytes
        );
        drop(store);
        fs::remove_dir_all(root).unwrap();
    }
    #[gpui_kit::test]
    fn import_cancel_success_and_old_review_callbacks_release_assistance(cx: &mut TestAppContext) {
        let root = PathBuf::from(env!("CARGO_MANIFEST_DIR"))
            .join("../../build/gpui/quality-import-assistance-tests")
            .join(uuid::Uuid::new_v4().to_string());
        let store = ProfileStore::acquire(root.join("connections.json")).unwrap();
        let original = ConnectionProfile::new();
        store.save(std::slice::from_ref(&original)).unwrap();
        let rows =
            transfer::preview(&transfer::encode(std::slice::from_ref(&original)).unwrap()).unwrap();
        let (window, view) = crate::workspace_tests::workspace(cx);
        cx.update(|cx| cx.background_executor().allow_parking());
        let initial_profile_count = cx.update(|cx| view.read(cx).profiles.len());
        let old = cx
            .update_window(window, |_, window, cx| {
                view.update(cx, |this, cx| {
                    this.show_import_review(
                        store.clone(),
                        vec![original.clone()],
                        rows.clone(),
                        window,
                        cx,
                    );
                    assert!(this.completion_editor(window, cx).is_none());
                    this.transfer_review.clone().unwrap()
                })
            })
            .unwrap();
        cx.update_window(window, |_, window, cx| {
            window.render_frame(cx);
            window.click("cancel-profile-import", cx);
            view.update(cx, |this, cx| {
                this.tabs[this.active].editor.update(cx, |state, cx| {
                    state.set_value("SELECT f(", window, cx);
                    state.set_selected_range(9..9, cx);
                    state.focus(window, cx);
                });
                assert!(this.completion_editor(window, cx).is_some());
                this.show_import_review(store.clone(), vec![original.clone()], rows, window, cx);
            });
            old.update(cx, |old, cx| old.cancel(window, cx));
            assert!(
                window.has_active_dialog(cx),
                "An old review closed the newer review."
            );
            let review = view.read(cx).transfer_review.clone().unwrap();
            review.update(cx, |review, cx| review.import(window, cx));
        })
        .unwrap();
        crate::workspace_tests::await_workspace(cx, &view, |this| {
            this.profiles.len() == initial_profile_count + 1
        });
        cx.update_window(window, |_, window, cx| {
            view.update(cx, |this, cx| {
                this.tabs[this.active]
                    .editor
                    .update(cx, |state, cx| state.focus(window, cx));
                assert!(!this.transfer_review.as_ref().unwrap().read(cx).is_active());
                assert!(this.completion_editor(window, cx).is_some());
                for invocation in [
                    crate::completion_view::Invocation::Manual,
                    crate::completion_view::Invocation::Automatic,
                ] {
                    this.start_completion(this.tabs[this.active].id, invocation, window, cx);
                    assert!(this.completion_editor(window, cx).is_some());
                    this.dismiss_completion();
                }
                this.start_signatures(
                    this.tabs[this.active].id,
                    crate::signature_view::Invocation::Manual,
                    window,
                    cx,
                );
                assert!(this.signature_escape(false, window, cx));
                assert!(this.backend.is_none());
            })
        })
        .unwrap();
        crate::completion::tests::assert_recovered_fake_assistance(cx, window, &view);
        drop(store);
        _ = fs::remove_dir_all(root);
    }
}
