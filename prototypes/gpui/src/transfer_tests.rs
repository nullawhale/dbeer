use super::*;
use serde_json::{Value, json};
use std::path::PathBuf;

const STAGES: [&[u8]; 4] = [
    include_bytes!("../../../protocol/fixtures/profile-transfer/mac-export-v2.json"),
    include_bytes!("../../../protocol/fixtures/profile-transfer/windows-remapped-v2.json"),
    include_bytes!("../../../protocol/fixtures/profile-transfer/linux-remapped-v2.json"),
    include_bytes!("../../../protocol/fixtures/profile-transfer/mac-return-v2.json"),
];
fn directory() -> PathBuf {
    let path = PathBuf::from(env!("CARGO_MANIFEST_DIR"))
        .join("../../build/gpui/transfer-tests")
        .join(ConnectionProfile::new().id);
    fs::create_dir_all(&path).unwrap();
    path
}
#[test]
fn shared_roundtrip_stages_preserve_engine_tls_policy_and_allocate_fresh_ids() {
    let mut seen = std::collections::HashSet::new();
    for bytes in STAGES {
        let rows = preview(bytes).unwrap();
        assert_eq!(rows.len(), 3);
        assert!(rows.iter().all(|row| seen.insert(row.profile.id.clone())));
        assert_eq!(rows[0].profile.engine, "postgresql");
        assert_eq!(rows[0].profile.ssl_mode, "verify-full");
        assert_eq!(rows[0].profile.environment, "production");
        assert!(rows[0].profile.readonly);
        assert_eq!(rows[1].profile.engine, "mysql");
        assert_eq!(rows[1].profile.ssl_mode, "verify-ca");
        assert_eq!(rows[1].profile.environment, "staging");
        assert!(!rows[1].profile.readonly);
        assert_eq!(rows[2].profile.port, 65535);
        assert_eq!(rows[2].profile.ssl_root_cert, None);
        let profiles = rows.into_iter().map(|p| p.profile).collect::<Vec<_>>();
        let encoded = encode(&profiles).unwrap();
        let json: Value = serde_json::from_slice(&encoded).unwrap();
        let source: Value = serde_json::from_slice(bytes).unwrap();
        assert_eq!(json, source);
        for p in &profiles {
            assert!(!String::from_utf8_lossy(&encoded).contains(&p.id));
        }
        assert!(!String::from_utf8_lossy(&encoded).contains("password"));
        assert!(!String::from_utf8_lossy(&encoded).contains("privateKey"));
    }
}
#[test]
fn shared_legacy_transfer_omissions_use_swift_defaults_not_gpui_library_defaults() {
    let rows = preview(include_bytes!(
        "../../../protocol/fixtures/profile-transfer/legacy-v1.json"
    ))
    .unwrap();
    assert_eq!(rows[0].profile.environment, "unspecified");
    assert!(!rows[0].profile.readonly);
    assert_eq!(rows[1].profile.environment, "development");
    assert!(rows[1].profile.readonly);
    assert_eq!(rows[2].profile.environment, "unspecified");
    assert!(!rows[2].profile.readonly);
    assert!(
        preview(&encode(&rows.into_iter().map(|r| r.profile).collect::<Vec<_>>()).unwrap()).is_ok()
    );
}
#[test]
fn shared_malformed_files_reject_secrets_duplicates_types_depth_and_unknown_fields() {
    let root = PathBuf::from(env!("CARGO_MANIFEST_DIR"))
        .join("../../protocol/fixtures/profile-transfer/invalid");
    let mut count = 0;
    for entry in fs::read_dir(root).unwrap() {
        let bytes = fs::read(entry.unwrap().path()).unwrap();
        assert!(
            preview(&bytes).is_err(),
            "Malformed transfer fixture accepted"
        );
        count += 1;
    }
    assert!(count >= 25);
}
#[test]
fn every_engine_mode_and_explicit_policy_survives_transfer_and_limits_are_enforced() {
    let mut profiles = Vec::new();
    for engine in ["postgresql", "mysql"] {
        let mut p = ConnectionProfile::new();
        p.engine = engine.into();
        for mode in p.ssl_modes() {
            for environment in ["unspecified", "development", "staging", "production"] {
                for readonly in [false, true] {
                    let mut p = p.clone();
                    p.ssl_mode = (*mode).into();
                    p.environment = environment.into();
                    p.readonly = readonly;
                    profiles.push(p);
                }
            }
        }
    }
    let rows = preview(&encode(&profiles).unwrap()).unwrap();
    for (source, row) in profiles.iter().zip(rows) {
        let mut p = row.profile;
        p.id = source.id.clone();
        assert_eq!(&p, source);
    }
    let mut p = ConnectionProfile::new();
    p.name = "e\u{301}".repeat(128);
    assert!(
        encode(&[p.clone()]).is_ok(),
        "Name limit is graphemes, matching Swift"
    );
    p.name.push('x');
    assert!(encode(&[p]).is_err());
    assert!(preview(&vec![b' '; MAX_BYTES + 1]).is_err());
    assert!(encode(&[]).is_err());
    assert!(encode(&vec![ConnectionProfile::new(); MAX_PROFILES + 1]).is_err());
    let mut value: Value = serde_json::from_slice(STAGES[0]).unwrap();
    for port in [
        json!(-1),
        json!(65536),
        json!(1.5),
        json!("5432"),
        Value::Null,
        json!(true),
    ] {
        value["profiles"][0]["port"] = port;
        assert!(preview(&serde_json::to_vec(&value).unwrap()).is_err());
    }
}
#[test]
fn ca_hints_are_syntax_only_foreign_paths_require_explicit_remap_and_tls_is_unchanged() {
    for path in [
        "/ca/team.pem",
        r"C:\CA\team.pem",
        "C:/CA/team.pem",
        r"\\server\public-ca\team.pem",
    ] {
        assert!(valid_ca_hint(path));
    }
    for path in [
        "",
        "ca.pem",
        r"C:ca.pem",
        r"\ca.pem",
        r"\\server",
        r"\\?\C:\ca.pem",
        r"\\.\device\ca.pem",
        "https://example.test/ca.pem",
        "bad\0path",
    ] {
        assert!(!valid_ca_hint(path));
    }
    let mut row = preview(STAGES[1]).unwrap().remove(1); // UNC is never probed automatically.
    assert!(row.requires_ca());
    let before = row.clone();
    assert!(row.remap_ca(Path::new("relative.pem")).is_err());
    assert_eq!(row, before);
    let root = directory();
    assert!(row.remap_ca(&root).is_err());
    let ca = root.join("ca.pem");
    fs::write(&ca, "public CA fixture").unwrap();
    row.remap_ca(&ca).unwrap();
    assert!(!row.requires_ca());
    assert_eq!(row.profile.ssl_mode, "verify-ca");
    assert_eq!(row.profile.environment, "staging");
    fs::remove_file(&ca).unwrap();
    assert!(row.requires_ca());
    fs::remove_dir_all(root).unwrap();
}
#[test]
fn bounded_reader_and_atomic_export_preserve_old_destination_on_failure_and_cleanup() {
    let root = directory();
    let dest = root.join("profiles.json");
    fs::write(&dest, "original").unwrap();
    assert!(write_atomic(b"invalid", &dest).is_err());
    assert_eq!(fs::read(&dest).unwrap(), b"original");
    write_atomic(STAGES[0], &dest).unwrap();
    assert_eq!(fs::read(&dest).unwrap(), STAGES[0]);
    assert_eq!(read_preview(&dest).unwrap().len(), 3);
    let occupied = root.join("occupied");
    fs::create_dir(&occupied).unwrap();
    assert!(write_atomic(STAGES[0], &occupied).is_err());
    assert!(occupied.is_dir());
    assert_eq!(fs::read_dir(&root).unwrap().count(), 2);
    #[cfg(unix)]
    {
        use std::os::unix::fs::PermissionsExt;
        assert_eq!(
            fs::metadata(&dest).unwrap().permissions().mode() & 0o777,
            0o600
        );
        let link = root.join("link");
        std::os::unix::fs::symlink(&dest, &link).unwrap();
        assert!(read_preview(&link).is_err());
    }
    fs::write(&dest, vec![b' '; MAX_BYTES + 1]).unwrap();
    assert!(read_preview(&dest).is_err());
    assert!(read_preview(&occupied).is_err());
    fs::remove_dir_all(root).unwrap();
}

