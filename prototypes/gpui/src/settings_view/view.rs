use super::{
    Choice, PREVIEW_SQL,
    model::{ChoiceGroup, Presentation, SettingsAction, SettingsEvent},
};
use gpui_kit::{
    base::Disableable,
    component::{
        ActiveTheme, IndexPath,
        button::{Button, ButtonVariants},
        input::{Editor, EditorState, InputAccessibilityGuard},
        select::{SearchableVec, Select, SelectEvent, SelectGroup, SelectItem, SelectState},
    },
    prelude::FluentBuilder,
    *,
};

type Menu = SearchableVec<SelectGroup<MenuItem>>;
type MenuState = SelectState<Menu>;

/// The revision travels through Kit's deferred confirmation itself. An old
/// popup cannot be relabeled as a choice against a newer owner presentation.
#[derive(Clone, PartialEq)]
struct MenuValue {
    revision: u64,
    id: String,
}
#[derive(Clone)]
struct MenuItem {
    choice: Choice,
    value: MenuValue,
}
impl SelectItem for MenuItem {
    type Value = MenuValue;
    fn title(&self) -> SharedString {
        self.choice.title().to_owned().into()
    }
    fn value(&self) -> &Self::Value {
        &self.value
    }
    fn disabled(&self) -> bool {
        !self.choice.available()
    }
}

/// Retain this entity while Settings is open. Its only local state is Kit
/// control/focus state, the immutable owner projection and a synthetic preview.
/// Subscribe to SettingsEvent before displaying it, and synchronously project
/// the owner's next presentation back after every accepted action.
pub struct SettingsView {
    presentation: Presentation,
    application: Entity<MenuState>,
    editor: Entity<MenuState>,
    preview: Entity<EditorState>,
    preview_guard: InputAccessibilityGuard,
    additional_sections: Vec<AnyView>,
    _subscriptions: Vec<Subscription>,
}
impl EventEmitter<SettingsEvent> for SettingsView {}

impl SettingsView {
    pub fn new(presentation: Presentation, window: &mut Window, cx: &mut Context<Self>) -> Self {
        let application = menu_state(
            presentation.application_choices(),
            presentation.application_selection(),
            presentation.revision(),
            window,
            cx,
        );
        let editor = menu_state(
            presentation.editor_choices(),
            presentation.editor_selection(),
            presentation.revision(),
            window,
            cx,
        );
        let application_subscription = cx.subscribe_in(
            &application,
            window,
            |this, state, event: &SelectEvent<Menu>, window, cx| {
                if let SelectEvent::Confirm(Some(value)) = event {
                    // Kit commits its local cursor before emitting Confirm.
                    // Restore the authoritative display until the owner accepts
                    // and projects the action, including stale-event refusal.
                    replace_menu(
                        state,
                        this.presentation.application_choices(),
                        this.presentation.application_selection(),
                        this.presentation.revision(),
                        window,
                        cx,
                    );
                    this.emit_at(
                        value.revision,
                        SettingsAction::ChooseApplication(value.id.clone()),
                        cx,
                    );
                }
            },
        );
        let editor_subscription = cx.subscribe_in(
            &editor,
            window,
            |this, state, event: &SelectEvent<Menu>, window, cx| {
                if let SelectEvent::Confirm(Some(value)) = event {
                    replace_menu(
                        state,
                        this.presentation.editor_choices(),
                        this.presentation.editor_selection(),
                        this.presentation.revision(),
                        window,
                        cx,
                    );
                    this.emit_at(
                        value.revision,
                        SettingsAction::ChooseEditor(value.id.clone()),
                        cx,
                    );
                }
            },
        );
        Self {
            presentation,
            application,
            editor,
            preview: cx
                .new(|cx| crate::controls::sql_editor_state(PREVIEW_SQL.to_owned(), window, cx)),
            preview_guard: InputAccessibilityGuard::default(),
            additional_sections: Vec::new(),
            _subscriptions: vec![application_subscription, editor_subscription],
        }
    }
    pub fn presentation(&self) -> &Presentation {
        &self.presentation
    }
    /// Update value presentation, never recreate any editor/control or mutate
    /// source, selection, scroll, Undo, grid state or a live operation. Changes
    /// to a menu's authority invalidate its pending deferred confirmations.
    /// The owner advances the revision for every changed projection. Delayed
    /// or same-revision conflicting publications are refused without mutation.
    pub fn set_presentation(
        &mut self,
        presentation: Presentation,
        window: &mut Window,
        cx: &mut Context<Self>,
    ) -> bool {
        if presentation.revision() <= self.presentation.revision() {
            return presentation == self.presentation;
        }
        if presentation.revision() != self.presentation.revision()
            || presentation.application_choices() != self.presentation.application_choices()
            || presentation.application_selection() != self.presentation.application_selection()
        {
            replace_menu(
                &self.application,
                presentation.application_choices(),
                presentation.application_selection(),
                presentation.revision(),
                window,
                cx,
            );
        }
        if presentation.revision() != self.presentation.revision()
            || presentation.editor_choices() != self.presentation.editor_choices()
            || presentation.editor_selection() != self.presentation.editor_selection()
        {
            replace_menu(
                &self.editor,
                presentation.editor_choices(),
                presentation.editor_selection(),
                presentation.revision(),
                window,
                cx,
            );
        }
        self.presentation = presentation;
        cx.notify();
        true
    }
    /// Additional independently owned Settings sections can share this scroll
    /// surface/footer. No future library/import/shortcut behavior lives here.
    pub fn set_additional_sections(&mut self, sections: Vec<AnyView>, cx: &mut Context<Self>) {
        self.additional_sections = sections;
        cx.notify();
    }
    /// Focus on opening only. Theme/status updates never steal keyboard focus.
    pub fn focus_application(&self, window: &mut Window, cx: &mut App) {
        self.application.focus_handle(cx).focus(window, cx);
    }
    /// Used by the enclosing dialog's existing Cancel/close path. Dismissing
    /// Settings does not claim a persisted save or authorize window teardown.
    pub fn request_close(&mut self, cx: &mut Context<Self>) {
        self.emit_at(self.presentation.revision(), SettingsAction::Close, cx);
    }
    /// Invalidate before removing this original Settings/modal owner, including
    /// native dialog dismissal. Retained preview text never changes otherwise.
    pub fn invalidate_accessibility(&self) {
        self.preview_guard.invalidate();
    }
    fn emit_at(&mut self, revision: u64, action: SettingsAction, cx: &mut Context<Self>) {
        let event = SettingsEvent { revision, action };
        if self.presentation.accepts(&event) {
            cx.emit(event);
        }
        cx.notify();
    }
}
impl Drop for SettingsView {
    fn drop(&mut self) {
        self.preview_guard.invalidate();
    }
}
impl Focusable for SettingsView {
    fn focus_handle(&self, cx: &App) -> FocusHandle {
        self.application.focus_handle(cx)
    }
}

