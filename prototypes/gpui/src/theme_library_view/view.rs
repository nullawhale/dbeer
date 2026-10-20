use super::{
    PREVIEW_SQL,
    model::{ImportMode, LibraryAccess, LibraryAction, LibraryEvent, Presentation, Workflow},
};
use gpui_kit::{
    base::Disableable,
    component::{
        ActiveTheme, IndexPath,
        button::{Button, ButtonVariants},
        input::{Editor, EditorState, InputAccessibilityGuard},
        select::{SearchableVec, Select, SelectEvent, SelectItem, SelectState},
    },
    prelude::FluentBuilder,
    *,
};

type Menu = SearchableVec<MenuItem>;
type MenuState = SelectState<Menu>;

#[derive(Clone, PartialEq)]
struct MenuValue {
    revision: u64,
    id: String,
}
#[derive(Clone)]
struct MenuItem {
    title: String,
    value: MenuValue,
}
impl SelectItem for MenuItem {
    type Value = MenuValue;
    fn title(&self) -> SharedString {
        self.title.clone().into()
    }
    fn value(&self) -> &Self::Value {
        &self.value
    }
}

/// Mount this retained entity through SettingsView::set_additional_sections.
/// Subscribe before display. Every event requires the original Settings/modal
/// owner AND Presentation::accepts to still match in the integration callback.
pub struct ThemeLibraryView {
    presentation: Presentation,
    browse: Entity<MenuState>,
    preview: Entity<EditorState>,
    preview_guard: InputAccessibilityGuard,
    active: bool,
    _subscription: Subscription,
}
impl EventEmitter<LibraryEvent> for ThemeLibraryView {}

impl ThemeLibraryView {
    pub fn new(presentation: Presentation, window: &mut Window, cx: &mut Context<Self>) -> Self {
        let browse = cx.new(|cx| {
            SelectState::new(
                menu_items(&presentation),
                selected_index(&presentation),
                window,
                cx,
            )
            .searchable(true)
        });
        let subscription = cx.subscribe_in(
            &browse,
            window,
            |this, state, event: &SelectEvent<Menu>, window, cx| {
                if let SelectEvent::Confirm(Some(value)) = event {
                    // Kit tentatively commits before deferred Confirm. Always
                    // restore the owner's display, even for a rejected old menu.
                    replace_menu(state, &this.presentation, window, cx);
                    this.emit_at(value.revision, LibraryAction::Browse(value.id.clone()), cx);
                }
            },
        );
        Self {
            presentation,
            browse,
            preview: cx
                .new(|cx| crate::controls::sql_editor_state(PREVIEW_SQL.to_owned(), window, cx)),
            preview_guard: InputAccessibilityGuard::default(),
            active: true,
            _subscription: subscription,
        }
    }
    pub fn presentation(&self) -> &Presentation {
        &self.presentation
    }
    /// Higher revisions update only value presentation. The original menu,
    /// EditorState, text, caret, selection, scroll, Undo and focus survive.
    pub fn set_presentation(
        &mut self,
        presentation: Presentation,
        window: &mut Window,
        cx: &mut Context<Self>,
    ) -> bool {
        if !self.active {
            return false;
        }
        if presentation.revision() <= self.presentation.revision() {
            return presentation == self.presentation;
        }
        replace_menu(&self.browse, &presentation, window, cx);
        self.presentation = presentation;
        cx.notify();
        true
    }
    /// Initial section focus only. A preview, save status or palette update
    /// must never steal focus from the original editor/menu/native chooser.
    #[allow(dead_code)] // Deliberate native focus seam; live refresh never steals focus.
    pub fn focus_browse(&self, window: &mut Window, cx: &mut App) {
        if self.active {
            self.browse.focus_handle(cx).focus(window, cx);
        }
    }
    /// Route the enclosing import review's Cancel/Escape through the same typed
    /// event. Capture ALL arguments when installing the original modal handler;
    /// an old handler cannot recapture the current workflow as its own request.
    pub fn request_cancel_import(
        &mut self,
        revision: u64,
        request: super::ImportRequest,
        preview: Option<super::PreviewToken>,
        cx: &mut Context<Self>,
    ) {
        self.emit_at(
            revision,
            LibraryAction::CancelImport { request, preview },
            cx,
        );
    }
    /// Invalidate BEFORE removing the original Settings/modal owner. Workers
    /// belong to that owner; dropping this view does not authorize their result.
    pub fn invalidate(&mut self, cx: &mut Context<Self>) {
        self.active = false;
        self.preview_guard.invalidate();
        cx.notify();
    }
    fn emit_at(&mut self, revision: u64, action: LibraryAction, cx: &mut Context<Self>) {
        let event = LibraryEvent { revision, action };
        if self.active && self.presentation.accepts(&event) {
            cx.emit(event);
        }
        cx.notify();
    }
    fn action_button(
        &self,
        id: &'static str,
        label: &'static str,
        accessible_name: &'static str,
        action: LibraryAction,
        cx: &mut Context<Self>,
    ) -> Button {
        let revision = self.presentation.revision();
        let enabled = self.active
            && self.presentation.accepts(&LibraryEvent {
                revision,
                action: action.clone(),
            });
        Button::new(id)
            .label(label)
            .accessibility_id(id)
            .accessibility_label(accessible_name)
            .disabled(!enabled)
            .on_click(cx.listener(move |this, _, _, cx| {
                this.emit_at(revision, action.clone(), cx);
            }))
    }
}
impl Drop for ThemeLibraryView {
    fn drop(&mut self) {
        self.preview_guard.invalidate();
    }
}
impl Focusable for ThemeLibraryView {
    fn focus_handle(&self, cx: &App) -> FocusHandle {
        self.browse.focus_handle(cx)
    }
}

