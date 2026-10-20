use super::model::{Action, Edit, Event, Presentation, RecordingToken, Scope, State};
use crate::shortcuts::{CaptureOutcome, ConfigurableCommand, Evidence, InputSafety};
use gpui_kit::{
    base::Disableable,
    component::{
        ActiveTheme,
        button::Button,
        input::{IndentInline, Input, InputAccessibilityGuard, InputState, OutdentInline},
    },
    prelude::FluentBuilder,
    *,
};

struct RecorderInput {
    command: ConfigurableCommand,
    input: Entity<InputState>,
    guard: InputAccessibilityGuard,
}

/// One retained section per original Settings/modal owner. No store, helper,
/// database, command dispatch or live mutable preference authority enters it.
pub struct ShortcutSettingsView {
    state: State,
    inputs: Vec<RecorderInput>,
    blur: Option<Subscription>,
    _activation: Subscription,
}
impl EventEmitter<Event> for ShortcutSettingsView {}
impl ShortcutSettingsView {
    pub fn new(presentation: Presentation, window: &mut Window, cx: &mut Context<Self>) -> Self {
        let inputs = ConfigurableCommand::ALL
            .into_iter()
            .map(|command| RecorderInput {
                command,
                input: cx
                    .new(|cx| InputState::new(window, cx).placeholder("Choose Record to begin")),
                guard: InputAccessibilityGuard::default(),
            })
            .collect();
        let activation = cx.observe_window_activation(window, |this, window, cx| {
            if !window.is_window_active() {
                if let Some(token) = this.state.token() {
                    this.focus_lost(token, window, cx);
                }
                if let Some(event) = this.state.pending.as_ref()
                    && let Action::Edit(Edit::Bind(command, _)) = &event.action
                {
                    this.focus_lost(
                        RecordingToken {
                            scope: event.scope,
                            command: *command,
                        },
                        window,
                        cx,
                    );
                }
            }
        });
        Self {
            state: State::new(presentation),
            inputs,
            blur: None,
            _activation: activation,
        }
    }
    pub fn presentation(&self) -> &Presentation {
        &self.state.presentation
    }
    /// The owner must also recheck the original retained Settings entity/modal
    /// and current base revision. This rejects a queued event after replacement,
    /// focus loss, dismissal or a newer local recording/request.
    pub fn event_is_current(&self, event: &Event, window: &Window, cx: &App) -> bool {
        self.state.event_is_current(event)
            && match &event.action {
                Action::Edit(Edit::Bind(command, _)) => {
                    self.input(*command).focus_handle(cx).is_focused(window)
                }
                _ => true,
            }
    }
    pub fn set_presentation(
        &mut self,
        presentation: Presentation,
        window: &mut Window,
        cx: &mut Context<Self>,
    ) -> bool {
        let old_revision = self.state.presentation.revision();
        if !self.state.set_presentation(presentation) {
            return false;
        }
        if old_revision != self.state.presentation.revision() {
            self.blur = None;
            self.sync_inputs(window, cx);
        }
        cx.notify();
        true
    }
    /// Call synchronously before Settings close/replacement, including native
    /// dialog dismissal. Drop also invalidates the original semantic guards.
    pub fn dismiss(&mut self, window: &mut Window, cx: &mut Context<Self>) {
        self.state.dismiss();
        self.blur = None;
        self.sync_inputs(window, cx);
        for row in &self.inputs {
            row.guard.invalidate();
        }
        cx.notify();
    }
    pub fn focus_first(&self, window: &mut Window, cx: &mut App) {
        self.inputs[0].input.focus_handle(cx).focus(window, cx);
    }
    fn input(&self, command: ConfigurableCommand) -> Entity<InputState> {
        self.inputs
            .iter()
            .find(|row| row.command == command)
            .unwrap()
            .input
            .clone()
    }
    fn sync_inputs(&self, window: &mut Window, cx: &mut App) {
        for row in &self.inputs {
            let active = self
                .state
                .token()
                .is_some_and(|token| token.command == row.command);
            row.input.update(cx, |input, cx| {
                input.set_readonly(!active, cx);
                input.set_placeholder(
                    if active {
                        "Press a shortcut; Escape cancels"
                    } else {
                        "Choose Record to begin"
                    },
                    window,
                    cx,
                );
                // Scratch typing belongs to this real input, never a mapping.
                // Do not destroy native marked text while an IME owns it.
                if !active
                    && input.marked_text_range(window, cx).is_none()
                    && !input.value().is_empty()
                {
                    input.set_value("", window, cx);
                }
            });
        }
    }
    fn begin(
        &mut self,
        scope: Scope,
        command: ConfigurableCommand,
        window: &mut Window,
        cx: &mut Context<Self>,
    ) {
        if !self.state.current(scope) || !self.state.editable() {
            return;
        }
        let input = self.input(command);
        // Never clear or impersonate an already composing original input.
        if input.update(cx, |input, cx| {
            input.marked_text_range(window, cx).is_some()
        }) {
            return;
        }
        let focus = input.focus_handle(cx);
        focus.focus(window, cx);
        let Some(token) = self.state.begin(scope, command, focus.is_focused(window)) else {
            return;
        };
        input.update(cx, |input, cx| input.set_value("", window, cx));
        self.blur = Some(cx.on_blur(&focus, window, move |this, window, cx| {
            this.focus_lost(token, window, cx);
        }));
        self.sync_inputs(window, cx);
        cx.notify();
    }
    fn cancel(&mut self, token: RecordingToken, window: &mut Window, cx: &mut Context<Self>) {
        if self.state.token() != Some(token) {
            return;
        }
        self.state.cancel(token);
        self.blur = None;
        self.sync_inputs(window, cx);
        cx.notify();
    }
    fn focus_lost(&mut self, token: RecordingToken, window: &mut Window, cx: &mut Context<Self>) {
        self.state.focus_lost(token);
        // An old blur must not discard a newer recorder's subscription.
        if self.state.token().is_none() && self.state.pending.is_none() {
            self.blur = None;
            self.sync_inputs(window, cx);
        }
        cx.notify();
    }
    fn request(
        &mut self,
        scope: Scope,
        action: Action,
        window: &mut Window,
        cx: &mut Context<Self>,
    ) {
        if let Some(event) = self.state.request(scope, action) {
            self.blur = None;
            self.sync_inputs(window, cx);
            cx.emit(event);
        }
        cx.notify();
    }
    // GPUI dispatches matching Input actions before its low-level KeyDown
    // listeners. Capture only the recorder's Tab actions; these grant no bind
    // or persistence authority and must preserve the original composing input.
    fn capture_traversal(
        &mut self,
        token: RecordingToken,
        reverse: bool,
        window: &mut Window,
        cx: &mut Context<Self>,
    ) {
        if self.state.token() != Some(token) || !self.state.current(token.scope) {
            return;
        }
        let input = self.input(token.command);
        if !input.focus_handle(cx).is_focused(window)
            || input.update(cx, |input, cx| {
                input.marked_text_range(window, cx).is_some()
            })
        {
            return;
        }
        self.cancel(token, window, cx);
        self.traverse_focus(reverse, window, cx);
    }
    fn traverse_focus(&self, reverse: bool, window: &mut Window, cx: &mut Context<Self>) {
        if reverse {
            window.focus_prev(cx);
        } else {
            window.focus_next(cx);
        }
        window.prevent_default();
        cx.stop_propagation();
    }

