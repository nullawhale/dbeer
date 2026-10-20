//! Guarded profile lifecycle. Persistence follows captured close decisions.
use super::*;
use connections::ProfileSaveRequested;
use gpui_kit::component::menu::PopupMenu;
use live::environment;
use std::sync::Arc;

/// A captured, immutable mutation. No vector position or current UI selection
/// authorizes a write. The store revalidates the expected snapshot under lock.
pub(super) struct ProfileMutation {
    pub(super) change: ProfileChange,
    pub(super) editor: Option<WeakEntity<ConnectionEditor>>,
    pub(super) startup: bool,
}
pub(super) enum ProfileChange {
    Save(Box<ProfileSaveRequested>),
    Delete(Box<ConnectionProfile>),
}
impl ProfileMutation {
    pub(super) fn expected(&self) -> Option<&ConnectionProfile> {
        match &self.change {
            ProfileChange::Save(request) => request.expected.as_ref(),
            ProfileChange::Delete(expected) => Some(expected),
        }
    }
    pub(super) fn profile_id(&self) -> ProfileId {
        match &self.change {
            ProfileChange::Save(request) => ProfileId::saved(&request.profile),
            ProfileChange::Delete(expected) => ProfileId::saved(expected),
        }
    }
    pub(super) fn matches(&self, profiles: &[Profile]) -> bool {
        let current = profiles.iter().find(|p| p.id == self.profile_id());
        match self.expected() {
            Some(expected) => current.is_some_and(|p| p.config.as_ref() == Some(expected)),
            None => current.is_none(),
        }
    }
}

impl Profile {
    pub(super) fn unavailable(missing: bool) -> Self {
        Self {
            id: ProfileId::unbound(),
            demo: false,
            generation: 0,
            service_generation: 0,
            name: if missing {
                "Missing connection"
            } else {
                "Select connection"
            }
            .into(),
            environment: "Not connected",
            config: None,
            loaded: false,
            expanded: false,
            session: None,
            session_settings: None,
            session_client: None,
            schemas: Vec::new(),
            task: None,
            status: "Not connected. Select a saved connection explicitly to run SQL.".into(),
        }
    }
    pub(super) fn saved(profile: ConnectionProfile) -> Self {
        Self {
            id: ProfileId::saved(&profile),
            demo: false,
            generation: 0,
            service_generation: 0,
            name: profile.name.clone().into(),
            environment: environment(&profile.environment),
            config: Some(profile),
            loaded: false,
            expanded: false,
            session: None,
            session_settings: None,
            session_client: None,
            schemas: Vec::new(),
            task: None,
            status: "Disconnected".into(),
        }
    }
}