impl Render for ThemeLibraryView {
    fn render(&mut self, _: &mut Window, cx: &mut Context<Self>) -> impl IntoElement {
        let workflow = self.presentation.workflow().clone();
        let theme = self.presentation.preview_theme();
        let title = theme.name.clone();
        let detail = format!(
            "{} appearance, {} colors, {} syntax rules",
            if theme.appearance.is_dark() {
                "Dark"
            } else {
                "Light"
            },
            theme.colors.len(),
            theme.token_rules.len()
        );
        let is_review = workflow.review().is_some();
        let mut buttons = div().flex().items_center().flex_wrap().gap_2();
        if self.presentation.access().can_import(ImportMode::Standard) {
            buttons = buttons.child(self.action_button(
                "dbeer.settings.themes.import",
                "Import Theme...",
                "Choose a theme file to preview before importing",
                LibraryAction::RequestImport,
                cx,
            ));
        }
        if self.presentation.access().can_import(ImportMode::Recovery) {
            buttons = buttons.child(self.action_button(
                "dbeer.settings.themes.recover", "Recover Library and Import...",
                "Choose a theme for explicit library recovery, preserving the unreadable library first",
                LibraryAction::RequestRecoveryImport, cx));
        }
        if let Some(theme) = self.presentation.browsed_theme().filter(|_| !is_review) {
            let id = theme.id.clone();
            buttons = buttons.child(self.action_button(
                "dbeer.settings.themes.remove",
                "Remove Theme",
                "Remove the previewed imported theme from the saved library",
                LibraryAction::Remove(id),
                cx,
            ));
        }
        if let Workflow::Review(review) = &workflow {
            let recovery = review.token().request().mode() == ImportMode::Recovery;
            buttons = buttons.child(
                self.action_button(
                    "dbeer.settings.themes.commit",
                    if recovery {
                        "Preserve Library and Import"
                    } else {
                        "Import Theme"
                    },
                    if recovery {
                        "Preserve the unreadable library and save this imported theme"
                    } else {
                        "Save this theme and select it for the SQL editor"
                    },
                    LibraryAction::CommitImport(review.token()),
                    cx,
                )
                .primary(),
            );
        }
        let retry = match &workflow {
            Workflow::ImportFailed { request, .. } => {
                Some(("Retry Selected File", LibraryAction::RetryImport(*request)))
            }
            Workflow::ImportSaveFailed { review, .. } => Some((
                "Retry Saving Import",
                LibraryAction::RetryImportSave(review.token()),
            )),
            Workflow::RemoveFailed { request, .. } => Some((
                "Retry Removing Theme",
                LibraryAction::RetryRemove(request.clone()),
            )),
            _ => None,
        };
        if let Some((label, action)) = retry.filter(|(_, action)| {
            self.presentation.accepts(&LibraryEvent {
                revision: self.presentation.revision(),
                action: action.clone(),
            })
        }) {
            buttons = buttons.child(self.action_button(
                "dbeer.settings.themes.retry",
                label,
                label,
                action,
                cx,
            ));
        }
        if let Some(action) = self.presentation.cancel_action() {
            buttons = buttons.child(self.action_button(
                "dbeer.settings.themes.cancel",
                "Cancel Import",
                "Cancel the original import and discard its uncommitted preview",
                action,
                cx,
            ));
        }
        buttons = buttons.child(self.action_button(
            "dbeer.settings.themes.reload",
            "Reload Saved Library",
            "Reload the saved theme library, canceling any uncommitted import preview",
            LibraryAction::Reload,
            cx,
        ));

        crate::settings_view::section(
            "dbeer.settings.theme-library", "Theme library",
            "Import VS Code (.json, .jsonc), TextMate (.tmTheme, .plist) or JetBrains (.icls) schemes for both theme menus. Application and editor selections remain independent.", cx,
        )
        .child(div().flex().items_center().gap_4()
            .child(div().w(px(120.)).flex_shrink_0().child("Browse schemes"))
            .child(Select::new(&self.browse).id("themeLibraryScheme")
                .accessibility_id("dbeer.settings.theme-library-scheme")
                .accessibility_label("Theme library preview scheme")
                .search_placeholder("Find a library theme").menu_max_h(px(260.))
                .disabled(!self.active || !self.presentation.can_browse()).w_full()))
        .child(div().id("theme-preview-description").role(Role::Group).accessibility_id("dbeer.settings.themes.preview-description")
            .aria_label(if is_review { "Uncommitted imported theme preview" } else { "Library theme preview" })
            .flex().flex_col().gap_1().child(div().font_weight(FontWeight::SEMIBOLD).child(title))
            .child(div().text_sm().text_color(cx.theme().muted_foreground).child(detail)))
        .child(div().id("themeLibraryPreview").h(px(168.)).overflow_hidden().border_1()
            .border_color(cx.theme().border).rounded_md()
            .child(Editor::new(&self.preview).aria_label("Theme library SQL preview, read only")
                .accessibility_id("dbeer.settings.themes.editor-preview")
                .accessibility_guard(self.preview_guard.clone()).readonly(true).bordered(false).h_full()
                .editor_style(self.presentation.editor_palette().input_style())))
        .child(div().id("theme-library-status").role(if self.presentation.error().is_some() { Role::Alert } else { Role::Status })
            .accessibility_id("dbeer.settings.themes.status").aria_label("Theme library status")
            .flex().flex_col().gap_1().text_sm().child(workflow.summary())
            .when(self.presentation.access() == LibraryAccess::PreviewOnly, |status| {
                status.child("This disposable workspace previews bundled schemes only. No personal theme library is changed.")
            })
            .when(matches!(self.presentation.access(), LibraryAccess::ReadOnly { .. }), |status| {
                status.child("The saved library is read only. Browsing does not change it. Reload after repair, or explicitly recover with an import when offered.")
            })
            .when(workflow.import_request().is_some_and(|request| request.mode() == ImportMode::Recovery), |status| {
                status.child("Recovery import requires preserving the unreadable library in a separate recovery copy before replacing it.")
            })
            .when_some(self.presentation.error(), |status, error| {
                status.child(div().text_color(cx.theme().danger).child(error.to_string()))
            }))
        .child(buttons)
    }
}

