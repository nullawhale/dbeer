//! Prepared cases only. Execute after all remaining code through Task 32 integrates.
use super::*;
use crate::language_service::{
    CatalogSnapshot, ContextKey, Dialect, LanguageService, SignatureInformation, metadata::Relation,
};
use gpui_kit::{KeyDownEvent, Keystroke};
use serde::Deserialize;
use std::{
    fs,
    path::{Path, PathBuf},
    process::{Command, Stdio},
    sync::OnceLock,
};

pub(super) fn signature(
    label: &str,
    active: Option<usize>,
    parameters: &[&str],
) -> SignatureInformation {
    SignatureInformation {
        label: label.into(),
        active_parameter: active,
        parameter_ranges: parameters
            .iter()
            .map(|parameter| {
                let start = label.find(parameter).unwrap();
                start..start + parameter.len()
            })
            .collect(),
    }
}

#[test]
fn labels_parameters_returns_rank_and_overload_navigation_remain_go_owned() {
    let labels = [
        signature("f(value: integer) → integer", Some(0), &["value: integer"]),
        signature(
            "f(value: numeric, scale: integer = DEFAULT) → numeric",
            Some(1),
            &["value: numeric", "scale: integer = DEFAULT"],
        ),
        signature(
            "f(VARIADIC values: text[]) → text",
            Some(0),
            &["VARIADIC values: text[]"],
        ),
    ];
    let model = model::Signatures::new(labels.into(), 1).unwrap();
    assert_eq!(model.active, 1);
    assert_eq!(model.order(model.active), [1, 0, 2]);
    assert_eq!(
        &model.rows[1].label[model.rows[1].active_range.clone().unwrap()],
        "scale: integer = DEFAULT"
    );
    assert_eq!(model.navigate(1, PopupAction::PreviousOverload), Some(0));
    assert_eq!(model.navigate(1, PopupAction::NextOverload), Some(2));
    assert_eq!(model.navigate(2, PopupAction::NextOverload), Some(2));
    assert_eq!(model.navigate(1, PopupAction::ChooseOverload(3)), None);
    assert_eq!(&*model.rows[2].label, "f(VARIADIC values: text[]) → text");
}

#[test]
fn eight_visible_rows_still_allow_all_thirty_two_overloads() {
    let model = model::Signatures::new(
        (0..32)
            .map(|index| {
                signature(
                    &format!("f(value: type_{index}) → result"),
                    Some(0),
                    &[&format!("value: type_{index}")],
                )
            })
            .collect(),
        31,
    )
    .unwrap();
    assert_eq!(model.order(31), [31, 0, 1, 2, 3, 4, 5, 6]);
    assert_eq!(model.navigate(0, PopupAction::ChooseOverload(31)), Some(31));
}

#[test]
fn active_parameter_display_uses_composed_characters_without_rewriting_labels() {
    let label = "f(cafe\u{301}: text, second 😀: integer) → text";
    let model = model::Signatures::new(
        vec![signature(
            label,
            Some(1),
            &["cafe\u{301}: text", "second 😀: integer"],
        )],
        0,
    )
    .unwrap();
    assert_eq!(
        &model.rows[0].label[model.rows[0].active_range.clone().unwrap()],
        "second 😀: integer"
    );
    let label = "f(e\u{301})";
    let model = model::Signatures::new(
        vec![SignatureInformation {
            label: label.into(),
            parameter_ranges: vec![std::ops::Range { start: 2, end: 3 }],
            active_parameter: Some(0),
        }],
        0,
    )
    .unwrap();
    assert_eq!(model.rows[0].active_range, Some(2..5));
    assert_eq!(&*model.rows[0].label, label);
}

