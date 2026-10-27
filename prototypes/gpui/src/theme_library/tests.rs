use super::*;
use crate::appearance::{Color, Scheme, TokenRule, TokenStyle};
use serde::Deserialize;
use std::{
    collections::BTreeMap,
    fs,
    path::{Path, PathBuf},
};
const FIXTURE_ROOT: &str = concat!(
    env!("CARGO_MANIFEST_DIR"),
    "/../../protocol/fixtures/gpui-theme-parity"
);
const ID: &str = "imported-00000000-0000-4000-8000-000000000027";
#[derive(Deserialize)]
struct Fixtures {
    version: u32,
    cases: Vec<Case>,
}
#[derive(Deserialize)]
struct Case {
    file: String,
    name: String,
    appearance: Scheme,
    colors: BTreeMap<String, String>,
    rules: Vec<Rule>,
    styles: Vec<Resolved>,
}
#[derive(Deserialize)]
struct Rule {
    scopes: Vec<String>,
    style: Style,
}
#[derive(Deserialize)]
struct Resolved {
    scopes: Vec<String>,
    #[serde(flatten)]
    style: Style,
}
#[derive(Deserialize)]
#[serde(rename_all = "camelCase")]
struct Style {
    foreground: Option<String>,
    background: Option<String>,
    font_style: Option<String>,
}
impl Style {
    fn normalized(&self) -> TokenStyle {
        TokenStyle {
            foreground: self
                .foreground
                .as_deref()
                .map(|hex| Color::hex(hex).unwrap()),
            background: self
                .background
                .as_deref()
                .map(|hex| Color::hex(hex).unwrap()),
            font_style: self.font_style.clone(),
        }
    }
}
#[test]
fn shared_sources_match_every_normalized_color_rule_and_resolved_style() {
    let fixtures: Fixtures = serde_json::from_str(include_str!(
        "../../../../protocol/fixtures/gpui-theme-parity/cases.json"
    ))
    .unwrap();
    assert_eq!(fixtures.version, 1);
    for case in fixtures.cases {
        let theme =
            preview_import(&fs::canonicalize(Path::new(FIXTURE_ROOT).join(&case.file)).unwrap())
                .unwrap()
                .theme;
        assert_eq!(theme.name, case.name);
        assert_eq!(theme.appearance, case.appearance);
        assert!(theme.is_imported);
        assert_eq!(
            theme.colors,
            case.colors
                .into_iter()
                .map(|(key, hex)| (key, Color::hex(&hex).unwrap()))
                .collect()
        );
        assert_eq!(
            theme.token_rules,
            case.rules
                .into_iter()
                .map(|rule| TokenRule {
                    scopes: rule.scopes,
                    style: rule.style.normalized()
                })
                .collect::<Vec<_>>()
        );
        for resolved in case.styles {
            assert_eq!(
                theme.style(
                    &resolved
                        .scopes
                        .iter()
                        .map(String::as_str)
                        .collect::<Vec<_>>()
                ),
                resolved.style.normalized()
            );
        }
    }
}
#[test]
fn eight_actual_bundled_themes_and_jetbrains_parents_are_complete() {
    let themes = builtin_themes().unwrap();
    assert_eq!(themes.len(), 8);
    assert_eq!(
        themes
            .iter()
            .map(|theme| theme.id.as_str())
            .collect::<Vec<_>>(),
        BUILTIN_IDS
    );
    assert!(
        themes
            .iter()
            .all(|theme| theme.is_valid() && !theme.is_imported)
    );
    assert_eq!(themes[0], Theme::native(Scheme::Light));
    assert_eq!(themes[1], Theme::native(Scheme::Dark));
    assert_eq!(themes[6].name, "JetBrains Light");
    assert_eq!(themes[7].appearance, Scheme::Dark);
    assert!(themes[2].token_rules.len() > 10);
    assert!(themes[3].token_rules.len() > 10);
    let theme = preview_import(
        &fs::canonicalize(Path::new(FIXTURE_ROOT).join("jetbrains-parent.icls")).unwrap(),
    )
    .unwrap()
    .theme;
    assert_eq!(theme.appearance, Scheme::Dark);
    let style = theme.style(&["source.sql", "keyword.control.sql"]);
    assert_eq!(style.foreground, Color::hex("#123456"));
    assert_eq!(style.font_style.as_deref(), Some(""));
}
#[test]
fn standalone_includes_and_invalid_jsonc_colors_and_foreign_documents_are_refused() {
    for bytes in [
        b"{}".as_slice(),
        b"null",
        b"[]",
        br##"{"colors":{"editor.background":"red"}}"##,
        br##"{"colors":{"editor.background":"#fff"},/*unclosed"##,
        br##"{"include":"local.json","colors":{"editor.background":"#fff"}}"##,
        br##"{"tokenColors":"theme.tmTheme"}"##,
        br##"{"tokenColors":false}"##,
    ] {
        assert!(parse_bytes(bytes, "Theme", ID).is_err());
    }
    assert_eq!(
        parse_bytes(&vec![b' '; MAX_FILE_BYTES + 1], "Theme", ID),
        Err(Error::TooLarge)
    );
    assert_eq!(
        parse_bytes(
            br##"{"colors":{"editor.background":"#fff"}}"##,
            "Theme",
            "native-light"
        ),
        Err(Error::InvalidIdentity)
    );
}
struct Directory(PathBuf);
impl Directory {
    fn new() -> Self {
        let root = PathBuf::from(env!("CARGO_MANIFEST_DIR"))
            .join("../../build/gpui/task27-parser-tests")
            .join(uuid::Uuid::new_v4().to_string());
        fs::create_dir_all(&root).unwrap();
        Self(fs::canonicalize(root).unwrap())
    }
    fn file(&self, name: &str, content: &[u8]) -> PathBuf {
        let path = self.0.join(name);
        fs::write(&path, content).unwrap();
        path
    }
}
impl Drop for Directory {
    fn drop(&mut self) {
        _ = fs::remove_dir_all(&self.0);
    }
}
#[test]
fn local_references_reject_traversal_remote_cycles_depth_and_nonregular_paths() {
    let directory = Directory::new();
    for reference in [
        "../outside.json",
        "/absolute.json",
        "https://example.invalid/theme.json",
        "file:theme.json",
        "~/.theme",
        "..\\outside.json",
        "\\\\server\\theme.json",
    ] {
        let data = serde_json::to_vec(&serde_json::json!({"include":reference})).unwrap();
        assert_eq!(
            preview_import(&directory.file("selected.json", &data)),
            Err(Error::UnsafeReference)
        );
    }
    assert_eq!(
        preview_import(&directory.file("cycle.json", b"{\"include\":\"cycle.json\"}")),
        Err(Error::ReferenceCycle)
    );
    for index in 0..9 {
        directory.file(
            &format!("depth{index}.json"),
            format!("{{\"include\":\"depth{}.json\"}}", index + 1).as_bytes(),
        );
    }
    assert_eq!(
        preview_import(&directory.0.join("depth0.json")),
        Err(Error::ReferenceCycle)
    );
    assert!(preview_import(&directory.0).is_err());
}
#[test]
fn aggregate_count_and_rule_limits_are_enforced_after_include_merges() {
    let directory = Directory::new();
    // A 2-way include DAG reuses files but still counts every read toward the 16-file bound.
    directory.file("leaf.json", br##"{"colors":{"editor.background":"#fff"}}"##);
    for index in (0..4).rev() {
        let next = if index == 3 {
            "leaf.json".into()
        } else {
            format!("node{}.json", index + 1)
        };
        directory.file(
            &format!("node{index}.json"),
            serde_json::to_string(&serde_json::json!({"include":next,"tokenColors":next}))
                .unwrap()
                .as_bytes(),
        );
    }
    assert_eq!(
        preview_import(&directory.0.join("node0.json")),
        Err(Error::TooLarge)
    );
    let rule = serde_json::json!({"scope":"keyword","settings":{"foreground":"#123456"}});
    let data =
        serde_json::to_vec(&serde_json::json!({"tokenColors":vec![rule.clone();10_001]})).unwrap();
    assert!(data.len() < MAX_FILE_BYTES);
    assert_eq!(parse_bytes(&data, "Theme", ID), Err(Error::TooComplex));
    for file in ["first.json", "second.json"] {
        directory.file(
            file,
            &serde_json::to_vec(&serde_json::json!({"tokenColors":vec![rule.clone();5_001]}))
                .unwrap(),
        );
    }
    let entry = directory.file(
        "merged.json",
        b"{\"include\":\"first.json\",\"tokenColors\":\"second.json\"}",
    );
    assert_eq!(preview_import(&entry), Err(Error::TooComplex));
    for index in 0..6 {
        let mut data = if index == 5 {
            br##"{"colors":{"editor.background":"#fff"}}"##.to_vec()
        } else {
            format!("{{\"include\":\"large{}.json\"}}", index + 1).into_bytes()
        };
        data.resize(800_000, b' ');
        directory.file(&format!("large{index}.json"), &data);
    }
    assert_eq!(
        preview_import(&directory.0.join("large0.json")),
        Err(Error::TooLarge)
    );
}
#[test]
fn xml_entities_external_dtd_namespaces_deep_trees_and_attribute_cycles_are_refused() {
    for xml in [
        "<!DOCTYPE scheme SYSTEM 'https://example.invalid/theme.dtd'><scheme parent_scheme='Default'/>",
        "<!DOCTYPE plist [<!ENTITY value 'expanded'>]><plist><dict/></plist>",
        "<!DOCTYPE plist SYSTEM 'https://example.invalid/theme.dtd'><plist><dict/></plist>",
        "<scheme xmlns='urn:foreign' parent_scheme='Default'/>",
        "<scheme parent_scheme='Unknown'/>",
        "<scheme><attributes><option name='TEXT' baseAttributes='TEXT'/></attributes></scheme>",
    ] {
        assert!(parse_bytes(xml.as_bytes(), "Theme", ID).is_err());
    }
    let xml = format!(
        "<scheme>{}<colors><option name='CARET_COLOR' value='fff'/></colors>{}</scheme>",
        "<nested>".repeat(33),
        "</nested>".repeat(33)
    );
    assert!(parse_bytes(xml.as_bytes(), "Theme", ID).is_err());
}
#[cfg(unix)]
#[test]
fn local_file_and_directory_symlink_escapes_are_refused() {
    use std::os::unix::fs::symlink;
    let directory = Directory::new();
    let outside = Directory::new();
    let target = outside.file(
        "external.json",
        br##"{"colors":{"editor.background":"#fff"}}"##,
    );
    symlink(&target, directory.0.join("link.json")).unwrap();
    assert_eq!(
        preview_import(&directory.0.join("link.json")),
        Err(Error::UnsafeReference)
    );
    let selected = directory.file("selected.json", b"{\"include\":\"link.json\"}");
    assert_eq!(preview_import(&selected), Err(Error::UnsafeReference));
    symlink(&outside.0, directory.0.join("folder")).unwrap();
    fs::write(&selected, b"{\"include\":\"folder/external.json\"}").unwrap();
    assert_eq!(preview_import(&selected), Err(Error::UnsafeReference));
}
