//! Prepared cases; execution is deferred until final plan integration.
use super::model::*;
use crate::shortcuts::{
    CaptureOutcome, ConfigurableCommand as Command, Evidence, InputSafety, Modifiers,
    NativePlatform, Preferences, Shortcut, StoreError, ValidationError,
};
use gpui_kit::KeyDownEvent;
use serde::Deserialize;

const CLEAR: InputSafety = InputSafety {
    marked_text: Evidence::Clear,
    dead_key: Evidence::Clear,
};
fn presentation(
    revision: u64,
    preferences: &Preferences,
    persistence: PersistenceState,
) -> Presentation {
    Presentation::new(revision, preferences, NativePlatform::Windows, persistence).unwrap()
}
fn state() -> State {
    State::new(presentation(
        7,
        &Preferences::default(),
        PersistenceState::Saved,
    ))
}
fn ctrl(key: &str) -> Shortcut {
    Shortcut::new(
        key,
        Modifiers {
            control: true,
            ..Modifiers::default()
        },
    )
}
fn event(key: &str) -> KeyDownEvent {
    KeyDownEvent {
        keystroke: ctrl(key).keystroke(),
        is_held: false,
        prefer_character_input: false,
    }
}
fn begin(state: &mut State) -> RecordingToken {
    state
        .begin(state.scope(), Command::RunCurrent, true)
        .unwrap()
}

#[test]
fn row_labels_follow_the_actual_preferences_and_registry_defaults_on_each_platform() {
    for platform in [
        NativePlatform::Windows,
        NativePlatform::Linux,
        NativePlatform::MacDevelopment,
    ] {
        let defaults = Preferences::default();
        let view = Presentation::new(1, &defaults, platform, PersistenceState::Saved).unwrap();
        let rows = view.rows().collect::<Vec<_>>();
        assert_eq!(rows.len(), Command::ALL.len());
        for (row, command) in rows.iter().zip(Command::ALL) {
            assert_eq!(row.command, command);
            assert_eq!(row.title(), command.title());
            assert_eq!(row.current, defaults.menu_label(command, platform));
            assert_eq!(row.default, defaults.menu_label(command, platform));
            assert_eq!(row.source, MappingSource::Default);
        }
        let cleared = view.candidate(&Edit::Clear(Command::RunCurrent)).unwrap();
        let cleared_view =
            Presentation::new(2, &cleared, platform, PersistenceState::Saved).unwrap();
        let row = cleared_view.rows().next().unwrap();
        assert_eq!(row.source, MappingSource::Unbound);
        assert_eq!(row.current_label(), "Unbound");
        assert!(row.has_override);
        assert_eq!(view.rows().next().unwrap().source, MappingSource::Default);
        let restored = cleared_view
            .candidate(&Edit::RestoreDefault(Command::RunCurrent))
            .unwrap();
        assert_eq!(restored, defaults);
    }
}

#[test]
fn candidates_are_temporary_and_conflicting_restore_does_not_relabel_any_row() {
    let base = Preferences::default();
    let model = presentation(1, &base, PersistenceState::Saved);
    let mut preferences = model.candidate(&Edit::Clear(Command::RunCurrent)).unwrap();
    preferences
        .set(
            Command::Stop,
            crate::shortcuts::BindingChoice::Bound(ctrl("enter")),
            NativePlatform::Windows,
        )
        .unwrap();
    let mut state = State::new(presentation(2, &preferences, PersistenceState::Saved));
    let before = state.presentation.clone();
    assert!(
        state
            .request(
                state.scope(),
                Action::Edit(Edit::RestoreDefault(Command::RunCurrent))
            )
            .is_none()
    );
    assert_eq!(
        state.error,
        Some((Some(Command::RunCurrent), ValidationError::Conflict))
    );
    assert_eq!(state.presentation, before);
    assert_eq!(state.presentation.candidate(&Edit::ResetAll).unwrap(), base);
    let request = state
        .request(state.scope(), Action::Edit(Edit::Clear(Command::Stop)))
        .unwrap();
    assert_eq!(state.presentation, before);
    assert!(state.event_is_current(&request));
    assert!(
        state
            .request(request.scope, Action::Edit(Edit::ResetAll))
            .is_none()
    );
}