#[test]
fn captured_export_refuses_a_changed_or_newly_appeared_target_and_foreign_temporary() {
    let root = directory();
    let bytes = encode(&[ConnectionProfile::new()]).unwrap();
    for existing in [false, true] {
        let target = root.join(if existing {
            "existing.json"
        } else {
            "absent.json"
        });
        if existing {
            fs::write(&target, b"original synthetic file").unwrap();
        }
        let capture = crate::files::CapturedDestination::capture(&target).unwrap();
        fs::write(&target, b"external synthetic replacement").unwrap();
        assert!(write_captured(&bytes, &target, &capture).is_err());
        assert_eq!(
            fs::read(&target).unwrap(),
            b"external synthetic replacement"
        );
    }
    let target = root.join("temporary.json");
    fs::write(&target, b"original").unwrap();
    let capture = crate::files::CapturedDestination::capture(&target).unwrap();
    let prepared = prepare_captured(&bytes, &target, &capture).unwrap();
    let temporary = prepared.temporary_path().to_owned();
    fs::rename(&temporary, root.join("detached-owned.tmp")).unwrap();
    fs::write(&temporary, b"foreign temporary").unwrap();
    assert!(prepared.publish().is_err());
    assert_eq!(fs::read(&target).unwrap(), b"original");
    assert_eq!(fs::read(&temporary).unwrap(), b"foreign temporary");
    fs::remove_dir_all(root).unwrap();
}

#[cfg(unix)]
#[test]
fn captured_absent_export_refuses_a_replaced_parent_directory() {
    let root = directory();
    let parent = root.join("parent");
    fs::create_dir(&parent).unwrap();
    let target = parent.join("profiles.json");
    let capture = crate::files::CapturedDestination::capture(&target).unwrap();
    fs::rename(&parent, root.join("detached-owned-parent")).unwrap();
    fs::create_dir(&parent).unwrap();
    let bytes = encode(&[ConnectionProfile::new()]).unwrap();
    assert!(write_captured(&bytes, &target, &capture).is_err());
    assert!(!target.exists());
    assert!(fs::read_dir(&parent).unwrap().next().is_none());
    fs::remove_dir_all(root).unwrap();
}