impl Render for SettingsView {
    fn render(&mut self, _: &mut Window, cx: &mut Context<Self>) -> impl IntoElement {
        let revision = self.presentation.revision();
        let persistence = self.presentation.persistence();
        let application = section(
            "dbeer.settings.application",
            "Application",
            "Choose a native appearance or a color scheme for the application.",
            cx,
        )
        .child(
            div()
                .flex()
                .items_center()
                .gap_4()
                .child(div().w(px(120.)).flex_shrink_0().child("Theme"))
                .child(
                    Select::new(&self.application)
                        .id("appearanceTheme")
                        .accessibility_label("Application theme")
                        .accessibility_id("dbeer.settings.application-theme")
                        .search_placeholder("Find an application theme")
                        .menu_max_h(px(260.))
                        .disabled(!persistence.choices_enabled())
                        .w_full(),
                ),
        );
        let sql_editor = section(
            "dbeer.settings.sql-editor",
            "SQL editor",
            "The application and editor selections are independent. Follow App Appearance uses the application's complete color scheme.",
            cx,
        )
        .child(
            div()
                .flex()
                .items_center()
                .gap_4()
                .child(div().w(px(120.)).flex_shrink_0().child("Color scheme"))
                .child(
                    Select::new(&self.editor)
                        .id("editorColorScheme")
                        .accessibility_label("Editor color scheme")
                        .accessibility_id("dbeer.settings.editor-color-scheme")
                        .search_placeholder("Find an editor color scheme")
                        .menu_max_h(px(260.))
                        .disabled(!persistence.choices_enabled())
                        .w_full(),
                ),
        )
        .child(
            div()
                .text_sm()
                .text_color(cx.theme().muted_foreground)
                .child("Preview"),
        )
        .child(
            div()
                .id("editorThemePreview")
                .h(px(168.))
                .overflow_hidden()
                .border_1()
                .border_color(cx.theme().border)
                .rounded_md()
                .child(
                    Editor::new(&self.preview)
                        .aria_label("Editor color scheme preview, read only")
                        .accessibility_id("dbeer.settings.editor-preview")
                        .accessibility_guard(self.preview_guard.clone())
                        .readonly(true)
                        .bordered(false)
                        .h_full()
                        .editor_style(self.presentation.editor_palette().input_style()),
                ),
        );
        div()
            .id("dbeer-appearance-settings")
            .role(Role::Group)
            .accessibility_id("dbeer.settings.appearance")
            .aria_label("Appearance settings")
            .w_full()
            .min_w_0()
            .flex()
            .flex_col()
            .gap_3()
            .text_color(cx.theme().foreground)
            .bg(cx.theme().background)
            .child(
                div()
                    .id("dbeer-settings-sections")
                    .max_h(px(520.))
                    .overflow_y_scroll()
                    .flex()
                    .flex_col()
                    .gap_3()
                    .child(application)
                    .child(sql_editor)
                    .children(self.additional_sections.iter().cloned()),
            )
            .child(
                div()
                    .id("dbeer-appearance-status")
                    .role(if persistence.error().is_some() {
                        Role::Alert
                    } else {
                        Role::Status
                    })
                    .accessibility_id("dbeer.settings.appearance-status")
                    .aria_label("Appearance settings status")
                    .flex()
                    .flex_col()
                    .gap_1()
                    .text_sm()
                    .child(persistence.summary())
                    .when_some(persistence.error(), |status, error| {
                        status.child(div().text_color(cx.theme().danger).child(error.to_string()))
                    }),
            )
            .child(
                div()
                    .flex()
                    .items_center()
                    .gap_2()
                    .when(persistence.can_retry(), |footer| {
                        footer.child(
                            Button::new("retryAppearanceSave")
                                .label("Retry Saving")
                                .accessibility_id("dbeer.settings.retry-appearance-save")
                                .on_click(cx.listener(move |this, _, _, cx| {
                                    this.emit_at(revision, SettingsAction::RetrySave, cx);
                                })),
                        )
                    })
                    .child(
                        Button::new("reloadAppearance")
                            .label("Reload Saved Settings")
                            .accessibility_label(
                                "Reload saved appearance settings, replacing the current preview",
                            )
                            .accessibility_id("dbeer.settings.reload-appearance")
                            .disabled(!persistence.can_reload())
                            .on_click(cx.listener(move |this, _, _, cx| {
                                this.emit_at(revision, SettingsAction::Reload, cx);
                            })),
                    )
                    .child(div().flex_1())
                    .child(
                        Button::new("closeAppearanceSettings")
                            .primary()
                            .label("Done")
                            .accessibility_id("dbeer.settings.close")
                            .on_click(cx.listener(move |this, _, _, cx| {
                                this.emit_at(revision, SettingsAction::Close, cx);
                            })),
                    ),
            )
    }
}