#[test]
fn actual_recording_core_emits_original_revision_epoch_without_committing_its_clone() {
    let mut state = state();
    let original = state.presentation.clone();
    let token = begin(&mut state);
    let (outcome, request) = state.capture(token, true, &event("f8"), CLEAR);
    assert_eq!(outcome, CaptureOutcome::Bound);
    let request = request.unwrap();
    assert_eq!(request.scope, token.scope);
    assert_eq!(
        request.action,
        Action::Edit(Edit::Bind(Command::RunCurrent, ctrl("f8")))
    );
    assert_eq!(state.presentation, original);
    assert!(state.token().is_none());
    assert!(state.event_is_current(&request));
    state.focus_lost(token);
    assert!(!state.event_is_current(&request));
    // Focus return cannot revive a queued capture or an obsolete key callback.
    let newer = begin(&mut state);
    assert_ne!(newer.scope.epoch, token.scope.epoch);
    assert_eq!(
        state.capture(token, true, &event("f9"), CLEAR).0,
        CaptureOutcome::Inactive
    );
    assert_eq!(state.token(), Some(newer));
}

#[test]
fn blur_replacement_close_and_new_presentation_reject_stale_callbacks() {
    let mut state = state();
    let old_scope = state.scope();
    assert!(state.begin(old_scope, Command::RunCurrent, false).is_none());
    let first = begin(&mut state);
    state.cancel(first);
    let second = begin(&mut state);
    state.focus_lost(first);
    assert_eq!(state.token(), Some(second));
    assert!(
        state
            .request(old_scope, Action::Edit(Edit::Clear(Command::RunCurrent)))
            .is_none()
    );
    assert_eq!(
        state.capture(second, false, &event("f8"), CLEAR).0,
        CaptureOutcome::Inactive
    );
    let third = begin(&mut state);
    assert!(state.set_presentation(presentation(
        8,
        &Preferences::default(),
        PersistenceState::Saved
    )));
    assert_eq!(
        state.capture(third, true, &event("f8"), CLEAR).0,
        CaptureOutcome::Inactive
    );
    assert!(!state.set_presentation(presentation(
        7,
        &Preferences::default(),
        PersistenceState::Saved
    )));
    let last = begin(&mut state);
    state.dismiss();
    assert_eq!(
        state.capture(last, true, &event("f8"), CLEAR).0,
        CaptureOutcome::Inactive
    );
    assert!(state.request(state.scope(), Action::Reload).is_none());
}

#[derive(Deserialize)]
#[serde(rename_all = "camelCase", deny_unknown_fields)]
struct SafetyCase {
    name: String,
    marked: String,
    dead: String,
    priority: bool,
    repeat: bool,
    alt: bool,
    outcome: String,
}
fn evidence(value: &str) -> Evidence {
    match value {
        "clear" => Evidence::Clear,
        "active" => Evidence::Active,
        "unknown" => Evidence::Unknown,
        _ => panic!("invalid synthetic evidence fixture"),
    }
}
#[test]
fn prepared_native_capture_safety_fixture_preserves_original_mapping_and_input_path() {
    let cases: Vec<SafetyCase> = serde_json::from_str(include_str!(
        "../../fixtures/shortcut-settings/capture-safety.json"
    ))
    .unwrap();
    for case in cases {
        let mut state = state();
        let before = state.presentation.clone();
        let token = begin(&mut state);
        let mut key = event("f8");
        key.is_held = case.repeat;
        key.prefer_character_input = case.priority;
        key.keystroke.modifiers.alt = case.alt;
        let (outcome, request) = state.capture(
            token,
            true,
            &key,
            InputSafety {
                marked_text: evidence(&case.marked),
                dead_key: evidence(&case.dead),
            },
        );
        assert_eq!(
            outcome,
            match case.outcome.as_str() {
                "passThrough" => CaptureOutcome::PassThrough,
                "repeat" => CaptureOutcome::IgnoredRepeat,
                _ => panic!("invalid synthetic outcome fixture"),
            },
            "{}",
            case.name
        );
        assert!(request.is_none(), "{}", case.name);
        assert_eq!(state.presentation, before, "{}", case.name);
        assert_eq!(state.token(), Some(token), "{}", case.name);
    }
}

