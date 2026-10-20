use super::*;
use std::path::PathBuf;
struct Fixture {
    root: PathBuf,
    store: WorkspaceStore,
}
impl Fixture {
    fn new() -> Self {
        let root = PathBuf::from(env!("CARGO_MANIFEST_DIR"))
            .join("../../build/gpui/restoration-tests")
            .join(new_uuid());
        let owner = DataDirectory::acquire(&root).unwrap();
        Self {
            root,
            store: WorkspaceStore::new(owner),
        }
    }
    fn path(&self) -> PathBuf {
        self.root.join("workspace.json")
    }
}
impl Drop for Fixture {
    fn drop(&mut self) {
        _ = fs::remove_dir_all(&self.root);
    }
}
fn document() -> StoredDocument {
    StoredDocument {
        id: new_uuid(),
        title: "Analysis.sql".into(),
        text: "SELECT 'κόσμος 😀';\r\n-- exact source\r\n".into(),
        profile_id: Some("legacy-profile-id".into()),
    }
}
fn snapshot() -> Snapshot {
    let document = document();
    Snapshot {
        selected_document_id: Some(document.id.clone()),
        documents: vec![document],
        ..Snapshot::default()
    }
}
fn entry(date: f64, index: usize) -> HistoryEntry {
    HistoryEntry {
        id: new_uuid(),
        date,
        document_id: None,
        profile_id: None,
        sql: format!("SELECT {index}"),
        outcome: "Completed".into(),
    }
}
#[test]
fn roundtrip_explicit_allowed_fields_preserves_opaque_binding_unicode_order_and_selection() {
    let f = Fixture::new();
    f.store.load().unwrap();
    let mut saved = snapshot();
    saved.documents.push(document());
    saved.history.push(entry(now_ms(), 1));
    f.store.reserve(saved.clone()).commit().unwrap();
    assert!(f.store.load().unwrap() == saved);
    let value: serde_json::Value = serde_json::from_slice(&fs::read(f.path()).unwrap()).unwrap();
    assert_eq!(
        value
            .as_object()
            .unwrap()
            .keys()
            .cloned()
            .collect::<HashSet<_>>(),
        [
            "version",
            "documents",
            "selectedDocumentID",
            "history",
            "historyEnabled"
        ]
        .map(String::from)
        .into()
    );
    assert_eq!(
        value["documents"][0]
            .as_object()
            .unwrap()
            .keys()
            .cloned()
            .collect::<HashSet<_>>(),
        ["id", "title", "text", "profileID"]
            .map(String::from)
            .into()
    );
    assert_eq!(
        value["history"][0]
            .as_object()
            .unwrap()
            .keys()
            .cloned()
            .collect::<HashSet<_>>(),
        ["id", "date", "sql", "outcome"].map(String::from).into()
    );
    #[cfg(unix)]
    {
        use std::os::unix::fs::PermissionsExt;
        assert_eq!(
            fs::metadata(f.path()).unwrap().permissions().mode() & 0o777,
            0o600
        );
        assert_eq!(
            fs::metadata(&f.root).unwrap().permissions().mode() & 0o777,
            0o700
        );
    }
}
#[test]
fn legacy_v0_migration_exact_backup_defaults_and_nonoverwriting_retry() {
    let f = Fixture::new();
    let mut value = serde_json::to_value(snapshot()).unwrap();
    value.as_object_mut().unwrap().remove("version");
    value.as_object_mut().unwrap().remove("history");
    value.as_object_mut().unwrap().remove("historyEnabled");
    let bytes = format!("{}\r\n", serde_json::to_string_pretty(&value).unwrap()).into_bytes();
    fs::write(f.path(), &bytes).unwrap();
    fs::write(f.root.join("workspace.json.v0.backup"), b"existing backup").unwrap();
    let saved = f.store.load().unwrap();
    assert_eq!(saved.version, VERSION);
    assert!(saved.history_enabled && saved.history.is_empty());
    assert_eq!(
        fs::read(f.root.join("workspace.json.v0.backup")).unwrap(),
        b"existing backup"
    );
    let backups = fs::read_dir(&f.root)
        .unwrap()
        .flatten()
        .filter(|e| {
            e.file_name()
                .to_string_lossy()
                .starts_with("workspace.json.v0-")
        })
        .collect::<Vec<_>>();
    assert_eq!(backups.len(), 1);
    assert_eq!(fs::read(backups[0].path()).unwrap(), bytes);
    #[cfg(unix)]
    {
        use std::os::unix::fs::PermissionsExt;
        assert_eq!(
            backups[0].metadata().unwrap().permissions().mode() & 0o777,
            0o600
        );
    }
}
#[test]
fn actual_v0_migration_protects_exact_source_history_backup_before_first_byte() {
    use crate::files::test_support::{Stage, with_preparation_hook};
    use std::sync::atomic::AtomicUsize;
    let f = Fixture::new();
    let mut old = snapshot();
    old.version = 0;
    let mut history = entry(now_ms(), 7);
    history.document_id = Some(old.documents[0].id.clone());
    history.profile_id = old.documents[0].profile_id.clone();
    old.history.push(history);
    let original = [
        b" \r\n".as_slice(),
        &serde_json::to_vec_pretty(&old).unwrap(),
        b"\r\n\t",
    ]
    .concat();
    #[cfg(windows)]
    let private = {
        use crate::files::test_support::windows;
        windows::set_broad_inheritance(&f.root);
        let mut source = windows::create_private(&f.path()).unwrap();
        source.write_all(&original).unwrap();
        source.sync_all().unwrap();
        let descriptor = windows::descriptor(&source);
        assert!(descriptor.starts_with("D:P(A;;FA;;;"));
        assert_eq!(descriptor.matches("(A;").count(), 1);
        descriptor
    };
    #[cfg(not(windows))]
    fs::write(f.path(), &original).unwrap();
    let backup = f.root.join("workspace.json.v0.backup");
    let seen = Arc::new(AtomicUsize::new(0));
    let observed = seen.clone();
    let expected = original.clone();
    let target = fs::canonicalize(backup.parent().unwrap())
        .unwrap()
        .join(backup.file_name().unwrap());
    #[cfg(windows)]
    let expected_private = private.clone();
    let migrated = with_preparation_hook(
        move |stage, path, temporary, retained| {
            if path != target {
                return Ok(());
            }
            #[cfg(windows)]
            assert_eq!(
                crate::files::test_support::windows::descriptor(retained),
                expected_private
            );
            #[cfg(unix)]
            {
                use std::os::unix::fs::PermissionsExt;
                assert_eq!(retained.metadata()?.permissions().mode() & 0o777, 0o600);
            }
            match stage {
                Stage::BeforeWrite => {
                    assert_eq!(retained.metadata()?.len(), 0);
                    observed.fetch_add(1, Ordering::SeqCst);
                }
                Stage::BeforeSync => {
                    assert_eq!(retained.metadata()?.len(), expected.len() as u64);
                    assert_eq!(fs::read(temporary)?, expected);
                    observed.fetch_add(1, Ordering::SeqCst);
                }
            }
            Ok(())
        },
        || f.store.load(),
    )
    .unwrap();
    assert_eq!(seen.load(Ordering::SeqCst), 2);
    assert_eq!(fs::read(&backup).unwrap(), original);
    old.version = VERSION;
    assert!(migrated == old);
    let restarted = WorkspaceStore::new(f.store.0.owner.clone()).load().unwrap();
    assert!(restarted == old);
    #[cfg(windows)]
    for path in [backup, f.path()] {
        assert_eq!(
            crate::files::test_support::windows::descriptor(&fs::File::open(path).unwrap()),
            private
        );
    }
}
#[test]
fn actual_v0_backup_fault_preserves_original_and_foreign_staging_identity() {
    use crate::files::test_support::{Stage, with_preparation_hook};
    for stage in [Stage::BeforeWrite, Stage::BeforeSync] {
        for replace in [false, true] {
            let f = Fixture::new();
            let mut old = snapshot();
            old.version = 0;
            old.history.push(entry(now_ms(), 8));
            let original = serde_json::to_vec_pretty(&old).unwrap();
            fs::write(f.path(), &original).unwrap();
            let backup = f.root.join("workspace.json.v0.backup");
            let target = fs::canonicalize(backup.parent().unwrap())
                .unwrap()
                .join(backup.file_name().unwrap());
            let moved = f.root.join("retained-backup-stage");
            let retained_path = moved.clone();
            let evidence = Arc::new(Mutex::new(None));
            let observed = evidence.clone();
            let result = with_preparation_hook(
                move |current, path, temporary, _| {
                    if path == target && current == stage {
                        if replace {
                            fs::rename(temporary, &retained_path)?;
                            fs::write(temporary, b"foreign workspace backup staging")?;
                            *observed.lock().unwrap() = Some((
                                temporary.to_path_buf(),
                                crate::files::open(temporary).unwrap().binding,
                            ));
                        }
                        return Err(std::io::Error::other("synthetic backup stage fault"));
                    }
                    Ok(())
                },
                || f.store.load(),
            );
            assert!(matches!(result, Err(StoreError::Write)));
            assert_eq!(fs::read(f.path()).unwrap(), original);
            assert!(!backup.exists());
            assert!(f.store.reserve(snapshot()).commit().is_err());
            if replace {
                let evidence = evidence.lock().unwrap();
                let (path, binding) = evidence.as_ref().unwrap();
                assert!(&crate::files::open(path).unwrap().binding == binding);
                assert_eq!(
                    fs::read(&moved).unwrap(),
                    if stage == Stage::BeforeWrite {
                        &[]
                    } else {
                        original.as_slice()
                    }
                );
            } else {
                assert!(
                    !fs::read_dir(&f.root)
                        .unwrap()
                        .flatten()
                        .any(|entry| { entry.file_name().to_string_lossy().ends_with(".tmp") })
                );
            }
            assert_eq!(f.store.load().unwrap().version, VERSION);
            assert_eq!(fs::read(backup).unwrap(), original);
            if let Some((path, binding)) = evidence.lock().unwrap().as_ref() {
                assert!(&crate::files::open(path).unwrap().binding == binding);
            }
        }
    }
}
#[test]
fn actual_v0_backup_refuses_a_late_foreign_destination_without_migrating() {
    use crate::files::test_support::{Stage, with_preparation_hook};
    let f = Fixture::new();
    let mut old = snapshot();
    old.version = 0;
    let original = serde_json::to_vec(&old).unwrap();
    fs::write(f.path(), &original).unwrap();
    let backup = f.root.join("workspace.json.v0.backup");
    let target = fs::canonicalize(backup.parent().unwrap())
        .unwrap()
        .join(backup.file_name().unwrap());
    let evidence = Arc::new(Mutex::new(None));
    let observed = evidence.clone();
    let result = with_preparation_hook(
        move |stage, path, _, _| {
            if path == target && stage == Stage::BeforeWrite {
                fs::write(path, b"late foreign workspace backup")?;
                *observed.lock().unwrap() = Some(crate::files::open(path).unwrap().binding);
            }
            Ok(())
        },
        || f.store.load(),
    );
    assert!(matches!(result, Err(StoreError::Write)));
    assert_eq!(fs::read(f.path()).unwrap(), original);
    assert!(Some(crate::files::open(&backup).unwrap().binding) == *evidence.lock().unwrap());
    assert!(f.store.reserve(snapshot()).commit().is_err());
    assert_eq!(f.store.load().unwrap().version, VERSION);
    assert!(Some(crate::files::open(&backup).unwrap().binding) == *evidence.lock().unwrap());
}
#[test]
fn invalid_corrupt_future_duplicate_unknown_and_incomplete_files_survive_load_and_save() {
    let mut future = serde_json::to_value(snapshot()).unwrap();
    future["version"] = 9.into();
    let mut secret = serde_json::to_value(snapshot()).unwrap();
    secret["password"] = "never allowed".into();
    let mut duplicate = snapshot();
    duplicate.documents.push(duplicate.documents[0].clone());
    let mut invalid = snapshot();
    invalid.documents[0].id = "not-a-uuid".into();
    let cases = [
        b"broken JSON".to_vec(),
        serde_json::to_vec(&future).unwrap(),
        serde_json::to_vec(&secret).unwrap(),
        serde_json::to_vec(&duplicate).unwrap(),
        serde_json::to_vec(&invalid).unwrap(),
        br#"{"documents":[],"documents":[]}"#.to_vec(),
        vec![b' '; 1024 * 1024],
    ];
    for bytes in cases {
        let f = Fixture::new();
        fs::write(f.path(), &bytes).unwrap();
        assert!(f.store.load().is_err());
        assert!(f.store.reserve(snapshot()).commit().is_err());
        assert_eq!(fs::read(f.path()).unwrap(), bytes);
    }
}
#[test]
fn atomic_failure_preserves_previous_source_cleans_temp_and_can_retry() {
    let f = Fixture::new();
    f.store.load().unwrap();
    f.store.reserve(snapshot()).commit().unwrap();
    let original = fs::read(f.path()).unwrap();
    f.store.fail_replacement(true);
    assert_eq!(f.store.reserve(snapshot()).commit(), Err(StoreError::Write));
    assert_eq!(fs::read(f.path()).unwrap(), original);
    assert!(
        !fs::read_dir(&f.root)
            .unwrap()
            .flatten()
            .any(|e| e.file_name().to_string_lossy().ends_with(".tmp"))
    );
    f.store.fail_replacement(false);
    let latest = snapshot();
    f.store.reserve(latest.clone()).commit().unwrap();
    assert!(f.store.load().unwrap() == latest);
}
#[test]
fn failed_migration_preserves_exact_source_and_retry_has_nonoverwriting_backup() {
    let f = Fixture::new();
    let mut old = snapshot();
    old.version = 0;
    let bytes = serde_json::to_vec(&old).unwrap();
    fs::write(f.path(), &bytes).unwrap();
    f.store.fail_replacement(true);
    assert!(f.store.load().is_err());
    assert_eq!(fs::read(f.path()).unwrap(), bytes);
    assert!(f.store.reserve(snapshot()).commit().is_err());
    f.store.fail_replacement(false);
    assert_eq!(f.store.load().unwrap().version, 1);
    assert_eq!(
        fs::read(f.root.join("workspace.json.v0.backup")).unwrap(),
        bytes
    );
}
#[test]
fn final_flush_waits_for_owner_and_supersedes_delayed_older_writers() {
    let f = Fixture::new();
    f.store.load().unwrap();
    let old = f.store.reserve(snapshot());
    let latest = snapshot();
    let final_write = f.store.reserve(latest.clone());
    let owner = f.store.0.owner.clone();
    let locked = owner.mutation().unwrap();
    let (tx, rx) = std::sync::mpsc::channel();
    let worker = std::thread::spawn(move || {
        tx.send(final_write.commit()).unwrap();
    });
    assert!(
        rx.recv_timeout(std::time::Duration::from_millis(30))
            .is_err()
    );
    drop(locked);
    assert_eq!(
        rx.recv_timeout(std::time::Duration::from_secs(2)).unwrap(),
        Ok(())
    );
    worker.join().unwrap();
    old.commit().unwrap();
    assert!(f.store.load().unwrap() == latest);
}
#[test]
fn stale_external_changes_and_new_corruption_are_never_overwritten() {
    let f = Fixture::new();
    f.store.load().unwrap();
    f.store.reserve(snapshot()).commit().unwrap();
    let request = f.store.reserve(snapshot());
    let external = serde_json::to_vec(&snapshot()).unwrap();
    fs::write(f.path(), &external).unwrap();
    assert_eq!(request.commit(), Err(StoreError::Conflict));
    assert_eq!(fs::read(f.path()).unwrap(), external);
    fs::write(f.path(), b"corrupt after load").unwrap();
    assert!(f.store.reserve(snapshot()).commit().is_err());
    assert_eq!(fs::read(f.path()).unwrap(), b"corrupt after load");
}
#[test]
fn write_request_retains_data_ownership_and_releases_it_only_after_drop() {
    let root = PathBuf::from(env!("CARGO_MANIFEST_DIR"))
        .join("../../build/gpui/restoration-tests")
        .join(new_uuid());
    let store = WorkspaceStore::new(DataDirectory::acquire(&root).unwrap());
    store.load().unwrap();
    let request = store.reserve(snapshot());
    drop(store);
    assert!(DataDirectory::acquire(&root).is_err());
    request.commit().unwrap();
    let owner = DataDirectory::acquire(&root).expect("Last writer released its ownership guard.");
    drop(owner);
    fs::remove_dir_all(root).unwrap();
}

