//! Prepared behavior cases. Execute only after integration through Task 32.
use super::*;
use crate::{
    appearance::{Preferences, Scheme, Theme},
    theme_library::{self, Error},
};
use serde::Deserialize;

const IMPORTED: &str = "imported-48e1743b-4c98-4a8e-8d7b-5241c3cddda5";

fn themes() -> Vec<Theme> {
    let mut themes = theme_library::builtin_themes().unwrap();
    themes.push(
        theme_library::parse_bytes(
            include_bytes!("../../fixtures/settings-theme-library/import.jsonc"),
            "Library Preview Fixture",
            IMPORTED,
        )
        .unwrap(),
    );
    themes
}
fn request(mode: ImportMode) -> ImportRequest {
    ImportRequest::new(3, 71, mode).unwrap()
}
fn review(mode: ImportMode) -> ImportReview {
    let preview = theme_library::preview_import(
        std::path::Path::new(env!("CARGO_MANIFEST_DIR"))
            .join("fixtures/settings-theme-library/import.jsonc")
            .as_path(),
    )
    .unwrap();
    ImportReview::new(PreviewToken::new(request(mode), 94).unwrap(), &preview)
}
fn presentation(access: LibraryAccess, workflow: Workflow) -> Presentation {
    Presentation::new(8, &themes(), Some(IMPORTED), Scheme::Dark, access, workflow)
}
fn accepts(model: &Presentation, action: LibraryAction) -> bool {
    model.accepts(&LibraryEvent {
        revision: model.revision(),
        action,
    })
}

#[test]
fn fixture_library_authority_does_not_turn_fallback_into_writes() {
    #[derive(Deserialize)]
    #[serde(rename_all = "camelCase")]
    struct Case {
        access: String,
        request_import: bool,
        request_recovery: bool,
        remove_imported: bool,
    }
    let cases: Vec<Case> = serde_json::from_str(include_str!(
        "../../fixtures/settings-theme-library/actions.json"
    ))
    .unwrap();
    for case in cases {
        let access = match case.access.as_str() {
            "writable" => LibraryAccess::Writable,
            "recoverable" => LibraryAccess::ReadOnly {
                error: Error::LibraryRead,
                recovery_available: true,
            },
            "unreadable" => LibraryAccess::ReadOnly {
                error: Error::Unreadable,
                recovery_available: false,
            },
            _ => panic!("Unknown fixture authority"),
        };
        let model = presentation(access, Workflow::Idle);
        assert_eq!(
            accepts(&model, LibraryAction::RequestImport),
            case.request_import
        );
        assert_eq!(
            accepts(&model, LibraryAction::RequestRecoveryImport),
            case.request_recovery
        );
        assert_eq!(
            accepts(&model, LibraryAction::Remove(IMPORTED.into())),
            case.remove_imported
        );
        assert!(accepts(
            &model,
            LibraryAction::Browse("vscode-dark-plus".into())
        ));
        for id in theme_library::BUILTIN_IDS {
            assert!(!model.can_remove(id));
        }
        assert!(!model.can_remove("missing-imported-theme"));
        assert!(accepts(&model, LibraryAction::Reload));
    }
}

#[test]
fn projection_borrows_actual_normalized_library_and_never_changes_selectors() {
    let themes = themes();
    let mut preferences = Preferences::default();
    preferences.choose_application("solarized-light", &themes);
    preferences.choose_editor("native-dark", &themes);
    let original_preferences = preferences.clone();
    let original_themes = themes.clone();
    for id in themes.iter().map(|theme| theme.id.as_str()) {
        let model = Presentation::new(
            1,
            &themes,
            Some(id),
            Scheme::Light,
            LibraryAccess::Writable,
            Workflow::Idle,
        );
        assert_eq!(model.themes(), themes);
        assert_eq!(
            model.preview_theme(),
            themes.iter().find(|theme| theme.id == id).unwrap()
        );
        assert!(accepts(&model, LibraryAction::Browse(id.into())));
    }
    assert_eq!(preferences, original_preferences);
    assert_eq!(themes, original_themes);
}

#[test]
fn review_uses_original_request_and_exact_preview_with_explicit_commit_and_cancel() {
    let review = review(ImportMode::Standard);
    let model = presentation(LibraryAccess::Writable, Workflow::Review(review.clone()));
    assert_eq!(model.preview_theme(), review.preview().theme());
    assert!(
        !model
            .themes()
            .iter()
            .any(|theme| theme.id == review.theme().id)
    );
    assert!(accepts(&model, LibraryAction::CommitImport(review.token())));
    let cancel = LibraryAction::CancelImport {
        request: request(ImportMode::Standard),
        preview: Some(review.token()),
    };
    assert!(accepts(&model, cancel.clone()));
    assert!(!accepts(&model, LibraryAction::Browse(IMPORTED.into())));
    assert!(!accepts(&model, LibraryAction::RequestImport));
    assert!(!accepts(&model, LibraryAction::Remove(IMPORTED.into())));
    assert!(!accepts(
        &model,
        LibraryAction::CommitImport(PreviewToken::new(request(ImportMode::Standard), 95).unwrap())
    ));
    let newer_request = ImportRequest::new(7, 72, ImportMode::Standard).unwrap();
    assert!(!accepts(
        &model,
        LibraryAction::CancelImport {
            request: newer_request,
            preview: Some(review.token())
        }
    ));
    assert!(!accepts(
        &model,
        LibraryAction::CancelImport {
            request: request(ImportMode::Standard),
            preview: None
        }
    ));
    assert!(!model.accepts(&LibraryEvent {
        revision: 7,
        action: cancel
    }));
    let idle = presentation(LibraryAccess::Writable, Workflow::Idle);
    assert_eq!(idle.preview_theme().id, IMPORTED);
    assert!(!accepts(&idle, LibraryAction::CommitImport(review.token())));
}

