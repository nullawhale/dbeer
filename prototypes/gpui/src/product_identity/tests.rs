use super::*;
use std::{
    fs,
    io::{BufRead, BufReader, Write},
    path::Path,
    process::{Command, Stdio},
    time::{SystemTime, UNIX_EPOCH},
};

fn identity() -> BuildIdentity {
    BuildIdentity::parse(include_bytes!(
        "../../fixtures/packaging/build-identity.json"
    ))
    .unwrap()
}

#[test]
fn wire_version_alone_never_accepts_an_old_or_different_helper() {
    let gui = identity();
    let capabilities = vec![REQUIRED_CAPABILITY.to_owned()];
    assert!(
        gui.require_matching_helper(Some(&gui), 3, &capabilities)
            .is_ok()
    );
    assert!(gui.require_matching_helper(None, 3, &capabilities).is_err());
    assert!(gui.require_matching_helper(Some(&gui), 3, &[]).is_err());
    assert!(
        gui.require_matching_helper(Some(&gui), 2, &capabilities)
            .is_err()
    );
    for field in [
        "version",
        "build",
        "source",
        "contract",
        "capability",
        "target",
    ] {
        let mut helper = gui.clone();
        match field {
            "version" => helper.version = "0.0.1".into(),
            "build" => helper.build_number = "999".into(),
            "source" => helper.source_sha256 = "b".repeat(64),
            "contract" => helper.contract_revision = "old-v3".into(),
            "capability" => helper.capabilities.clear(),
            "target" => helper.target = NativeTarget::WindowsX64,
            _ => unreachable!(),
        }
        assert!(
            gui.require_matching_helper(Some(&helper), 3, &capabilities)
                .is_err()
        );
    }
}

#[test]
fn strict_metadata_rejects_duplicate_unknown_and_invalid_release_fields() {
    let original = include_str!("../../fixtures/packaging/build-identity.json");
    for invalid in [
        original.replacen(
            "\"schemaVersion\":1",
            "\"schemaVersion\":1,\"schemaVersion\":1",
            1,
        ),
        original.replacen(
            "\"schemaVersion\":1",
            "\"schemaVersion\":1,\"password\":\"absent\"",
            1,
        ),
        original.replace("capturedExportV1", "legacyExport"),
        original.replace("linux-x86_64-gnu", "linux-aarch64-gnu"),
        original.replace("\"buildNumber\":\"1\"", "\"buildNumber\":\"01\""),
    ] {
        assert!(BuildIdentity::parse(invalid.as_bytes()).is_err());
    }
    assert!(BuildIdentity::parse(&[b' '; 4097]).is_err());
}

#[test]
fn canonical_embedded_marker_is_sorted_ascii_without_file_newline() {
    let expected =
        include_str!("../../../../protocol/fixtures/gpui-build-identity-v1/valid-linux.json");
    let value = identity().canonical_json().unwrap();
    assert_eq!(format!("{value}\n"), expected);
    assert!(value.is_ascii());
    assert!(!value.contains('\n'));
}

#[test]
fn native_architecture_normalizes_only_supported_toolchain_targets() {
    for architecture in ["x86_64", "amd64"] {
        assert_eq!(
            NativeTarget::from_native("windows", architecture, "msvc"),
            Some(NativeTarget::WindowsX64)
        );
        assert_eq!(
            NativeTarget::from_native("linux", architecture, "gnu"),
            Some(NativeTarget::UbuntuX64)
        );
    }
    for (os, architecture, abi) in [
        ("macos", "x86_64", "gnu"),
        ("linux", "arm64", "gnu"),
        ("linux", "amd64", "musl"),
        ("windows", "amd64", "gnu"),
    ] {
        assert!(NativeTarget::from_native(os, architecture, abi).is_none());
    }
}

#[test]
fn fixtures_are_explicit_and_product_restoration_is_always_disconnected() {
    for platform in [Platform::Windows, Platform::Linux, Platform::MacDevelopment] {
        for explicit in [false, true] {
            let policy = StartupPolicy::new(platform, explicit);
            assert!(policy.restore_disconnected);
            assert_eq!(
                policy.built_in_fixtures,
                platform == Platform::MacDevelopment && explicit
            );
        }
    }
    // A saved opaque ID is never inspected for a presentation/demo prefix.
    let mut profile = crate::connections::ConnectionProfile::new();
    profile.id = "demo-brewery".to_owned();
    let saved = crate::model::ProfileId::saved(&profile);
    assert_ne!(saved, crate::model::ProfileId::demo("brewery"));
    assert_eq!(CREDENTIAL_SERVICE, "dev.dbeer.gpui-prototype");
}