/// Shared visual section for independently owned future Settings sections.
/// This actual group wrapper provides section semantics, not selector identity.
pub fn section(
    id: &'static str,
    title: &'static str,
    description: &'static str,
    cx: &App,
) -> Stateful<Div> {
    div()
        .id(id)
        .role(Role::Group)
        .accessibility_id(id)
        .aria_label(title)
        .flex()
        .flex_col()
        .gap_3()
        .p_4()
        .border_1()
        .border_color(cx.theme().border)
        .rounded_md()
        .child(div().font_weight(FontWeight::SEMIBOLD).child(title))
        .child(
            div()
                .text_sm()
                .text_color(cx.theme().muted_foreground)
                .child(description),
        )
}

fn menu_items(choices: &[Choice], revision: u64) -> Menu {
    let groups = [
        (ChoiceGroup::Native, "Native appearance"),
        (ChoiceGroup::FollowApplication, "Application appearance"),
        (ChoiceGroup::Schemes, "Color schemes"),
        (ChoiceGroup::Unavailable, "Unavailable saved choice"),
    ]
    .into_iter()
    .filter_map(|(group, title)| {
        let items = choices
            .iter()
            .filter(|choice| choice.group == group)
            .map(|choice| MenuItem {
                choice: choice.clone(),
                value: MenuValue {
                    revision,
                    id: choice.id().to_owned(),
                },
            })
            .collect::<Vec<_>>();
        (!items.is_empty()).then(|| SelectGroup::new(title).items(items))
    })
    .collect::<Vec<_>>();
    SearchableVec::new(groups)
}
fn selected_index(choices: &[Choice], id: &str) -> Option<IndexPath> {
    let mut section = 0;
    for group in [
        ChoiceGroup::Native,
        ChoiceGroup::FollowApplication,
        ChoiceGroup::Schemes,
        ChoiceGroup::Unavailable,
    ] {
        let members = choices.iter().filter(|choice| choice.group == group);
        let mut count = 0;
        for (row, choice) in members.enumerate() {
            count += 1;
            if choice.id() == id {
                return Some(IndexPath::default().section(section).row(row));
            }
        }
        if count != 0 {
            section += 1;
        }
    }
    None
}
fn menu_state(
    choices: &[Choice],
    selected: &str,
    revision: u64,
    window: &mut Window,
    cx: &mut App,
) -> Entity<MenuState> {
    cx.new(|cx| {
        SelectState::new(
            menu_items(choices, revision),
            selected_index(choices, selected),
            window,
            cx,
        )
        .searchable(true)
    })
}
fn replace_menu(
    state: &Entity<MenuState>,
    choices: &[Choice],
    selected: &str,
    revision: u64,
    window: &mut Window,
    cx: &mut App,
) {
    state.update(cx, |state, cx| {
        state.set_items(menu_items(choices, revision), window, cx);
        state.set_selected_value(
            &MenuValue {
                revision,
                id: selected.to_owned(),
            },
            window,
            cx,
        );
        cx.notify();
    });
}

#[cfg(all(test, feature = "native-smoke"))]
#[path = "native_tests.rs"]
mod native_tests;