fn menu_items(presentation: &Presentation) -> Menu {
    SearchableVec::new(
        presentation
            .themes()
            .iter()
            .map(|theme| MenuItem {
                title: if theme.is_imported {
                    format!("{} (Imported)", theme.name)
                } else {
                    theme.name.clone()
                },
                value: MenuValue {
                    revision: presentation.revision(),
                    id: theme.id.clone(),
                },
            })
            .collect::<Vec<_>>(),
    )
}
fn selected_index(presentation: &Presentation) -> Option<IndexPath> {
    presentation
        .themes()
        .iter()
        .position(|theme| Some(theme.id.as_str()) == presentation.browsed_id())
        .map(IndexPath::new)
}
fn replace_menu(
    state: &Entity<MenuState>,
    presentation: &Presentation,
    window: &mut Window,
    cx: &mut App,
) {
    state.update(cx, |state, cx| {
        state.set_items(menu_items(presentation), window, cx);
        if let Some(id) = presentation.browsed_id() {
            state.set_selected_value(
                &MenuValue {
                    revision: presentation.revision(),
                    id: id.into(),
                },
                window,
                cx,
            );
        } else {
            state.set_selected_index(None, window, cx);
        }
        cx.notify();
    });
}

#[cfg(all(test, feature = "native-smoke"))]
#[path = "native_tests.rs"]
mod native_tests;