#[test]
fn history_retention_stable_ties_disabled_clear_and_exact_reference_outcomes() {
    let now = now_ms();
    let mut s = Snapshot {
        history: (0..1_010).map(|i| entry(now, i)).collect(),
        ..Snapshot::default()
    };
    s.history.push(entry(now - RETENTION_MS - 1., 9999));
    s.trim(now);
    assert_eq!(s.history.len(), 1000);
    assert_eq!(s.history[0].sql, "SELECT 10");
    assert_eq!(s.history[999].sql, "SELECT 1009");
    s.history_enabled = false;
    s.record(entry(now, 9999), now);
    assert_eq!(s.history[999].sql, "SELECT 1009");
    s.history.clear();
    s.record(entry(now, 0), now);
    assert!(s.history.is_empty());
    assert_eq!(failure_outcome("transport", true), "Unknown outcome");
    assert_eq!(failure_outcome("timeout", false), "Query timed out");
    assert_eq!(failure_outcome("cancelled", false), "Query cancelled");
    assert_eq!(failure_outcome("sql", false), "Query failed");
}
#[cfg(unix)]
#[test]
fn symlink_workspace_never_reads_or_replaces_unrelated_file() {
    use std::os::unix::fs::symlink;
    let f = Fixture::new();
    let unrelated = f.root.join("unrelated.sql");
    fs::write(&unrelated, b"SELECT 1;").unwrap();
    symlink(&unrelated, f.path()).unwrap();
    assert!(f.store.load().is_err());
    assert!(f.store.reserve(snapshot()).commit().is_err());
    assert_eq!(fs::read(&unrelated).unwrap(), b"SELECT 1;");
}
#[cfg(windows)]
#[test]
fn windows_locked_workspace_preserves_previous_state_for_retry() {
    use std::os::windows::fs::OpenOptionsExt;
    let f = Fixture::new();
    f.store.load().unwrap();
    f.store.reserve(snapshot()).commit().unwrap();
    let bytes = fs::read(f.path()).unwrap();
    let lock = OpenOptions::new()
        .read(true)
        .share_mode(1)
        .open(f.path())
        .unwrap();
    assert!(f.store.reserve(snapshot()).commit().is_err());
    drop(lock);
    assert_eq!(fs::read(f.path()).unwrap(), bytes);
    f.store.reserve(snapshot()).commit().unwrap();
}