    /// Runs synchronously inside the original focused control's native KeyDown
    /// dispatch. Linux scoped evidence is read here, never cached or awaited.
    fn capture(
        &mut self,
        token: RecordingToken,
        event: &KeyDownEvent,
        window: &mut Window,
        cx: &mut Context<Self>,
    ) {
        if self.state.token() != Some(token) || !self.state.current(token.scope) {
            return;
        }
        let input = self.input(token.command);
        let focused = input.focus_handle(cx).is_focused(window);
        let marked = input.update(cx, |input, cx| {
            if input.marked_text_range(window, cx).is_some() {
                Evidence::Active
            } else {
                Evidence::Clear
            }
        });
        let safety = InputSafety::from_gpui(event, marked);
        let (outcome, emitted) = self.state.capture(token, focused, event, safety);
        if self.state.token().is_none() {
            if self.state.pending.is_none() {
                self.blur = None;
            }
            self.sync_inputs(window, cx);
        }
        if let Some(event) = emitted {
            cx.emit(event);
        }
        match outcome {
            CaptureOutcome::Traverse { reverse } => {
                // Use the real rendered tab-stop graph, including controls in
                // adjacent Settings sections. Do not let Input insert a tab or
                // a second default handler traverse twice.
                self.traverse_focus(reverse, window, cx);
            }
            outcome if outcome.consume() => {
                window.prevent_default();
                cx.stop_propagation();
            }
            _ => {}
        }
        cx.notify();
    }
}
impl Drop for ShortcutSettingsView {
    fn drop(&mut self) {
        self.state.dismiss();
        for row in &self.inputs {
            row.guard.invalidate();
        }
    }
}
impl Focusable for ShortcutSettingsView {
    fn focus_handle(&self, cx: &App) -> FocusHandle {
        self.inputs[0].input.focus_handle(cx)
    }
}
impl Render for ShortcutSettingsView {
    fn render(&mut self, _: &mut Window, cx: &mut Context<Self>) -> impl IntoElement {
        let scope = self.state.scope();
        let persistence = self.state.presentation.persistence();
        let editable = self.state.editable();
        let idle = self.state.pending.is_none() && self.state.current(scope);
        let rows = self.state.presentation.rows().enumerate().map(|(index, row)| {
            let command = row.command;
            let recorder = &self.inputs[index];
            let token = self.state.token().filter(|token| token.command == command);
            let recording = token.is_some();
            div().id(("shortcut-row", index)).role(Role::Group)
                .accessibility_id(format!("dbeer.settings.shortcuts.row.{index}"))
                .aria_label(format!("{} shortcut", row.title()))
                .flex().flex_col().gap_2().py_2()
                .child(div().flex().items_center().gap_2()
                    .child(div().flex_1().flex().flex_col().gap_1()
                        .child(div().font_weight(FontWeight::SEMIBOLD).child(row.title()))
                        .child(div().text_sm().child(format!("{} ({})", row.current_label(), row.source.label())))
                        .child(div().text_sm().text_color(cx.theme().muted_foreground).child(format!("Default: {}", row.default_label()))))
                    .child(Button::new(("record-shortcut", index)).label(if recording { "Cancel Recording" } else { "Record / Rebind" })
                        .accessibility_label(if recording { format!("Cancel recording shortcut for {}", row.title()) } else { format!("Record or rebind shortcut for {}", row.title()) })
                        .accessibility_id(format!("dbeer.settings.shortcuts.record.{index}"))
                        .disabled(!editable)
                        .on_click(cx.listener(move |this, _, window, cx| {
                            if let Some(token) = token { this.cancel(token, window, cx); }
                            else { this.begin(scope, command, window, cx); }
                        })))
                    .child(Button::new(("clear-shortcut", index)).label("Clear")
                        .accessibility_label(format!("Clear shortcut for {}", row.title()))
                        .accessibility_id(format!("dbeer.settings.shortcuts.clear.{index}"))
                        .disabled(!editable || row.current.is_none())
                        .on_click(cx.listener(move |this, _, window, cx| this.request(scope, Action::Edit(Edit::Clear(command)), window, cx))))
                    .child(Button::new(("restore-shortcut", index)).label("Restore Default")
                        .accessibility_label(format!("Restore default shortcut for {}", row.title()))
                        .accessibility_id(format!("dbeer.settings.shortcuts.restore.{index}"))
                        .disabled(!editable || !row.has_override)
                        .on_click(cx.listener(move |this, _, window, cx| this.request(scope, Action::Edit(Edit::RestoreDefault(command)), window, cx)))))
                .child(div().flex().items_center().gap_2()
                    .child(div().flex_1().capture_key_down(cx.listener(move |this, event, window, cx| {
                        if let Some(token) = token { this.capture(token, event, window, cx); }
                    }))
                    .capture_action(cx.listener(move |this, _: &IndentInline, window, cx| {
                        if let Some(token) = token { this.capture_traversal(token, false, window, cx); }
                    }))
                    .capture_action(cx.listener(move |this, _: &OutdentInline, window, cx| {
                        if let Some(token) = token { this.capture_traversal(token, true, window, cx); }
                    }))
                    .child(Input::new(&recorder.input)
                        .aria_label(format!("Shortcut recorder for {}. Current: {} ({}). Default: {}. {}", row.title(), row.current_label(), row.source.label(), row.default_label(), if recording { "Recording. Press a shortcut; Escape cancels; Tab moves focus." } else { "Choose Record to begin." }))
                        .accessibility_id(format!("dbeer.settings.shortcuts.recorder.{index}"))
                        .accessibility_guard(recorder.guard.clone())
                        .readonly(!recording))))
                .when_some(self.state.error.filter(|(owner, _)| *owner == Some(command)), |row, (_, error)| row.child(
                    div().id(("shortcut-error", index)).role(Role::Alert).accessibility_id(format!("dbeer.settings.shortcuts.error.{index}"))
                        .text_sm().text_color(cx.theme().danger).child(error.to_string())))
        }).collect::<Vec<_>>();
        crate::settings_view::section(
            "dbeer.settings.shortcuts", "Query shortcuts",
            "Choose Record, then press a shortcut in the focused recorder. Escape cancels; Tab moves to the next control. Native editing, input methods, AltGr and operating system shortcuts stay available.", cx,
        ).children(rows)
            .child(div().id("shortcut-status").role(if persistence.error().is_some() { Role::Alert } else { Role::Status })
                .accessibility_id("dbeer.settings.shortcuts.status").aria_label("Shortcut settings status")
                .flex().flex_col().gap_1().text_sm()
                .child(if self.state.pending.is_some() { "Waiting for shortcut settings to update..." } else { persistence.summary() })
                .when_some(persistence.error(), |status, error| status.child(div().text_color(cx.theme().danger).child(error.to_string())))
                .when_some(self.state.error.filter(|(owner, _)| owner.is_none()), |status, (_, error)| status.child(div().text_color(cx.theme().danger).child(error.to_string()))))
            .child(div().flex().flex_wrap().items_center().gap_2()
                .child(Button::new("reset-all-shortcuts").label("Restore All Defaults")
                    .accessibility_id("dbeer.settings.shortcuts.reset-all")
                    .disabled(!editable)
                    .on_click(cx.listener(move |this, _, window, cx| this.request(scope, Action::Edit(Edit::ResetAll), window, cx))))
                .when(persistence.can_retry(), |footer| footer.child(Button::new("retry-shortcuts").label("Retry Saving")
                    .accessibility_id("dbeer.settings.shortcuts.retry")
                    .disabled(!idle)
                    .on_click(cx.listener(move |this, _, window, cx| this.request(scope, Action::RetrySave, window, cx)))))
                .child(Button::new("reload-shortcuts").label("Reload Saved Shortcuts")
                    .accessibility_label("Reload saved shortcuts, replacing current mappings")
                    .accessibility_id("dbeer.settings.shortcuts.reload")
                    .disabled(!idle || !persistence.can_reload())
                    .on_click(cx.listener(move |this, _, window, cx| this.request(scope, Action::Reload, window, cx))))
                .when(persistence.can_recover(), |footer| footer.child(Button::new("recover-shortcuts").label("Recover Defaults")
                    .accessibility_label("Recover default shortcuts after preserving original preferences in a private recovery file")
                    .accessibility_id("dbeer.settings.shortcuts.recover")
                    .disabled(!idle)
                    .on_click(cx.listener(move |this, _, window, cx| this.request(scope, Action::RecoverDefaults, window, cx))))))
    }
}

#[cfg(all(test, feature = "native-smoke"))]
#[path = "native_tests.rs"]
mod native_tests;

// Drivers for the prepared integrated headless cases use the same retained
// input/request path; they add no rendered control or runtime shortcut route.
#[cfg(all(test, feature = "native-smoke"))]
impl ShortcutSettingsView {
    pub(crate) fn test_request(
        &mut self,
        action: Action,
        window: &mut Window,
        cx: &mut Context<Self>,
    ) -> Option<Event> {
        self.request(self.state.scope(), action, window, cx);
        self.state.pending.clone()
    }
    pub(crate) fn test_record(
        &mut self,
        command: ConfigurableCommand,
        window: &mut Window,
        cx: &mut Context<Self>,
    ) -> Entity<InputState> {
        self.begin(self.state.scope(), command, window, cx);
        self.input(command)
    }
}
