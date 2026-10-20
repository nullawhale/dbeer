//! Prepared pure/file fault cases. Execute only at final integration.
use super::*;
use crate::backend::ResultSet;
use serde_json::Value;
use std::fs;

fn sets(value: &Value) -> Vec<ResultSet> {
    value["resultSets"]
        .as_array()
        .unwrap()
        .iter()
        .map(|set| {
            let mut flat = set["metadata"].clone();
            flat["rows"] = set["rows"].clone();
            serde_json::from_value(flat).unwrap()
        })
        .collect()
}
#[test]
fn frozen_shared_full_export_fixture_matches_without_modifying_the_baseline() {
    let fixture: Value =
        serde_json::from_str(include_str!("../../../../protocol/fixtures/export.json")).unwrap();
    assert_eq!(
        serde_json::from_str::<Value>(&json(&sets(&fixture)).unwrap()).unwrap(),
        fixture
    );
}
#[test]
fn shared_loaded_fixture_keeps_metadata_duplicates_exact_values_unicode_and_csv_bytes() {
    let fixture: Value = serde_json::from_str(include_str!(
        "../../../../protocol/fixtures/loaded-export-v1.json"
    ))
    .unwrap();
    let results = sets(&fixture);
    let actual: Value = serde_json::from_str(&json(&results).unwrap()).unwrap();
    assert_eq!(actual["resultSets"], fixture["resultSets"]);
    assert_eq!(actual["version"], 1);
    for (i, set) in results.iter().enumerate() {
        assert_eq!(
            csv(set, fixture["nullMarker"].as_str().unwrap())
                .unwrap()
                .as_bytes(),
            fixture["csv"][i].as_str().unwrap().as_bytes()
        );
    }
    for marker in ["", "\\N", "NULL", "", "AP8=", "9007199254740993.123456789"] {
        assert!(csv(&results[0], marker).is_err());
    }
    let quoted_marker = "marker,\"\r\n";
    assert!(
        csv(&results[0], quoted_marker)
            .unwrap()
            .contains("\"marker,\"\"\r\n\"")
    );
    assert_eq!(
        Format::Json.suggested_name("test.sql", 4),
        "test.sql-loaded-4-rows.json"
    );
    assert_eq!(
        Format::Csv.suggested_name("safe/path", 0),
        "safe_path-loaded-0-rows.csv"
    );
}
#[test]
fn malformed_ordinals_width_display_count_and_signed_range_are_refused_before_write() {
    let fixture: Value = serde_json::from_str(include_str!(
        "../../../../protocol/fixtures/loaded-export-v1.json"
    ))
    .unwrap();
    for variant in 0..4 {
        let mut s = sets(&fixture).remove(0);
        match variant {
            0 => s.columns[0].index = 3,
            1 => {
                s.rows[0].pop();
            }
            2 => s.displayed_row_count += 1,
            _ => s.row_count = u64::MAX,
        }
        assert!(json(std::slice::from_ref(&s)).is_err());
        assert!(csv(&s, "safe").is_err());
    }
}
#[test]
fn large_values_and_all_loaded_rows_have_no_local_projection_or_extra_cutoff() {
    let fixture: Value = serde_json::from_str(include_str!(
        "../../../../protocol/fixtures/loaded-export-v1.json"
    ))
    .unwrap();
    let mut set = sets(&fixture).remove(0);
    let large = "caf\u{e9}\u{1f642}\r\n".repeat(65_536);
    set.rows = (0..1000)
        .map(|n| {
            vec![
                Some(n.to_string()),
                Some(String::new()),
                Some(if n == 999 {
                    large.clone()
                } else {
                    "AP8=".into()
                }),
            ]
        })
        .collect();
    set.displayed_row_count = 1000;
    let output: Value = serde_json::from_str(&json(&[set.clone()]).unwrap()).unwrap();
    assert_eq!(
        output["resultSets"][0]["rows"].as_array().unwrap().len(),
        1000
    );
    assert_eq!(
        output["resultSets"][0]["rows"][999][2].as_str().unwrap(),
        large
    );
    assert!(csv(&set, "safe").unwrap().ends_with("\"\r\n"));
}
struct Fixture(std::path::PathBuf);
impl Fixture {
    fn new() -> Self {
        let root = std::path::PathBuf::from(env!("CARGO_MANIFEST_DIR"))
            .join("../../build/gpui/export-tests")
            .join(uuid::Uuid::new_v4().to_string());
        fs::create_dir_all(&root).unwrap();
        Self(fs::canonicalize(root).unwrap())
    }
    fn prepare(&self, name: &str, bytes: &str) -> Result<PreparedExport, ExportError> {
        let path = self.0.join(name);
        let captured = crate::files::CapturedDestination::capture(&path)?;
        PreparedExport::prepare(Arc::from(bytes), &path, &captured)
    }
    fn clean(&self) {
        assert_eq!(fs::read_dir(&self.0).unwrap().count(), 1);
    }
}
impl Drop for Fixture {
    fn drop(&mut self) {
        _ = fs::remove_dir_all(&self.0);
    }
}
#[test]
fn cancelled_preparation_stale_destination_encoding_and_replace_failures_preserve_original() {
    let f = Fixture::new();
    let path = f.0.join("loaded.csv");
    fs::write(&path, "original").unwrap();
    drop(f.prepare("loaded.csv", "cancelled").unwrap());
    f.clean();
    assert_eq!(fs::read_to_string(&path).unwrap(), "original");
    let destination = crate::files::CapturedDestination::capture(&path).unwrap();
    fs::write(&path, "external edit").unwrap();
    assert!(PreparedExport::prepare(Arc::from("new"), &path, &destination).is_err());
    let prepared = f.prepare("loaded.csv", "replacement").unwrap();
    fs::write(&path, "newer external edit").unwrap();
    assert!(prepared.publish().is_err());
    f.clean();
    assert_eq!(fs::read_to_string(&path).unwrap(), "newer external edit");
    let missing = f.0.join("absent.csv");
    let destination = crate::files::CapturedDestination::capture(&missing).unwrap();
    fs::write(&missing, "appeared").unwrap();
    assert!(PreparedExport::prepare(Arc::from("new"), &missing, &destination).is_err());
    assert_eq!(fs::read_to_string(&missing).unwrap(), "appeared");
}
#[test]
fn cooperative_locked_destination_is_refused_and_source_clean_state_is_not_owned() {
    let f = Fixture::new();
    let path = f.0.join("loaded.json");
    fs::write(&path, "original").unwrap();
    let locked = fs::File::open(&path).unwrap();
    locked.lock().unwrap();
    assert!(f.prepare("loaded.json", "new").is_err());
    assert_eq!(fs::read_to_string(&path).unwrap(), "original");
    f.clean();
}
#[cfg(windows)]
#[test]
fn windows_native_deny_sharing_prevents_export_without_changing_destination() {
    use std::os::windows::fs::OpenOptionsExt;
    let f = Fixture::new();
    let path = f.0.join("loaded.json");
    fs::write(&path, "original").unwrap();
    let locked = fs::OpenOptions::new()
        .read(true)
        .share_mode(0)
        .open(&path)
        .unwrap();
    assert!(f.prepare("loaded.json", "replacement").is_err());
    drop(locked);
    assert_eq!(fs::read_to_string(&path).unwrap(), "original");
    f.clean();
}