impl Workspace {
    pub(super) fn profile_menu(
        menu: PopupMenu,
        view: WeakEntity<Self>,
        id: ProfileId,
        saved: bool,
        window: &mut Window,
        cx: &mut App,
    ) -> PopupMenu {
        let mut entries = vec![CommandId::SelectProfile, CommandId::NewProfileTab];
        if saved {
            entries.extend([
                CommandId::Connect,
                CommandId::Disconnect,
                CommandId::EditProfile,
                CommandId::DeleteProfile,
                CommandId::ExportProfiles,
            ]);
        }
        let Some(view) = view.upgrade() else {
            return menu;
        };
        view.update(cx, |this, cx| {
            this.build_command_menu(menu, &entries, Some(id), window, cx)
        })
    }
    pub fn load_profiles(&mut self) {
        if self.startup_policy.built_in_fixtures {
            return;
        }
        match self
            .profile_store
            .clone()
            .ok_or(connections::ProfileError::Ownership)
        {
            Ok(store) => match store.load_library() {
                Ok(library) => {
                    self.profiles
                        .extend(library.connections.into_iter().map(Profile::saved));
                    if let Some(id) = library.selected_profile_id
                        && let Some(index) = self.profiles.iter().position(|p| p.id.0 == id)
                    {
                        self.selected_profile = index;
                    }
                }
                Err(e) => self.profile_error = Some(e.to_string()),
            },
            Err(e) => self.profile_error = Some(e.to_string()),
        }
    }
    /// Ordered selection merges latest metadata; it never changes an existing
    /// document's profile or physical session. Modal callers must not enter.
    pub(super) fn select_profile(&mut self, index: usize, cx: &mut Context<Self>) {
        if self.closing || index >= self.profiles.len() {
            return;
        }
        self.selected_profile = index;
        let Some(store) = self.profile_store.as_ref() else {
            return;
        };
        let id = self.profiles[index].config.as_ref().map(ProfileId::saved);
        let request = store.selection(id.as_ref());
        cx.spawn(async move |this, cx| {
            let result = cx
                .background_executor()
                .spawn(async move { request.commit() })
                .await;
            if let Err(error) = result {
                _ = this.update(cx, |this, cx| {
                    let index = id
                        .as_ref()
                        .and_then(|id| this.profile_index(id))
                        .unwrap_or(0);
                    if let Some(profile) = this.profiles.get_mut(index) {
                        profile.status = error.to_string().into();
                    } else {
                        this.profile_error = Some(error.to_string());
                    }
                    cx.notify();
                });
            }
        })
        .detach();
    }
    pub fn edit_profile(
        &mut self,
        index: Option<usize>,
        window: &mut Window,
        cx: &mut Context<Self>,
    ) {
        if self.closing || window.has_active_dialog(cx) || self.profile_store.is_none() {
            return;
        }
        let profile = index.and_then(|i| self.profiles.get(i)?.config.clone());
        if index.is_some() && profile.is_none() {
            return;
        }
        let editor = cx.new(|cx| ConnectionEditor::new(profile, window, cx));
        self.attach_profile_editor(&editor, window, cx);
        Self::show_profile_editor(editor, window, cx);
    }
    fn attach_profile_editor(
        &mut self,
        editor: &Entity<ConnectionEditor>,
        window: &mut Window,
        cx: &mut Context<Self>,
    ) {
        self.dismiss_completion();
        self.dismiss_signatures();
        if let Some(previous) = self.profile_editor.as_ref() {
            previous.update(cx, |previous, _| previous.deactivate());
        }
        self.editor_subscription = Some(cx.subscribe_in(
            editor,
            window,
            |this, editor, request: &ProfileSaveRequested, window, cx| {
                if this.profile_editor.as_ref() != Some(editor) || !editor.read(cx).is_active() {
                    return;
                }
                window.close_dialog(cx);
                let mutation = Arc::new(ProfileMutation {
                    change: ProfileChange::Save(Box::new(request.clone())),
                    editor: Some(editor.downgrade()),
                    startup: false,
                });
                this.request_close(CloseIntent::ProfileMutation(mutation), window, cx);
            },
        ));
        self.profile_editor = Some(editor.clone());
    }
    fn show_profile_editor(
        editor: Entity<ConnectionEditor>,
        window: &mut Window,
        cx: &mut Context<Self>,
    ) {
        editor.update(cx, |editor, _| editor.activate());
        let focus = editor.clone();
        window.open_dialog(cx, move |dialog, _, _| {
            dialog
                .title("Connection")
                .accessibility_label("Connection")
                .w(px(560.))
                .overlay_closable(false)
                .close_button(false)
                .keyboard(false)
                .content({
                    let editor = editor.clone();
                    move |content, _, _| content.child(editor.clone())
                })
        });
        focus.update(cx, |editor, cx| editor.focus(window, cx));
    }
    pub(super) fn restore_profile_editor(
        &mut self,
        mutation: &ProfileMutation,
        error: Option<String>,
        window: &mut Window,
        cx: &mut Context<Self>,
    ) {
        if let Some(editor) = mutation.editor.as_ref().and_then(WeakEntity::upgrade) {
            if self.profile_editor.as_ref() != Some(&editor) {
                return;
            }
            self.dismiss_completion();
            self.dismiss_signatures();
            editor.update(cx, |editor, cx| editor.finish_save(error, cx));
            Self::show_profile_editor(editor, window, cx);
        } else if let Some(error) = error {
            Self::information(error, window, cx);
        }
    }
    pub(super) fn delete_profile(
        &mut self,
        id: ProfileId,
        window: &mut Window,
        cx: &mut Context<Self>,
    ) {
        if self.closing || window.has_active_dialog(cx) {
            return;
        }
        let Some(expected) = self
            .profiles
            .iter()
            .find(|p| p.id == id)
            .and_then(|p| p.config.clone())
        else {
            return;
        };
        let mutation = Arc::new(ProfileMutation {
            change: ProfileChange::Delete(Box::new(expected)),
            editor: None,
            startup: false,
        });
        let view = cx.entity().downgrade();
        window.open_dialog(cx, move |dialog, _, _| {
            let view = view.clone(); let mutation = mutation.clone();
            dialog.title("Delete connection?").accessibility_label("Delete connection?").overlay_closable(false).close_button(false).keyboard(false)
                .child("The saved profile and its password will be removed after its sessions finish. Other connections are unchanged.")
                .footer(div().flex().gap_2().justify_end()
                    .child(Button::new("cancel-delete-profile").label("Cancel").on_click(|_, window, cx| window.close_dialog(cx)))
                    .child(Button::new("delete-profile").label("Delete").on_click(move |_, window, cx| {
                        window.close_dialog(cx);
                        _ = view.update(cx, |this, cx| this.request_close(CloseIntent::ProfileMutation(mutation.clone()), window, cx));
                    })))
        });
    }
    /// Only reached after decisions and acknowledged session teardown. Metadata
    /// and credentials are coordinated by ProfileStore, then the UI is updated.
    pub(super) fn commit_profile_mutation(
        &mut self,
        mutation: Arc<ProfileMutation>,
        window: &mut Window,
        cx: &mut Context<Self>,
    ) {
        self.commit_profile_mutation_with_drafts(mutation, Vec::new(), window, cx);
    }
    pub(super) fn commit_profile_mutation_with_drafts(
        &mut self,
        mutation: Arc<ProfileMutation>,
        drafts: Vec<close::DraftReview>,
        window: &mut Window,
        cx: &mut Context<Self>,
    ) {
        if !mutation.matches(&self.profiles)
            || self
                .tabs
                .iter()
                .any(|t| t.profile == mutation.profile_id() && t.snapshot_locked())
        {
            self.restore_profile_editor(
                &mutation,
                Some(connections::ProfileError::Conflict.to_string()),
                window,
                cx,
            );
            return;
        }
        let Some(store) = self.profile_store.clone() else {
            self.restore_profile_editor(
                &mutation,
                Some(connections::ProfileError::Ownership.to_string()),
                window,
                cx,
            );
            return;
        };
        if let Some(index) = self.profile_index(&mutation.profile_id()) {
            self.profiles[index].loaded = false;
            self.profiles[index].session_settings = None;
            self.profiles[index].schemas.clear();
            self.profiles[index].status = "Disconnected".into();
            for tab in &mut self.tabs {
                if tab.profile == mutation.profile_id() {
                    tab.retire_session();
                    tab.query_id = None;
                    tab.transaction = "idle".into();
                    tab.uncertain = false;
                    tab.status = "Disconnected".into();
                }
            }
        }
        self.closing = true;
        self.closing_task = Some(cx.spawn_in(window, async move |this, cx| {
            let request = mutation.clone();
            let result = cx
                .background_executor()
                .spawn(async move {
                    match &request.change {
                        ProfileChange::Save(save) => store
                            .save_profile(
                                &save.profile,
                                save.password.as_ref().map(|p| p.expose()),
                                save.expected.as_ref(),
                            )
                            .map(|_| None),
                        ProfileChange::Delete(expected) => store.delete(expected).map(Some),
                    }
                })
                .await;
            _ = this.update_in(cx, |this, window, cx| {
                this.closing = false;
                this.closing_task = None;
                match result {
                    Err(error) => {
                        this.restore_profile_editor(&mutation, Some(error.to_string()), window, cx)
                    }
                    Ok(library) => {
                        this.discard_reviewed_drafts(&drafts,window,cx);
                        match &mutation.change {
                        ProfileChange::Save(save) => {
                            for tab in &mut this.tabs {
                                if tab.profile == mutation.profile_id() {
                                    tab.clear_execution_marks();
                                    tab.execution_decoration.clear(cx);
                                }
                            }
                            let index =
                                if let Some(index) = this.profile_index(&mutation.profile_id()) {
                                    let generation = this.profiles[index].generation + 1;
                                    this.profiles[index] = Profile::saved(save.profile.clone());
                                    this.profiles[index].generation = generation;
                                    index
                                } else {
                                    this.profiles.push(Profile::saved(save.profile.clone()));
                                    this.profiles.len() - 1
                                };
                            if let Some(editor) =
                                mutation.editor.as_ref().and_then(WeakEntity::upgrade)
                            {
                                editor.update(cx, |editor, cx| {
                                    editor.clear_password(window, cx);
                                    editor.finish_save(None, cx);
                                });
                            }
                            this.select_profile(index, cx);
                            if save.expected.is_none() || mutation.startup {
                                this.add_sql_tab(
                                    "Query.sql".into(),
                                    String::new(),
                                    window,
                                    cx,
                                );
                            }
                            if save.connect {
                                this.connect_profile(index, window, cx);
                            }
                        }
                        ProfileChange::Delete(_) => {
                            let deleted = mutation.profile_id();
                            let selected = this.profiles.get(this.selected_profile).map(|profile| profile.id.clone()).unwrap_or_else(ProfileId::unbound);
                            let active = this.tabs.get(this.active).map(|tab| tab.id);
                            // A deleted binding never retargets or discards its SQL.
                            if let Some(index) = this.profile_index(&deleted) {
                                let profile = &mut this.profiles[index];
                                profile.config = None;
                                profile.generation += 1;
                                profile.name = "Missing connection".into();
                                profile.status = "Disconnected. Choose a saved connection explicitly to run SQL.".into();
                            }
                            let restored = library
                                .and_then(|lib| lib.selected_profile_id)
                                .map(ProfileId);
                            this.selected_profile = this
                                .profile_index(&selected)
                                .filter(|_| selected != deleted)
                                .or_else(|| restored.as_ref().and_then(|id| this.profile_index(id)))
                                .unwrap_or(0);
                            if this.tabs.is_empty() {
                                this.add_default_tab(DemoTable::Products, window, cx);
                            } else {
                                this.active =
                                    this.tabs.iter().position(|t| Some(t.id) == active).unwrap_or(0);
                            }
                        }
                    } },
                }
                this.schedule_documents(cx);
                cx.notify();
            });
        }));
        cx.notify();
    }
    /// The explicit launch channel is consumed once by main, never by profile
    /// restoration. Save through the normal store, then exactly one Connect;
    /// creating a document never submits its SQL.
    pub(super) fn start_explicit_connection(
        &mut self,
        input: Result<startup::StartupConnection, startup::InputError>,
        window: &mut Window,
        cx: &mut Context<Self>,
    ) {
        if self.startup_consumed {
            return;
        }
        self.startup_consumed = true;
        match input {
            Ok(mut input) => {
                let existing = self
                    .profiles
                    .iter()
                    .filter_map(|p| p.config.as_ref())
                    .find(|p| {
                        p.engine == input.profile.engine
                            && p.host == input.profile.host
                            && p.port == input.profile.port
                            && p.database == input.profile.database
                            && p.user == input.profile.user
                            && p.ssl_mode == input.profile.ssl_mode
                            && p.ssl_root_cert == input.profile.ssl_root_cert
                            && p.readonly == input.profile.readonly
                            && p.environment == input.profile.environment
                    })
                    .cloned();
                if let Some(expected) = &existing {
                    input.profile.id = expected.id.clone();
                    input.profile.name = expected.name.clone();
                }
                let editor = cx.new(|cx| {
                    ConnectionEditor::from_startup(
                        input.profile.clone(),
                        existing.clone(),
                        input.password.expose(),
                        window,
                        cx,
                    )
                });
                self.attach_profile_editor(&editor, window, cx);
                let mutation = Arc::new(ProfileMutation {
                    change: ProfileChange::Save(Box::new(ProfileSaveRequested {
                        profile: input.profile,
                        expected: existing,
                        password: Some(Arc::new(input.password)),
                        connect: true,
                    })),
                    editor: Some(editor.downgrade()),
                    startup: true,
                });
                self.request_close(CloseIntent::ProfileMutation(mutation), window, cx);
            }
            Err(_) => self.edit_startup_recovery(window, cx),
        }
    }
    fn edit_startup_recovery(&mut self, window: &mut Window, cx: &mut Context<Self>) {
        self.edit_profile(None, window, cx);
        if let Some(editor) = &self.profile_editor {
            editor.update(cx, |editor, cx| {
                editor.finish_save(Some(startup::INPUT_ERROR.into()), cx)
            });
        }
    }
    pub(super) fn information(message: impl Into<SharedString>, window: &mut Window, cx: &mut App) {
        let message = message.into();
        window.open_dialog(cx, move |dialog, _, _| {
            dialog
                .title("DBeer")
                .accessibility_label("DBeer")
                .child(message.clone())
        });
    }
}
