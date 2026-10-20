//! Prepared focused cases; do not execute before final integration after Task 32.
use super::*;
use crate::{
    language_service::label_range,
    shortcuts::{Evidence, InputSafety},
};
use gpui_kit::{KeyDownEvent, Keystroke};
use serde::Deserialize;

fn item(label: &str, replacement: &str, range: Range<usize>) -> CompletionItem {
    CompletionItem {
        label: label.into(),
        detail: None,
        kind: None,
        replacement: replacement.into(),
        replacement_range: range,
        match_ranges: Vec::new(),
    }
}

#[test]
fn shared_go_match_fixture_retains_disjoint_unicode_spans_for_display() {
    #[derive(Deserialize)]
    struct Fixture {
        label: String,
        ranges: Vec<[usize; 2]>,
    }
    let fixtures: Vec<Fixture> = serde_json::from_str(include_str!(
        "../../../../protocol/fixtures/completion-matches.json"
    ))
    .unwrap();
    for fixture in fixtures {
        let ranges: Vec<_> = fixture
            .ranges
            .into_iter()
            .map(|span| label_range(&fixture.label, span).unwrap())
            .collect();
        let expanded = display::grapheme_ranges(&fixture.label, &ranges);
        for original in ranges {
            assert!(
                expanded
                    .iter()
                    .any(|display| display.start <= original.start && display.end >= original.end)
            );
        }
        for pair in expanded.windows(2) {
            assert!(pair[0].end < pair[1].start);
        }
        for range in expanded {
            assert!(fixture.label.is_char_boundary(range.start));
            assert!(fixture.label.is_char_boundary(range.end));
        }
    }
}

#[test]
#[allow(clippy::single_range_in_vec_init, clippy::reversed_empty_ranges)] // Deliberately malformed peer ranges.
fn display_spans_expand_composed_characters_without_changing_engine_matches() {
    #[derive(Deserialize)]
    struct Fixture {
        label: String,
        utf16: Vec<[usize; 2]>,
        display_bytes: Vec<[usize; 2]>,
    }
    let fixtures: Vec<Fixture> =
        serde_json::from_str(include_str!("../../fixtures/completion-view/display.json")).unwrap();
    for fixture in fixtures {
        let ranges: Vec<_> = fixture
            .utf16
            .into_iter()
            .map(|span| label_range(&fixture.label, span).unwrap())
            .collect();
        let expected: Vec<_> = fixture
            .display_bytes
            .into_iter()
            .map(|[a, b]| a..b)
            .collect();
        assert_eq!(display::grapheme_ranges(&fixture.label, &ranges), expected);
    }
    for ranges in [vec![1..2], vec![0..4, 3..5], vec![5..4], vec![0..100]] {
        assert!(display::grapheme_ranges("😀orders", &ranges).is_empty());
    }
}

#[test]
fn popup_limit_keeps_go_priority_exact_quoting_and_whole_token_edit() {
    let source = "SELECT '😀', * FROM ordres_suffix";
    let start = source.find("ordres").unwrap();
    let caret = start + "ordres".len();
    let quoted = "\"Sales\".\"Order Items\"";
    let mut candidates = vec![
        item("foreign", "refused", 0..6),
        item("Order Items", quoted, start..source.len()),
    ];
    candidates.extend((0..300).map(|index| {
        item(
            &format!("candidate-{index}"),
            "unchanged",
            start..source.len(),
        )
    }));
    let rows = ordered_items(source, caret, candidates);
    assert_eq!(rows.len(), MAX_ROWS);
    assert_eq!(rows[0].label, "Order Items");
    assert_eq!(rows[0].replacement, quoted);
    assert_eq!(rows[0].replacement_range, start..source.len());
    assert_eq!(rows[99].label, "candidate-98");
    let inserted = format!("{}{}", &source[..start], rows[0].replacement);
    assert_eq!(inserted, "SELECT '😀', * FROM \"Sales\".\"Order Items\"");
}