#[test]
fn product_path_retains_the_actual_legacy_root() {
    let platform = Platform::current().unwrap();
    assert_eq!(
        compatible_library_path(platform, |name| std::env::var_os(name)).unwrap(),
        crate::connections::ProfileStore::default_path().unwrap()
    );
    #[cfg(unix)]
    {
        let path = compatible_library_path(Platform::Linux, |name| match name {
            "XDG_CONFIG_HOME" => Some("relative-is-ignored".into()),
            "HOME" => Some("/home/fixture-owner".into()),
            _ => None,
        })
        .unwrap();
        assert_eq!(
            path,
            PathBuf::from("/home/fixture-owner/.config/dbeer-gpui/connections.json")
        );
    }
}

fn fixture_root() -> PathBuf {
    PathBuf::from(env!("CARGO_MANIFEST_DIR"))
        .join("../../build/gpui/task31-owned-identity")
        .join(format!(
            "{}-{}",
            std::process::id(),
            SystemTime::now()
                .duration_since(UNIX_EPOCH)
                .unwrap()
                .as_nanos()
        ))
}

#[test]
fn ownership_alias_child() {
    let Some(root) = std::env::var_os("DBEER_TASK31_OWNED_ROOT") else {
        return;
    };
    let owner = crate::instance::DataDirectory::acquire(Path::new(&root));
    if std::env::var_os("DBEER_TASK31_EXPECT_REFUSAL").is_some() {
        assert!(owner.is_err());
        return;
    }
    let _owner = owner.unwrap();
    println!("DBEER_TASK31_OWNER_READY");
    std::io::stdout().flush().unwrap();
    let mut input = String::new();
    std::io::stdin().read_line(&mut input).unwrap();
    assert_eq!(input.trim(), "release");
}

#[test]
fn old_and_new_identity_processes_share_one_owner_and_preserve_bytes() {
    let root = fixture_root();
    fs::create_dir_all(&root).unwrap();
    let original = b"opaque fixture bytes preserved before any migration/load";
    fs::write(root.join("connections.json"), original).unwrap();
    let spawn = || {
        let mut command = Command::new(std::env::current_exe().unwrap());
        command
            .args([
                "--exact",
                "product_identity::tests::ownership_alias_child",
                "--nocapture",
            ])
            .env("DBEER_TASK31_OWNED_ROOT", &root)
            .stdin(Stdio::piped())
            .stdout(Stdio::piped())
            .stderr(Stdio::null());
        command
    };
    let mut legacy = spawn().spawn().unwrap();
    let output = legacy.stdout.take().unwrap();
    let (sender, receiver) = std::sync::mpsc::channel();
    let output_reader = std::thread::spawn(move || {
        for line in BufReader::new(output).lines() {
            if line.is_ok_and(|value| value == "DBEER_TASK31_OWNER_READY") {
                _ = sender.send(true);
            }
        }
    });
    if receiver.recv_timeout(std::time::Duration::from_secs(10)) != Ok(true) {
        _ = legacy.kill();
        _ = legacy.wait();
        _ = output_reader.join();
        panic!("The owned identity fixture child did not become ready.");
    }
    let refused = spawn()
        .env("DBEER_TASK31_EXPECT_REFUSAL", "1")
        // This child has no readiness payload. Do not leave its test-harness
        // output connected to an unread pipe while waiting for its exit.
        .stdout(Stdio::null())
        .status();
    let local_refused = crate::instance::DataDirectory::acquire(&root).is_err();
    let preserved = fs::read(root.join("connections.json"));
    let release = writeln!(legacy.stdin.take().unwrap(), "release");
    if release.is_err() {
        _ = legacy.kill();
    }
    let exited = legacy.wait();
    output_reader.join().unwrap();
    release.unwrap();
    assert!(refused.unwrap().success());
    assert!(local_refused);
    assert_eq!(preserved.unwrap(), original);
    assert!(exited.unwrap().success());
    let product = crate::instance::DataDirectory::acquire(&root).unwrap();
    assert_eq!(fs::read(root.join("connections.json")).unwrap(), original);
    drop(product);
    fs::remove_dir_all(root).unwrap();
}
