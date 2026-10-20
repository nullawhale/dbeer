//! Prepared real cleanup-path regressions; no database or helper is started.
use super::*;

fn output() -> (FileFixture, PathBuf) {
    let mut fixture = FileFixture::new().unwrap();
    let path = fixture.destination("full.json").unwrap();
    let mut file = create_file(&path, false).unwrap();
    file.write_all(b"owned synthetic export output").unwrap();
    file.sync_all().unwrap();
    drop(file);
    fixture.capture_output("full.json").unwrap();
    (fixture, path)
}

#[test]
fn export_fixture_removes_only_its_original_captured_output_and_empty_root() {
    let (mut fixture, path) = output();
    let root = path.parent().unwrap().to_path_buf();
    fixture.cleanup().unwrap();
    assert!(!root.exists());
}

#[test]
fn export_fixture_foreign_entry_refuses_before_deleting_original_output() {
    let (mut fixture, path) = output();
    let root = path.parent().unwrap().to_path_buf();
    let foreign = root.join("foreign.txt");
    let mut file = create_file(&foreign, false).unwrap();
    file.write_all(b"preserve foreign fixture entry").unwrap();
    drop(file);
    assert!(fixture.cleanup().is_err());
    assert_eq!(
        fs::read(&foreign).unwrap(),
        b"preserve foreign fixture entry"
    );
    assert_eq!(fs::read(&path).unwrap(), b"owned synthetic export output");
    drop(fixture);
    // The regression itself created these exact synthetic entries.
    fs::remove_file(foreign).unwrap();
    fs::remove_file(path).unwrap();
    fs::remove_dir(root).unwrap();
}

#[cfg(unix)]
#[test]
fn export_fixture_same_byte_file_replacement_is_preserved() {
    let (mut fixture, path) = output();
    let original = path
        .parent()
        .unwrap()
        .with_extension("retained-original.json");
    fs::rename(&path, &original).unwrap();
    let mut replacement = create_file(&path, false).unwrap();
    replacement
        .write_all(b"owned synthetic export output")
        .unwrap();
    drop(replacement);
    assert!(fixture.cleanup().is_err());
    assert_eq!(fs::read(&path).unwrap(), b"owned synthetic export output");
    assert_eq!(
        fs::read(&original).unwrap(),
        b"owned synthetic export output"
    );
    let root = path.parent().unwrap().to_path_buf();
    drop(fixture);
    fs::remove_file(path).unwrap();
    fs::remove_file(original).unwrap();
    fs::remove_dir(root).unwrap();
}

#[cfg(unix)]
#[test]
fn export_fixture_regular_directory_replacement_preserves_both_trees() {
    let (mut fixture, path) = output();
    let root = path.parent().unwrap().to_path_buf();
    let retained = root.with_extension("retained-original");
    fs::rename(&root, &retained).unwrap();
    create_directory(&root).unwrap();
    let foreign = root.join("foreign.txt");
    let mut file = create_file(&foreign, false).unwrap();
    file.write_all(b"preserve replacement directory").unwrap();
    drop(file);
    assert!(fixture.cleanup().is_err());
    assert_eq!(
        fs::read(&foreign).unwrap(),
        b"preserve replacement directory"
    );
    assert_eq!(
        fs::read(retained.join("full.json")).unwrap(),
        b"owned synthetic export output"
    );
    drop(fixture);
    fs::remove_file(foreign).unwrap();
    fs::remove_dir(root).unwrap();
    fs::remove_file(retained.join("full.json")).unwrap();
    fs::remove_dir(retained).unwrap();
}

#[cfg(windows)]
#[test]
fn export_fixture_held_native_handles_deny_file_and_root_replacement() {
    let (mut fixture, path) = output();
    let root = path.parent().unwrap().to_path_buf();
    assert!(fs::rename(&path, root.join("replacement.json")).is_err());
    assert!(fs::rename(&root, root.with_extension("replacement")).is_err());
    fixture.cleanup().unwrap();
    assert!(!root.exists());
}