#[test]
fn invalid_utf8_utf16_crlf_and_foreign_primary_edits_refuse() {
    let source = "a😀\r\norders";
    assert!(!valid_item(source, source.len(), &item("bad", "bad", 1..3)));
    assert!(!valid_item(
        source,
        source.len(),
        &item("bad", "bad", 6..source.len())
    ));
    assert!(!valid_item(source, source.len(), &item("bad", "bad", 0..1)));
    assert!(valid_item(
        source,
        source.len(),
        &item("id", "\"id\"", 7..source.len())
    ));
}

#[test]
fn native_diagnostics_use_scalar_columns_after_non_bmp_and_crlf() {
    use gpui_kit::component::input::{Position, Rope};
    let source = "😀a\r\nb𝕌x";
    let rope = Rope::from(source);
    for (bytes, expected) in [
        (4..5, Position::new(0, 1)..Position::new(0, 2)),
        (8..12, Position::new(1, 1)..Position::new(1, 2)),
    ] {
        let range = native::diagnostic_range(source, &rope, &bytes).unwrap();
        assert_eq!(range, expected);
        let mut set = gpui_kit::base::input::DiagnosticSet::new(&rope);
        set.push(gpui_kit::base::input::Diagnostic::new(range, "syntax"));
        assert_eq!(set.iter().next().unwrap().range, bytes);
    }
    assert!(native::diagnostic_range(source, &rope, &(6..7)).is_none());
    assert!(native::diagnostic_range(source, &rope, &(9..12)).is_none());
}

#[test]
fn request_dismissal_replacement_and_overflow_never_reown_old_callbacks() {
    let mut epoch = Epoch::default();
    let first = epoch.advance().unwrap();
    assert!(epoch.owns(first));
    let next = epoch.advance().unwrap();
    assert!(!epoch.owns(first));
    assert!(epoch.owns(next));
    epoch.value = u64::MAX;
    assert!(epoch.advance().is_none());
    assert!(!epoch.owns(next));
    assert!(epoch.advance().is_none());
}

#[test]
fn native_popup_keys_preserve_ime_altgr_unknown_shift_tab_and_repeat_acceptance() {
    let clear = InputSafety {
        marked_text: Evidence::Clear,
        dead_key: Evidence::Clear,
    };
    let make = |key: &str| KeyDownEvent {
        keystroke: Keystroke::parse(key).unwrap(),
        is_held: false,
        prefer_character_input: false,
    };
    assert_eq!(
        PopupAction::from_native(&make("tab"), clear),
        Some(PopupAction::Accept)
    );
    assert_eq!(
        PopupAction::from_native(&make("enter"), clear),
        Some(PopupAction::Accept)
    );
    assert_eq!(
        PopupAction::from_native(&make("escape"), clear),
        Some(PopupAction::Dismiss)
    );
    assert_eq!(
        PopupAction::from_native(&make("down"), clear),
        Some(PopupAction::Next)
    );
    assert_eq!(PopupAction::from_native(&make("shift-tab"), clear), None);
    assert_eq!(
        PopupAction::from_native(&make("ctrl-alt-enter"), clear),
        None
    );
    let mut repeat = make("enter");
    repeat.is_held = true;
    assert_eq!(PopupAction::from_native(&repeat, clear), None);
    for safety in [
        InputSafety {
            marked_text: Evidence::Active,
            ..clear
        },
        InputSafety {
            marked_text: Evidence::Unknown,
            ..clear
        },
        InputSafety {
            dead_key: Evidence::Active,
            ..clear
        },
        InputSafety {
            dead_key: Evidence::Unknown,
            ..clear
        },
    ] {
        assert_eq!(PopupAction::from_native(&make("enter"), safety), None);
    }
    let mut character_priority = make("tab");
    character_priority.prefer_character_input = true;
    assert_eq!(PopupAction::from_native(&character_priority, clear), None);
}