#[test]
fn escape_tab_reverse_tab_modifiers_and_fixed_conflicts_use_real_recorder_outcomes() {
    for (key, shift, expected) in [
        ("escape", false, CaptureOutcome::Cancelled),
        ("tab", false, CaptureOutcome::Traverse { reverse: false }),
        ("tab", true, CaptureOutcome::Traverse { reverse: true }),
    ] {
        let mut state = state();
        let token = begin(&mut state);
        let mut key = event(key);
        key.keystroke.modifiers.control = false;
        key.keystroke.modifiers.shift = shift;
        assert_eq!(state.capture(token, true, &key, CLEAR), (expected, None));
        assert!(state.token().is_none());
    }
    let mut state = state();
    let token = begin(&mut state);
    assert_eq!(
        state.capture(token, true, &event("control"), CLEAR).0,
        CaptureOutcome::ModifierOnly
    );
    assert!(matches!(
        state.capture(token, true, &event("c"), CLEAR).0,
        CaptureOutcome::Rejected(ValidationError::EditingReserved)
    ));
    assert!(matches!(
        state.capture(token, true, &event("space"), CLEAR).0,
        CaptureOutcome::Rejected(_)
    ));
    assert_eq!(state.token(), Some(token));
    assert!(
        state
            .presentation
            .rows()
            .next()
            .unwrap()
            .current_label()
            .contains("Enter")
    );
}

#[test]
fn corrupt_readonly_fallback_allows_only_explicit_reload_or_bounded_recovery_requests() {
    for error in [
        StoreError::Read,
        StoreError::InvalidBindings,
        StoreError::Unavailable,
    ] {
        let mut state = State::new(presentation(
            9,
            &Preferences::default(),
            PersistenceState::ReadOnlyFallback(error),
        ));
        let scope = state.scope();
        assert!(!state.editable());
        assert!(state.begin(scope, Command::RunCurrent, true).is_none());
        assert!(state.request(scope, Action::Edit(Edit::ResetAll)).is_none());
        assert!(state.request(scope, Action::RetrySave).is_none());
        assert_eq!(
            state.presentation.persistence().can_recover(),
            error != StoreError::Unavailable
        );
        assert!(state.request(scope, Action::Reload).is_some());
        assert!(state.set_presentation(presentation(
            10,
            &Preferences::default(),
            PersistenceState::ReadOnlyFallback(error)
        )));
        assert_eq!(
            state
                .request(state.scope(), Action::RecoverDefaults)
                .is_some(),
            error != StoreError::Unavailable
        );
    }
    for persistence in [
        PersistenceState::Saving,
        PersistenceState::Reloading,
        PersistenceState::Recovering,
    ] {
        let state = State::new(presentation(1, &Preferences::default(), persistence));
        assert!(!state.presentation.persistence().can_reload());
        assert!(!state.presentation.persistence().can_retry());
    }
    assert!(PersistenceState::SaveFailed(StoreError::Write).can_retry());
    assert!(!PersistenceState::SaveFailed(StoreError::Conflict).can_retry());
}

#[test]
fn revision_and_epoch_exhaustion_never_wrap_into_new_recording_authority() {
    // Use the actual checked state transition rather than inventing a key ID.
    let mut state = State::new(presentation(
        u64::MAX,
        &Preferences::default(),
        PersistenceState::Saved,
    ));
    let scope = state.scope();
    state.dismiss();
    assert!(state.begin(scope, Command::RunCurrent, true).is_none());
    assert!(!state.set_presentation(presentation(
        0,
        &Preferences::default(),
        PersistenceState::Saved
    )));
}