#[test]
fn malformed_or_excessive_signature_sets_refuse_atomically() {
    assert!(model::Signatures::new(Vec::new(), 0).is_none());
    for range in [0..0, 1..3, 10..99] {
        assert!(
            model::Signatures::new(
                vec![SignatureInformation {
                    label: "😀(x)".into(),
                    parameter_ranges: vec![range],
                    active_parameter: Some(0),
                }],
                0
            )
            .is_none()
        );
    }
    assert!(model::Signatures::new(vec![signature("f() → text", None, &[])], 1).is_none());
    assert!(
        model::Signatures::new(
            (0..33)
                .map(|_| signature("f() → text", None, &[]))
                .collect(),
            0
        )
        .is_none()
    );
}

#[test]
fn replacement_escape_focus_and_epoch_exhaustion_never_reown_old_callbacks() {
    let mut epoch = Epoch::default();
    let pending = epoch.advance().unwrap();
    let replacement = epoch.advance().unwrap();
    assert!(!epoch.owns(pending));
    assert!(epoch.owns(replacement));
    epoch.advance(); // Escape or focus/context invalidation.
    assert!(!epoch.owns(replacement));
    epoch.value = u64::MAX;
    assert!(epoch.advance().is_none());
    assert!(!epoch.owns(replacement));
    assert!(epoch.advance().is_none());
}

#[test]
fn only_safe_escape_is_consumed_and_edit_navigation_undo_pass_through() {
    let clear = crate::shortcuts::InputSafety {
        marked_text: crate::shortcuts::Evidence::Clear,
        dead_key: crate::shortcuts::Evidence::Clear,
    };
    let make = |key: &str| KeyDownEvent {
        keystroke: Keystroke::parse(key).unwrap(),
        is_held: false,
        prefer_character_input: false,
    };
    assert_eq!(
        PopupAction::from_native(&make("escape"), clear),
        Some(PopupAction::Dismiss)
    );
    for key in [
        "up",
        "down",
        "tab",
        "enter",
        "ctrl-z",
        "cmd-z",
        "ctrl-alt-escape",
    ] {
        assert_eq!(PopupAction::from_native(&make(key), clear), None);
    }
    for safety in [
        crate::shortcuts::InputSafety {
            marked_text: crate::shortcuts::Evidence::Active,
            ..clear
        },
        crate::shortcuts::InputSafety {
            dead_key: crate::shortcuts::Evidence::Unknown,
            ..clear
        },
    ] {
        assert_eq!(PopupAction::from_native(&make("escape"), safety), None);
    }
    let mut repeat = make("escape");
    repeat.is_held = true;
    assert_eq!(PopupAction::from_native(&repeat, clear), None);
}

pub(super) fn fake(mode: &str) -> PathBuf {
    static BINARY: OnceLock<PathBuf> = OnceLock::new();
    let base = BINARY.get_or_init(|| {
        let root = Path::new(env!("CARGO_MANIFEST_DIR"))
            .join("../../build/gpui/task25-fixtures")
            .join(uuid::Uuid::new_v4().to_string());
        fs::create_dir_all(&root).unwrap();
        let binary = root.join(if cfg!(windows) { "base.exe" } else { "base" });
        assert!(
            Command::new("rustc")
                .arg("--edition=2024")
                .arg(
                    Path::new(env!("CARGO_MANIFEST_DIR"))
                        .join("fixtures/signature-help/fake_helper.rs")
                )
                .arg("-o")
                .arg(&binary)
                .stdout(Stdio::null())
                .stderr(Stdio::null())
                .status()
                .unwrap()
                .success()
        );
        binary
    });
    let path = base.parent().unwrap().join(format!(
        "{mode}-{}{}",
        uuid::Uuid::new_v4(),
        if cfg!(windows) { ".exe" } else { "" }
    ));
    fs::copy(base, &path).unwrap();
    path
}

