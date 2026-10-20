//! Prepared behavior cases; execution is deferred until integration through 32.
use super::*;
use crate::appearance::{Preferences, Scheme, StoreError};
use serde::Deserialize;

fn themes() -> Vec<crate::appearance::Theme> {
    crate::theme_library::builtin_themes().unwrap()
}

#[test]
fn fixture_choices_project_same_library_and_independent_effective_preview() {
    #[derive(Deserialize)]
    #[serde(rename_all = "camelCase")]
    struct Fixture {
        application: String,
        editor: String,
        system: String,
        resolved_editor: String,
    }
    let cases: Vec<Fixture> = serde_json::from_str(include_str!(
        "../../fixtures/settings-appearance/selections.json"
    ))
    .unwrap();
    let themes = themes();
    for case in cases {
        let mut preferences = Preferences::default();
        assert!(preferences.choose_application(&case.application, &themes));
        assert!(preferences.choose_editor(&case.editor, &themes));
        let original = preferences.clone();
        let model = Presentation::new(
            17,
            &preferences,
            if case.system == "dark" {
                Scheme::Dark
            } else {
                Scheme::Light
            },
            &themes,
            PersistenceState::Saved,
        );
        assert_eq!(model.application_selection(), case.application);
        assert_eq!(model.editor_selection(), case.editor);
        assert_eq!(model.editor_palette().theme.id, case.resolved_editor);
        assert_eq!(preferences, original);
        let app_schemes = &model.application_choices()[3..];
        let editor_schemes = &model.editor_choices()[1..];
        assert_eq!(app_schemes, editor_schemes);
        assert_eq!(app_schemes.len(), themes.len());
        for (choice, theme) in app_schemes.iter().zip(&themes) {
            assert_eq!(choice.id(), theme.id);
            assert_eq!(choice.title(), theme.name);
        }
        assert!(model.accepts(&SettingsEvent {
            revision: 17,
            action: SettingsAction::ChooseApplication(case.application),
        }));
    }
}

#[test]
fn missing_and_future_saved_ids_stay_selected_disabled_and_unchanged() {
    let preferences = Preferences {
        application_color_theme: "imported-temporarily-unavailable".into(),
        editor_color_theme: "future-editor-selection".into(),
        ..Default::default()
    };
    let original = preferences.clone();
    let model = Presentation::new(
        4,
        &preferences,
        Scheme::Dark,
        &themes(),
        PersistenceState::ReadOnlyFallback,
    );
    for (selected, choices, action) in [
        (
            model.application_selection(),
            model.application_choices(),
            SettingsAction::ChooseApplication(model.application_selection().into()),
        ),
        (
            model.editor_selection(),
            model.editor_choices(),
            SettingsAction::ChooseEditor(model.editor_selection().into()),
        ),
    ] {
        let selected = choices
            .iter()
            .find(|choice| choice.id() == selected)
            .unwrap();
        assert!(!selected.available());
        assert!(selected.title().starts_with("Unavailable saved"));
        assert!(!model.accepts(&SettingsEvent {
            revision: 4,
            action,
        }));
    }
    assert_eq!(model.editor_palette().theme.id, "native-dark");
    assert_eq!(preferences, original);
    assert!(model.accepts(&SettingsEvent {
        revision: 4,
        action: SettingsAction::Close,
    }));
}

#[test]
fn fixed_failure_actions_require_current_authority_and_never_offer_read_only_retry() {
    let themes = themes();
    for (state, retry, reload, choose) in [
        (PersistenceState::Saved, false, true, true),
        (PersistenceState::PreviewOnly, false, false, true),
        (PersistenceState::Saving, false, false, true),
        (PersistenceState::ReadOnlyFallback, false, true, true),
        (
            PersistenceState::SaveFailed(StoreError::Write),
            true,
            true,
            true,
        ),
        (
            PersistenceState::SaveFailed(StoreError::Conflict),
            false,
            true,
            true,
        ),
        (
            PersistenceState::SaveFailed(StoreError::Read),
            false,
            true,
            true,
        ),
        (PersistenceState::Reloading, false, false, false),
    ] {
        let model = Presentation::new(90, &Preferences::default(), Scheme::Dark, &themes, state);
        for (action, expected) in [
            (SettingsAction::RetrySave, retry),
            (SettingsAction::Reload, reload),
            (SettingsAction::ChooseEditor("native-light".into()), choose),
            (SettingsAction::Close, true),
        ] {
            assert_eq!(
                model.accepts(&SettingsEvent {
                    revision: 90,
                    action: action.clone(),
                }),
                expected,
            );
            assert!(!model.accepts(&SettingsEvent {
                revision: 89,
                action,
            }));
        }
        if let Some(error) = state.error() {
            assert!(!error.to_string().is_empty());
        }
    }
}

#[test]
fn invalid_duplicate_and_reserved_catalog_entries_cannot_create_ambiguous_choices() {
    let mut themes = themes();
    let mut duplicate = themes[0].clone();
    duplicate.name = "Second label for the same ID".into();
    let mut reserved = duplicate.clone();
    reserved.id = "system".into();
    let mut invalid = duplicate.clone();
    invalid.id = "invalid-theme".into();
    invalid.name.clear();
    let expected = themes.len();
    themes.extend([duplicate, reserved, invalid]);
    let model = Presentation::new(
        1,
        &Preferences::default(),
        Scheme::Light,
        &themes,
        PersistenceState::Saved,
    );
    assert_eq!(model.application_choices().len(), expected + 3);
    assert_eq!(model.editor_choices().len(), expected + 1);
    assert!(!model.accepts(&SettingsEvent {
        revision: 1,
        action: SettingsAction::ChooseEditor("invalid-theme".into()),
    }));
}

#[test]
fn native_reselection_and_follow_application_events_do_not_change_other_selector() {
    let themes = themes();
    let mut preferences = Preferences::default();
    preferences.choose_application("vscode-dark-plus", &themes);
    preferences.choose_editor("native-light", &themes);
    let model = Presentation::new(
        3,
        &preferences,
        Scheme::Light,
        &themes,
        PersistenceState::Saved,
    );
    assert!(model.accepts(&SettingsEvent {
        revision: 3,
        action: SettingsAction::ChooseApplication("system".into()),
    }));
    preferences.choose_application("system", &themes);
    assert_eq!(preferences.editor_color_theme, "native-light");
    let model = Presentation::new(
        4,
        &preferences,
        Scheme::Light,
        &themes,
        PersistenceState::Saved,
    );
    assert!(model.accepts(&SettingsEvent {
        revision: 4,
        action: SettingsAction::ChooseEditor("automatic".into()),
    }));
    preferences.choose_editor("automatic", &themes);
    assert_eq!(preferences.application_selection(), "system");
}