#[test]
fn recovery_must_be_separately_explicit_and_does_not_authorize_ordinary_import() {
    let access = LibraryAccess::ReadOnly {
        error: Error::LibraryRead,
        recovery_available: true,
    };
    let standard = review(ImportMode::Standard);
    let recovery = review(ImportMode::Recovery);
    assert!(!accepts(
        &presentation(access, Workflow::Review(standard.clone())),
        LibraryAction::CommitImport(standard.token())
    ));
    let model = presentation(access, Workflow::Review(recovery.clone()));
    assert!(accepts(
        &model,
        LibraryAction::CommitImport(recovery.token())
    ));
    assert!(accepts(&model, model.cancel_action().unwrap()));
    assert!(!accepts(
        &presentation(LibraryAccess::Writable, Workflow::Review(recovery.clone())),
        LibraryAction::CommitImport(recovery.token())
    ));
}

#[test]
fn retries_carry_original_operation_and_refuse_conflict_or_ambiguous_publication() {
    let review = review(ImportMode::Standard);
    let removal = RemovalRequest::new(3, 91, IMPORTED).unwrap();
    for error in [
        Error::LibraryWrite,
        Error::Conflict,
        Error::RecoveryRequired,
        Error::LibraryFull,
        Error::PublishedUnverified,
        #[cfg(windows)]
        Error::PublicationUnknown,
    ] {
        let model = presentation(
            LibraryAccess::Writable,
            Workflow::ImportSaveFailed {
                review: review.clone(),
                error,
            },
        );
        assert_eq!(
            accepts(&model, LibraryAction::RetryImportSave(review.token())),
            error == Error::LibraryWrite
        );
        let unverified = error == Error::PublishedUnverified;
        #[cfg(windows)]
        let unverified = unverified || error == Error::PublicationUnknown;
        assert_eq!(model.cancel_action().is_some(), !unverified);
        assert!(accepts(&model, LibraryAction::Reload));
        let model = presentation(
            LibraryAccess::Writable,
            Workflow::RemoveFailed {
                request: removal.clone(),
                error,
            },
        );
        assert_eq!(
            accepts(&model, LibraryAction::RetryRemove(removal.clone())),
            error == Error::LibraryWrite
        );
        if model.requires_reload() {
            assert!(!accepts(&model, LibraryAction::Remove(IMPORTED.into())));
            assert!(!accepts(&model, LibraryAction::RequestImport));
        }
        assert!(!accepts(
            &model,
            LibraryAction::RetryRemove(RemovalRequest::new(4, 92, IMPORTED).unwrap())
        ));
    }
    let failed = presentation(
        LibraryAccess::Writable,
        Workflow::ImportFailed {
            request: request(ImportMode::Standard),
            error: Error::Unreadable,
        },
    );
    assert!(accepts(
        &failed,
        LibraryAction::RetryImport(request(ImportMode::Standard))
    ));
    for workflow in [
        Workflow::SavingImport(review.clone()),
        Workflow::Removing(removal),
        Workflow::Reloading,
    ] {
        let model = presentation(LibraryAccess::Writable, workflow);
        assert!(!accepts(&model, LibraryAction::Reload));
        assert!(!accepts(&model, LibraryAction::RequestImport));
        assert!(!accepts(
            &model,
            LibraryAction::CommitImport(review.token())
        ));
        assert!(model.cancel_action().is_none());
    }
}

#[test]
fn choosing_parsing_cancellation_and_old_targets_require_exact_origin() {
    let original = request(ImportMode::Standard);
    let replacement = ImportRequest::new(7, 72, ImportMode::Standard).unwrap();
    for workflow in [Workflow::Choosing(original), Workflow::Parsing(original)] {
        let model = presentation(LibraryAccess::Writable, workflow);
        assert!(accepts(
            &model,
            LibraryAction::CancelImport {
                request: original,
                preview: None
            }
        ));
        assert!(!accepts(
            &model,
            LibraryAction::CancelImport {
                request: replacement,
                preview: None
            }
        ));
        assert!(!accepts(&model, LibraryAction::Remove(IMPORTED.into())));
        assert!(!model.accepts(&LibraryEvent {
            revision: 3,
            action: LibraryAction::RequestImport
        }));
    }
    assert!(ImportRequest::new(0, 0, ImportMode::Standard).is_none());
    assert!(PreviewToken::new(original, 0).is_none());
    assert!(RemovalRequest::new(0, 0, IMPORTED).is_none());
    let mut invalid = themes();
    invalid[0].is_imported = true;
    let model = Presentation::new(
        8,
        &invalid,
        Some("native-light"),
        Scheme::Light,
        LibraryAccess::Writable,
        Workflow::Idle,
    );
    assert!(!model.can_remove("native-light"));
}

#[test]
fn disposable_preview_never_claims_personal_library_or_reload_authority() {
    let model = presentation(LibraryAccess::PreviewOnly, Workflow::Idle);
    assert!(model.error().is_none());
    assert!(model.can_browse());
    assert!(!model.can_reload());
    assert!(!model.can_start(ImportMode::Standard));
    assert!(!model.can_start(ImportMode::Recovery));
    assert!(!model.can_remove(IMPORTED));
}