#[test]
fn owned_fake_service_preserves_overloads_and_refuses_late_source_and_invalid_spans() {
    smol::block_on(async {
        for mode in ["normal", "null", "bad", "slow"] {
            let path = fake(mode);
            let service = LanguageService::spawn(&path).unwrap();
            service.initialize().await.unwrap();
            let capture = service
                .update(
                    "signature-doc",
                    "SELECT f(1, ",
                    Dialect::PostgreSQL,
                    ContextKey::default(),
                    CatalogSnapshot::default(),
                )
                .unwrap();
            if mode == "slow" {
                let (response, ()) = smol::future::zip(
                    service.signature_help(&capture, capture.source().len()),
                    async {
                        smol::Timer::after(Duration::from_millis(20)).await;
                        service
                            .update(
                                "signature-doc",
                                "SELECT f(2, ",
                                Dialect::PostgreSQL,
                                ContextKey::default(),
                                CatalogSnapshot::default(),
                            )
                            .unwrap();
                    },
                )
                .await;
                assert!(matches!(response, Err(language_service::Error::Stale)));
            } else {
                let help = service
                    .signature_help(&capture, capture.source().len())
                    .await;
                match mode {
                    "null" => assert!(help.unwrap().is_none()),
                    "bad" => assert!(help.is_err()),
                    _ => {
                        let help = help.unwrap().unwrap();
                        let model =
                            model::Signatures::new(help.signatures, help.active_signature).unwrap();
                        assert_eq!(model.active, 1);
                        assert_eq!(model.rows.len(), 2);
                        assert_eq!(
                            &model.rows[1].label[model.rows[1].active_range.clone().unwrap()],
                            "scale: integer = DEFAULT"
                        );
                    }
                }
            }
            service.shutdown().await;
            let methods = fs::read_to_string(path.with_extension("events")).unwrap();
            assert_eq!(
                methods
                    .lines()
                    .filter(|method| *method == "textDocument/signatureHelp")
                    .count(),
                1
            );
            assert!(!methods.contains("textDocument/completion"));
        }
    });
}

#[derive(Deserialize)]
struct Case {
    engine: String,
    source: String,
    #[serde(default)]
    catalog: bool,
    prefix: Option<String>,
    active: Option<usize>,
    parameter: Option<String>,
    overload: Option<usize>,
}

/// Uses the actual matching bundled Go LSP, synthetic sources and immutable
/// catalog DTOs only. It has no backend, credential or database session handle.
#[test]
fn actual_go_signature_cases_reach_presentation_without_rust_sql_semantics() {
    smol::block_on(async {
        let service = LanguageService::spawn(crate::platform::helper_path()).unwrap();
        service.initialize().await.unwrap();
        let cases: Vec<Case> =
            serde_json::from_str(include_str!("../../fixtures/signature-help/cases.json")).unwrap();
        for case in cases {
            let caret = case.source.find('|').unwrap();
            let source = case.source.replacen('|', "", 1);
            let catalog = if case.catalog {
                CatalogSnapshot::bounded([Relation {
                    schema: "public".into(),
                    name: "calculate".into(),
                    kind: "function".into(),
                    columns: Vec::new(),
                    foreign_keys: Vec::new(),
                    signatures: serde_json::from_str(include_str!(
                        "../../fixtures/signature-help/catalog.json"
                    ))
                    .unwrap(),
                }])
            } else {
                CatalogSnapshot::default()
            };
            let capture = service
                .update(
                    "signature-doc",
                    source,
                    if case.engine == "mysql" {
                        Dialect::MySQL
                    } else {
                        Dialect::PostgreSQL
                    },
                    ContextKey {
                        catalog_revision: u64::from(case.catalog),
                        ..Default::default()
                    },
                    catalog,
                )
                .unwrap();
            let help = service.signature_help(&capture, caret).await.unwrap();
            let Some(prefix) = case.prefix else {
                assert!(help.is_none());
                continue;
            };
            let help = help.unwrap();
            assert_eq!(Some(help.active_signature), case.overload);
            assert_eq!(
                help.signatures[help.active_signature].active_parameter,
                case.active
            );
            let model = model::Signatures::new(help.signatures, help.active_signature).unwrap();
            let row = &model.rows[model.active];
            assert!(row.label.starts_with(&prefix));
            assert!(row.label.contains(" → "));
            assert_eq!(
                row.active_range
                    .clone()
                    .map(|range| row.label[range].to_owned()),
                case.parameter
            );
        }
        service.shutdown().await;
    });
}