#[test]
fn accepted_large_sources_and_aggregate_history_round_trip_without_shutdown_cap() {
    let f = Fixture::new();
    f.store.load().unwrap();
    let mut state = snapshot();
    state.documents[0].text = "x".repeat(8 * 1024 * 1024 + 1);
    let mut other = document();
    other.text = "y".repeat(33 * 1024 * 1024);
    state.documents.push(other);
    let mut entry = entry(now_ms(), 1);
    entry.sql = "z".repeat(33 * 1024 * 1024);
    state.history = vec![entry];
    f.store.reserve(state.clone()).commit().unwrap();
    assert!(fs::metadata(f.path()).unwrap().len() > 64 * 1024 * 1024);
    let restart = WorkspaceStore::new(f.store.0.owner.clone());
    assert!(restart.load().unwrap() == state);
    // A normal second final flush/manual-save retry remains valid too.
    restart.reserve(state.clone()).commit().unwrap();
    assert!(restart.load().unwrap() == state);
}
#[test]
fn workspace_refuses_to_publish_or_delete_a_foreign_temporary() {
    let f = Fixture::new();
    f.store.load().unwrap();
    f.store.reserve(snapshot()).commit().unwrap();
    let original = fs::read(f.path()).unwrap();
    let foreign = std::cell::RefCell::new(None);
    let result = f.store.reserve(snapshot()).commit_with(|prepared| {
        let temporary = prepared.temporary_path().to_owned();
        fs::rename(&temporary, f.root.join("detached-owned.tmp")).unwrap();
        fs::write(&temporary, b"foreign synthetic file").unwrap();
        *foreign.borrow_mut() = Some(temporary);
    });
    assert_eq!(result, Err(StoreError::Write));
    assert_eq!(fs::read(f.path()).unwrap(), original);
    assert_eq!(
        fs::read(foreign.into_inner().unwrap()).unwrap(),
        b"foreign synthetic file"
    );
}
