//! Prepared cases only; run after all remaining plan implementation is integrated.
use super::*;
use gpui_kit::KeyDownEvent;
use std::{fs, path::PathBuf};
const PLATFORM: NativePlatform = NativePlatform::Linux;
const CLEAR: InputSafety = InputSafety {
    marked_text: Evidence::Clear,
    dead_key: Evidence::Clear,
};
fn ctrl(key: &str) -> Shortcut {
    Shortcut::new(
        key,
        Modifiers {
            control: true,
            ..Modifiers::default()
        },
    )
}
fn event(shortcut: &Shortcut) -> KeyDownEvent {
    KeyDownEvent {
        keystroke: shortcut.keystroke(),
        is_held: false,
        prefer_character_input: false,
    }
}
fn fixture_preferences() -> Preferences {
    serde_json::from_str(include_str!("../../fixtures/shortcuts/preferences-v1.json")).unwrap()
}

#[test]
fn common_registry_is_the_only_default_and_fixed_binding_source() {
    for platform in [
        NativePlatform::Windows,
        NativePlatform::Linux,
        NativePlatform::MacDevelopment,
    ] {
        let preferences = Preferences::default();
        let resolved = preferences.validated_bindings(platform).unwrap();
        assert_eq!(resolved.len(), DEFAULT_SHORTCUTS.len());
        for &(key, command, scope) in DEFAULT_SHORTCUTS {
            let binding = resolved.iter().find(|b| b.command == command).unwrap();
            assert_eq!(
                binding.shortcut,
                Shortcut::from_suffix(key, platform).unwrap()
            );
            assert_eq!(binding.scope, scope);
            let _native = binding.key_binding();
        }
        for command in [
            ConfigurableCommand::Stop,
            ConfigurableCommand::RunToJson,
            ConfigurableCommand::RunToCsv,
        ] {
            assert_eq!(
                preferences.shortcut(command, platform),
                DEFAULT_SHORTCUTS
                    .iter()
                    .find(|b| b.1 == command.command())
                    .map(|b| Shortcut::from_suffix(b.0, platform).unwrap())
            );
        }
    }
    assert_eq!(
        Preferences::default()
            .menu_label(ConfigurableCommand::RunCurrent, PLATFORM)
            .as_deref(),
        Some("Ctrl+Enter")
    );
    assert_eq!(
        Preferences::default()
            .menu_label(ConfigurableCommand::RunScript, PLATFORM)
            .as_deref(),
        Some("Ctrl+Shift+Enter")
    );
}
#[test]
fn clear_default_reset_and_conflicting_reset_are_atomic() {
    let mut preferences = Preferences::default();
    let original = preferences.clone();
    preferences
        .clear(ConfigurableCommand::RunCurrent, PLATFORM)
        .unwrap();
    assert!(
        preferences
            .shortcut(ConfigurableCommand::RunCurrent, PLATFORM)
            .is_none()
    );
    preferences
        .set(
            ConfigurableCommand::Stop,
            BindingChoice::Bound(ctrl("enter")),
            PLATFORM,
        )
        .unwrap();
    let changed = preferences.clone();
    assert_eq!(
        preferences.restore_default(ConfigurableCommand::RunCurrent, PLATFORM),
        Err(ValidationError::Conflict)
    );
    assert_eq!(preferences, changed);
    preferences.reset_defaults();
    assert_eq!(preferences, original);
    assert!(
        preferences
            .shortcut(ConfigurableCommand::RunCurrent, PLATFORM)
            .is_some()
    );
}
#[test]
fn complete_assignment_supports_valid_swaps_and_refuses_duplicate_or_conflicting_entries() {
    let mut preferences = Preferences::default();
    let run = preferences
        .shortcut(ConfigurableCommand::RunCurrent, PLATFORM)
        .unwrap();
    let script = preferences
        .shortcut(ConfigurableCommand::RunScript, PLATFORM)
        .unwrap();
    preferences
        .replace_overrides(
            vec![
                Override {
                    command: ConfigurableCommand::RunCurrent,
                    binding: BindingChoice::Bound(script),
                },
                Override {
                    command: ConfigurableCommand::RunScript,
                    binding: BindingChoice::Bound(run),
                },
            ],
            PLATFORM,
        )
        .unwrap();
    let good = preferences.clone();
    assert!(
        preferences
            .replace_overrides(
                vec![good.overrides[0].clone(), good.overrides[0].clone()],
                PLATFORM
            )
            .is_err()
    );
    assert_eq!(preferences, good);
    for &(suffix, command, _) in DEFAULT_SHORTCUTS {
        if ConfigurableCommand::ALL
            .iter()
            .any(|c| c.command() == command)
        {
            continue;
        }
        assert!(
            preferences
                .set(
                    ConfigurableCommand::Stop,
                    BindingChoice::Bound(Shortcut::from_suffix(suffix, PLATFORM).unwrap()),
                    PLATFORM
                )
                .is_err()
        );
        assert_eq!(preferences, good);
    }
}
#[test]
fn explicit_recorder_clear_and_reset_finish_capture_only_after_atomic_success() {
    let mut preferences = Preferences::default();
    let mut recording = Recording::begin(ConfigurableCommand::RunCurrent);
    recording.clear(&mut preferences, PLATFORM).unwrap();
    assert!(!recording.active());
    assert!(
        preferences
            .shortcut(ConfigurableCommand::RunCurrent, PLATFORM)
            .is_none()
    );
    preferences
        .set(
            ConfigurableCommand::Stop,
            BindingChoice::Bound(ctrl("enter")),
            PLATFORM,
        )
        .unwrap();
    let previous = preferences.clone();
    let mut recording = Recording::begin(ConfigurableCommand::RunCurrent);
    assert_eq!(
        recording.restore_default(&mut preferences, PLATFORM),
        Err(ValidationError::Conflict)
    );
    assert!(recording.active());
    assert_eq!(preferences, previous);
    recording.reset_defaults(&mut preferences);
    assert!(!recording.active());
    assert_eq!(preferences, Preferences::default());
}
#[test]
fn protected_text_navigation_system_and_ambiguous_character_keys_are_refused() {
    let original = Preferences::default();
    for key in [
        "a",
        "c",
        "x",
        "v",
        "z",
        "y",
        "h",
        "d",
        "k",
        "u",
        "l",
        ".",
        "/",
        "[",
        "]",
        "left",
        "right",
        "up",
        "down",
        "tab",
        "escape",
        "delete",
        "backspace",
        "home",
        "end",
        "pageup",
        "pagedown",
        "insert",
        "space",
        "f4",
        "f6",
        "f10",
    ] {
        let mut preferences = original.clone();
        assert!(
            preferences
                .set(
                    ConfigurableCommand::Stop,
                    BindingChoice::Bound(ctrl(key)),
                    PLATFORM
                )
                .is_err(),
            "{key}"
        );
        assert_eq!(preferences, original);
    }
    for modifiers in [
        Modifiers::default(),
        Modifiers {
            shift: true,
            ..Modifiers::default()
        },
        Modifiers {
            alt: true,
            ..Modifiers::default()
        },
        Modifiers {
            control: true,
            alt: true,
            ..Modifiers::default()
        },
        Modifiers {
            platform: true,
            ..Modifiers::default()
        },
    ] {
        assert!(Shortcut::new("j", modifiers).validate(PLATFORM).is_err());
    }
    assert!(ctrl("j").validate(PLATFORM).is_ok());
    assert!(ctrl("f8").validate(PLATFORM).is_ok());
}
#[test]
fn cancel_repeat_modifiers_conflict_and_failed_capture_preserve_the_previous_binding() {
    let mut preferences = fixture_preferences();
    let original = preferences.clone();
    let mut recording = Recording::begin(ConfigurableCommand::Stop);
    let mut repeated = event(&ctrl("f9"));
    repeated.is_held = true;
    assert_eq!(
        recording.capture(&mut preferences, &repeated, CLEAR, PLATFORM),
        CaptureOutcome::IgnoredRepeat
    );
    let modifier = event(&ctrl("shift"));
    assert_eq!(
        recording.capture(&mut preferences, &modifier, CLEAR, PLATFORM),
        CaptureOutcome::ModifierOnly
    );
    assert!(matches!(
        recording.capture(&mut preferences, &event(&ctrl("n")), CLEAR, PLATFORM),
        CaptureOutcome::Rejected(_)
    ));
    assert_eq!(preferences, original);
    assert!(recording.active());
    assert_eq!(
        recording.capture(&mut preferences, &event(&ctrl("escape")), CLEAR, PLATFORM),
        CaptureOutcome::Cancelled
    );
    assert!(!recording.active());
    assert_eq!(preferences, original);
    let mut recording = Recording::begin(ConfigurableCommand::Stop);
    let mut tab = event(&ctrl("tab"));
    tab.keystroke.modifiers.shift = true;
    assert_eq!(
        recording.capture(&mut preferences, &tab, CLEAR, PLATFORM),
        CaptureOutcome::Traverse { reverse: true }
    );
    assert_eq!(preferences, original);
    let mut recording = Recording::begin(ConfigurableCommand::Stop);
    assert_eq!(
        recording.capture(&mut preferences, &event(&ctrl("f9")), CLEAR, PLATFORM),
        CaptureOutcome::Bound
    );
    assert_eq!(
        preferences
            .menu_label(ConfigurableCommand::Stop, PLATFORM)
            .as_deref(),
        Some("Ctrl+F9")
    );
    assert!(!recording.active());
}
#[test]
fn altgr_marked_text_dead_keys_and_unknown_evidence_pass_through_without_mutation() {
    let mut preferences = fixture_preferences();
    let original = preferences.clone();
    let mut recording = Recording::begin(ConfigurableCommand::Stop);
    for safety in [
        InputSafety {
            marked_text: Evidence::Active,
            ..CLEAR
        },
        InputSafety {
            marked_text: Evidence::Unknown,
            ..CLEAR
        },
        InputSafety {
            dead_key: Evidence::Active,
            ..CLEAR
        },
        InputSafety {
            dead_key: Evidence::Unknown,
            ..CLEAR
        },
    ] {
        assert_eq!(
            recording.capture(&mut preferences, &event(&ctrl("f9")), safety, PLATFORM),
            CaptureOutcome::PassThrough
        );
        assert!(
            preferences
                .command_for_native(&event(&ctrl("enter")), safety, PLATFORM)
                .is_none()
        );
    }
    let mut altgr = event(&ctrl("j"));
    altgr.keystroke.modifiers.alt = true;
    altgr.prefer_character_input = true;
    assert_eq!(
        recording.capture(&mut preferences, &altgr, CLEAR, PLATFORM),
        CaptureOutcome::PassThrough
    );
    assert!(
        preferences
            .command_for_native(&altgr, CLEAR, PLATFORM)
            .is_none()
    );
    altgr.prefer_character_input = false;
    assert_eq!(
        recording.capture(&mut preferences, &altgr, CLEAR, PLATFORM),
        CaptureOutcome::Rejected(ValidationError::CharacterInput)
    );
    assert!(
        preferences
            .command_for_native(&altgr, CLEAR, PLATFORM)
            .is_none()
    );
    assert_eq!(preferences, original);
    assert_eq!(
        InputSafety::from_gpui(&event(&ctrl("dead_acute")), Evidence::Clear).dead_key,
        Evidence::Active
    );
    assert_eq!(
        InputSafety::from_native(&event(&ctrl("j")), Evidence::Clear, NativePlatform::Linux)
            .dead_key,
        Evidence::Unknown
    );
    assert_eq!(
        InputSafety::from_native(
            &event(&ctrl("enter")),
            Evidence::Clear,
            NativePlatform::MacDevelopment
        )
        .dead_key,
        Evidence::Clear
    );
    assert_eq!(
        InputSafety::from_native(&event(&ctrl("j")), Evidence::Clear, NativePlatform::Windows)
            .dead_key,
        Evidence::Clear
    );
}
#[test]
fn native_layout_identity_and_menu_labels_never_substitute_text_or_physical_codes() {
    let preferences = fixture_preferences();
    assert!(ctrl("Α").validate(PLATFORM).is_ok());
    let greek = preferences
        .shortcut(ConfigurableCommand::RunToJson, PLATFORM)
        .unwrap();
    assert_eq!(greek.label(PLATFORM), "Ctrl+Shift+Α");
    let mut native = event(&greek);
    native.keystroke.key_char = Some("漢".into());
    assert_eq!(
        preferences.command_for_native(&native, CLEAR, PLATFORM),
        Some(CommandId::RunToJson)
    );
    native.keystroke.key = "a".into();
    native.keystroke.key_char = Some("α".into());
    assert!(
        preferences
            .command_for_native(&native, CLEAR, PLATFORM)
            .is_none()
    );
    let roundtrip: Preferences =
        serde_json::from_slice(&serde_json::to_vec(&preferences).unwrap()).unwrap();
    assert_eq!(roundtrip, preferences);
    for unsupported in ["physical", "scanCode", "macKeyCode"] {
        let json = serde_json::to_string(&preferences)
            .unwrap()
            .replace("nativeKey", unsupported);
        assert!(serde_json::from_str::<Preferences>(&json).is_err());
    }
}

struct Fixture {
    root: PathBuf,
    store: ShortcutStore,
}
impl Fixture {
    fn new() -> Self {
        let root = PathBuf::from(env!("CARGO_MANIFEST_DIR"))
            .join("../../build/gpui/task28-tests")
            .join(uuid::Uuid::new_v4().to_string());
        let owner = crate::instance::DataDirectory::acquire(&root).unwrap();
        Self {
            root,
            store: ShortcutStore::new(owner),
        }
    }
    fn path(&self) -> PathBuf {
        self.root.join("shortcuts.json")
    }
}
impl Drop for Fixture {
    fn drop(&mut self) {
        _ = fs::remove_dir_all(&self.root);
    }
}
#[test]
fn absent_clear_reset_restart_and_last_close_flush_preserve_explicit_unbound() {
    let fixture = Fixture::new();
    assert_eq!(
        fixture.store.load(PLATFORM).unwrap(),
        Preferences::default()
    );
    let expected = fixture_preferences();
    fixture
        .store
        .flush_latest(expected.clone(), PLATFORM)
        .unwrap();
    assert!(fixture.store.latest_saved());
    let restarted = ShortcutStore::new(fixture.store.owner());
    assert_eq!(restarted.load(PLATFORM).unwrap(), expected);
    assert!(
        expected
            .shortcut(ConfigurableCommand::RunCurrent, PLATFORM)
            .is_none()
    );
    let mut reset = expected;
    reset.reset_defaults();
    restarted.flush_latest(reset.clone(), PLATFORM).unwrap();
    assert_eq!(fixture.store.load(PLATFORM).unwrap(), reset);
}
#[test]
fn strict_corrupt_future_unknown_duplicate_oversize_and_bad_mappings_are_preserved() {
    for bytes in [
        b"{broken".to_vec(),
        br#"{"version":2,"overrides":[]}"#.to_vec(),
        br#"{"version":1,"overrides":[],"sessions":[]}"#.to_vec(),
        br#"{"version":1,"version":1,"overrides":[]}"#.to_vec(),
        br#"{"version":1,"overrides":[{"command":"query.future","binding":{"state":"unbound"}}]}"#.to_vec(),
        br#"{"version":1,"overrides":[{"command":"query.stop","binding":{"state":"unbound"}},{"command":"query.stop","binding":{"state":"unbound"}}]}"#.to_vec(),
        br#"{"version":1,"overrides":[{"command":"query.stop","binding":{"state":"unbound","shortcut":null}}]}"#.to_vec(),
        serde_json::to_vec(&Preferences { version: VERSION, overrides: vec![Override { command: ConfigurableCommand::Stop, binding: BindingChoice::Bound(ctrl("n")) }] }).unwrap(),
        vec![b' '; 16_385],
    ] {
        let fixture = Fixture::new(); fs::write(fixture.path(), &bytes).unwrap();
        let loaded = fixture.store.load_or_default(PLATFORM);
        assert_eq!(loaded.preferences, Preferences::default()); assert!(loaded.error.is_some());
        assert!(fixture.store.reserve(loaded.preferences, PLATFORM).is_err());
        assert!(!fixture.store.latest_saved());
        assert_eq!(fs::read(fixture.path()).unwrap(), bytes);
    }
}
#[test]
fn explicit_recovery_keeps_exact_original_and_invalidates_pre_recovery_requests() {
    let fixture = Fixture::new();
    fixture.store.load(PLATFORM).unwrap();
    let queued = fixture
        .store
        .reserve(fixture_preferences(), PLATFORM)
        .unwrap();
    let original = b"{ invalid original\r\n";
    fs::write(fixture.path(), original).unwrap();
    assert!(fixture.store.load(PLATFORM).is_err());
    fixture.store.recover_defaults(PLATFORM).unwrap();
    assert_eq!(queued.commit(), Ok(SaveOutcome::Superseded));
    let backups: Vec<_> = fs::read_dir(&fixture.root)
        .unwrap()
        .filter_map(Result::ok)
        .filter(|entry| {
            entry
                .file_name()
                .to_string_lossy()
                .starts_with("shortcuts-recovery-")
        })
        .collect();
    assert_eq!(backups.len(), 1);
    assert_eq!(fs::read(backups[0].path()).unwrap(), original);
    assert_eq!(
        fixture.store.load(PLATFORM).unwrap(),
        Preferences::default()
    );
}
#[test]
fn actual_default_recovery_protects_arbitrary_bytes_and_retries_colliding_backup_names() {
    use crate::files::test_support::{Stage, with_preparation_hook};
    use std::sync::{
        Arc,
        atomic::{AtomicUsize, Ordering},
    };
    let fixture = Fixture::new();
    fixture.store.load(PLATFORM).unwrap();
    let queued = fixture
        .store
        .reserve(fixture_preferences(), PLATFORM)
        .unwrap();
    let original = b"\xff\x00{ invalid recovery\r\n\x80";
    #[cfg(windows)]
    let private = {
        use crate::files::test_support::windows;
        use std::io::Write;
        windows::set_broad_inheritance(&fixture.root);
        let mut source = windows::create_private(&fixture.path()).unwrap();
        source.write_all(original).unwrap();
        source.sync_all().unwrap();
        let descriptor = windows::descriptor(&source);
        assert!(descriptor.starts_with("D:P(A;;FA;;;"));
        assert_eq!(descriptor.matches("(A;").count(), 1);
        descriptor
    };
    #[cfg(not(windows))]
    fs::write(fixture.path(), original).unwrap();
    assert!(fixture.store.load(PLATFORM).is_err());
    let collision_id = uuid::Uuid::new_v4();
    let backup_id = uuid::Uuid::new_v4();
    let collision = fixture
        .root
        .join(format!("shortcuts-recovery-{collision_id}.json"));
    let backup = fixture
        .root
        .join(format!("shortcuts-recovery-{backup_id}.json"));
    fs::write(&collision, b"preexisting shortcut backup").unwrap();
    let collision_binding = crate::files::open(&collision).unwrap().binding;
    let target = fs::canonicalize(backup.parent().unwrap())
        .unwrap()
        .join(backup.file_name().unwrap());
    let seen = Arc::new(AtomicUsize::new(0));
    let observed = seen.clone();
    #[cfg(windows)]
    let expected_private = private.clone();
    let mut ids = [collision_id, backup_id].into_iter();
    let outcome = with_preparation_hook(
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
                Stage::BeforeWrite => assert_eq!(retained.metadata()?.len(), 0),
                Stage::BeforeSync => assert_eq!(fs::read(temporary)?, original),
            }
            observed.fetch_add(1, Ordering::SeqCst);
            Ok(())
        },
        || {
            fixture
                .store
                .recover_defaults_using(PLATFORM, || ids.next().unwrap(), |_| {})
        },
    );
    assert_eq!(outcome, Ok(SaveOutcome::Published));
    assert_eq!(seen.load(Ordering::SeqCst), 2);
    assert_eq!(fs::read(&backup).unwrap(), original);
    assert!(crate::files::open(&collision).unwrap().binding == collision_binding);
    assert_eq!(queued.commit(), Ok(SaveOutcome::Superseded));
    assert!(fixture.store.latest_saved());
    let restarted = ShortcutStore::new(fixture.store.owner());
    assert_eq!(restarted.load(PLATFORM).unwrap(), Preferences::default());
    #[cfg(windows)]
    for path in [backup, fixture.path()] {
        assert_eq!(
            crate::files::test_support::windows::descriptor(&fs::File::open(path).unwrap()),
            private
        );
    }
}
#[test]
fn actual_default_recovery_backup_fault_preserves_corrupt_bytes_and_foreign_identity() {
    use crate::files::test_support::{Stage, with_preparation_hook};
    use std::sync::{Arc, Mutex};
    for stage in [Stage::BeforeWrite, Stage::BeforeSync] {
        for replace in [false, true] {
            let fixture = Fixture::new();
            let original = b"\xff\x00{ invalid recovery\r\n\x80";
            fs::write(fixture.path(), original).unwrap();
            assert!(fixture.store.load(PLATFORM).is_err());
            let published = fixture.store.published_revision();
            let id = uuid::Uuid::new_v4();
            let backup = fixture.root.join(format!("shortcuts-recovery-{id}.json"));
            let target = fs::canonicalize(backup.parent().unwrap())
                .unwrap()
                .join(backup.file_name().unwrap());
            let moved = fixture.root.join("retained-backup-stage");
            let retained_path = moved.clone();
            let evidence = Arc::new(Mutex::new(None));
            let observed = evidence.clone();
            let result = with_preparation_hook(
                move |current, path, temporary, _| {
                    if path == target && current == stage {
                        if replace {
                            fs::rename(temporary, &retained_path)?;
                            fs::write(temporary, b"foreign shortcut backup staging")?;
                            *observed.lock().unwrap() = Some((
                                temporary.to_path_buf(),
                                crate::files::open(temporary).unwrap().binding,
                            ));
                        }
                        return Err(std::io::Error::other("synthetic backup stage fault"));
                    }
                    Ok(())
                },
                || {
                    fixture
                        .store
                        .recover_defaults_using(PLATFORM, || id, |_| {})
                },
            );
            assert_eq!(result, Err(StoreError::Write));
            assert_eq!(fs::read(fixture.path()).unwrap(), original);
            assert!(!backup.exists());
            assert!(!fixture.store.latest_saved());
            assert_eq!(fixture.store.published_revision(), published);
            assert!(
                fixture
                    .store
                    .reserve(Preferences::default(), PLATFORM)
                    .is_err()
            );
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
                    !fs::read_dir(&fixture.root)
                        .unwrap()
                        .flatten()
                        .any(|entry| { entry.file_name().to_string_lossy().ends_with(".tmp") })
                );
            }
            fixture.store.recover_defaults(PLATFORM).unwrap();
            assert!(fixture.store.latest_saved());
            assert_eq!(
                fixture.store.load(PLATFORM).unwrap(),
                Preferences::default()
            );
            if let Some((path, binding)) = evidence.lock().unwrap().as_ref() {
                assert!(&crate::files::open(path).unwrap().binding == binding);
            }
        }
    }
}
#[test]
fn actual_default_recovery_refuses_late_foreign_backup_and_keeps_read_only_original() {
    use crate::files::test_support::{Stage, with_preparation_hook};
    use std::sync::{Arc, Mutex};
    let fixture = Fixture::new();
    let original = b"\xff\x00{ invalid recovery\r\n\x80";
    fs::write(fixture.path(), original).unwrap();
    assert!(fixture.store.load(PLATFORM).is_err());
    let published = fixture.store.published_revision();
    let id = uuid::Uuid::new_v4();
    let backup = fixture.root.join(format!("shortcuts-recovery-{id}.json"));
    let target = fs::canonicalize(backup.parent().unwrap())
        .unwrap()
        .join(backup.file_name().unwrap());
    let evidence = Arc::new(Mutex::new(None));
    let observed = evidence.clone();
    let result = with_preparation_hook(
        move |stage, path, _, _| {
            if path == target && stage == Stage::BeforeWrite {
                fs::write(path, b"late foreign shortcut backup")?;
                *observed.lock().unwrap() = Some(crate::files::open(path).unwrap().binding);
            }
            Ok(())
        },
        || {
            fixture
                .store
                .recover_defaults_using(PLATFORM, || id, |_| {})
        },
    );
    assert_eq!(result, Err(StoreError::Write));
    assert_eq!(fs::read(fixture.path()).unwrap(), original);
    assert!(Some(crate::files::open(&backup).unwrap().binding) == *evidence.lock().unwrap());
    assert!(!fixture.store.latest_saved());
    assert_eq!(fixture.store.published_revision(), published);
    assert!(
        fixture
            .store
            .reserve(Preferences::default(), PLATFORM)
            .is_err()
    );
    fixture.store.recover_defaults(PLATFORM).unwrap();
    assert!(Some(crate::files::open(&backup).unwrap().binding) == *evidence.lock().unwrap());
    assert_eq!(
        fixture.store.load(PLATFORM).unwrap(),
        Preferences::default()
    );
}
#[test]
fn reservations_are_ordered_concurrent_and_reload_invalidates_old_work() {
    let fixture = Fixture::new();
    fixture.store.load(PLATFORM).unwrap();
    let old = fixture
        .store
        .reserve(Preferences::default(), PLATFORM)
        .unwrap();
    let latest = fixture_preferences();
    let new = fixture.store.reserve(latest.clone(), PLATFORM).unwrap();
    assert!(new.revision() > old.revision());
    assert!(!fixture.store.latest_saved());
    std::thread::scope(|scope| {
        let first = scope.spawn(|| old.commit());
        let second = scope.spawn(|| new.commit());
        assert_eq!(first.join().unwrap(), Ok(SaveOutcome::Superseded));
        assert_eq!(second.join().unwrap(), Ok(SaveOutcome::Published));
    });
    assert!(fixture.store.latest_saved());
    assert_eq!(fixture.store.load(PLATFORM).unwrap(), latest);
    let stale = fixture
        .store
        .reserve(Preferences::default(), PLATFORM)
        .unwrap();
    fixture.store.load(PLATFORM).unwrap();
    assert_eq!(stale.commit(), Ok(SaveOutcome::Superseded));
}
#[test]
fn external_edit_and_atomic_failure_preserve_destination_and_unrelated_state() {
    let fixture = Fixture::new();
    fixture.store.load(PLATFORM).unwrap();
    let unrelated = b"unrelated private state";
    fs::write(fixture.root.join("workspace.json"), unrelated).unwrap();
    fixture
        .store
        .flush_latest(Preferences::default(), PLATFORM)
        .unwrap();
    let before = fs::read(fixture.path()).unwrap();
    fixture.store.fail_replacement(true);
    assert_eq!(
        fixture.store.flush_latest(fixture_preferences(), PLATFORM),
        Err(StoreError::Write)
    );
    assert_eq!(fs::read(fixture.path()).unwrap(), before);
    assert!(!fixture.store.latest_saved());
    fixture.store.fail_replacement(false);
    let request = fixture
        .store
        .reserve(fixture_preferences(), PLATFORM)
        .unwrap();
    fs::write(fixture.path(), b"external").unwrap();
    assert_eq!(request.commit(), Err(StoreError::Conflict));
    assert_eq!(fs::read(fixture.path()).unwrap(), b"external");
    assert_eq!(
        fs::read(fixture.root.join("workspace.json")).unwrap(),
        unrelated
    );
    assert_eq!(
        fs::read_dir(&fixture.root)
            .unwrap()
            .filter_map(Result::ok)
            .filter(|e| e.file_name().to_string_lossy().ends_with(".tmp"))
            .count(),
        0
    );
}
#[test]
fn actual_commit_refuses_foreign_or_modified_staging_without_advancing_publication() {
    for replace in [true, false] {
        let fixture = Fixture::new();
        fixture.store.load(PLATFORM).unwrap();
        fixture
            .store
            .flush_latest(Preferences::default(), PLATFORM)
            .unwrap();
        let before = fs::read(fixture.path()).unwrap();
        let published = fixture.store.published_revision();
        let stale = fixture
            .store
            .reserve(Preferences::default(), PLATFORM)
            .unwrap();
        let request = fixture
            .store
            .reserve(fixture_preferences(), PLATFORM)
            .unwrap();
        let mut temporary = PathBuf::new();
        let moved = fixture.root.join("retained-original.tmp");
        let foreign = b"foreign shortcut staging";
        assert_eq!(
            request.commit_with(|prepared| {
                temporary = prepared.temporary_path().to_path_buf();
                if replace {
                    fs::rename(&temporary, &moved).unwrap();
                }
                fs::write(&temporary, foreign).unwrap();
            }),
            Err(StoreError::Write)
        );
        assert_eq!(fs::read(fixture.path()).unwrap(), before);
        assert_eq!(fixture.store.published_revision(), published);
        assert!(!fixture.store.latest_saved());
        assert_eq!(stale.commit(), Ok(SaveOutcome::Superseded));
        if replace {
            assert_eq!(fs::read(&temporary).unwrap(), foreign);
            assert_eq!(
                fs::read(&moved).unwrap(),
                serde_json::to_vec_pretty(&fixture_preferences()).unwrap()
            );
        } else {
            assert!(!temporary.exists());
        }
        // Retry uses the actual latest reservation, and does not consume a
        // foreign file left at a former temporary pathname.
        fixture
            .store
            .flush_latest(fixture_preferences(), PLATFORM)
            .unwrap();
        assert!(fixture.store.latest_saved());
        assert_eq!(
            ShortcutStore::new(fixture.store.owner())
                .load(PLATFORM)
                .unwrap(),
            fixture_preferences()
        );
        if replace {
            assert_eq!(fs::read(temporary).unwrap(), foreign);
        }
    }
}
#[test]
fn actual_recovery_refuses_foreign_or_modified_staging_and_preserves_exact_backup() {
    for replace in [true, false] {
        let fixture = Fixture::new();
        fixture.store.load(PLATFORM).unwrap();
        let published = fixture.store.published_revision();
        let stale = fixture
            .store
            .reserve(fixture_preferences(), PLATFORM)
            .unwrap();
        let original = b"{ invalid shortcut recovery original\r\n";
        fs::write(fixture.path(), original).unwrap();
        assert!(fixture.store.load(PLATFORM).is_err());
        let mut temporary = PathBuf::new();
        let moved = fixture.root.join("retained-recovery.tmp");
        let foreign = b"foreign recovery staging";
        assert_eq!(
            fixture.store.recover_defaults_with(PLATFORM, |prepared| {
                temporary = prepared.temporary_path().to_path_buf();
                if replace {
                    fs::rename(&temporary, &moved).unwrap();
                }
                fs::write(&temporary, foreign).unwrap();
            }),
            Err(StoreError::Write)
        );
        assert_eq!(fs::read(fixture.path()).unwrap(), original);
        assert_eq!(fixture.store.published_revision(), published);
        assert!(!fixture.store.latest_saved());
        assert!(
            fixture
                .store
                .reserve(Preferences::default(), PLATFORM)
                .is_err()
        );
        assert_eq!(stale.commit(), Ok(SaveOutcome::Superseded));
        let backups = fs::read_dir(&fixture.root)
            .unwrap()
            .flatten()
            .filter(|entry| {
                entry
                    .file_name()
                    .to_string_lossy()
                    .starts_with("shortcuts-recovery-")
            })
            .collect::<Vec<_>>();
        assert_eq!(backups.len(), 1);
        assert_eq!(fs::read(backups[0].path()).unwrap(), original);
        if replace {
            assert_eq!(fs::read(&temporary).unwrap(), foreign);
            assert_eq!(
                fs::read(moved).unwrap(),
                serde_json::to_vec_pretty(&Preferences::default()).unwrap()
            );
        } else {
            assert!(!temporary.exists());
        }
        fixture.store.recover_defaults(PLATFORM).unwrap();
        assert!(fixture.store.latest_saved());
        assert_eq!(
            ShortcutStore::new(fixture.store.owner())
                .load(PLATFORM)
                .unwrap(),
            Preferences::default()
        );
        if replace {
            assert_eq!(fs::read(temporary).unwrap(), foreign);
        }
    }
}
#[cfg(unix)]
#[test]
fn private_modes_and_symlink_refusal_preserve_original_files() {
    use std::os::unix::fs::{PermissionsExt, symlink};
    let fixture = Fixture::new();
    fixture.store.load(PLATFORM).unwrap();
    fixture
        .store
        .flush_latest(fixture_preferences(), PLATFORM)
        .unwrap();
    assert_eq!(
        fs::metadata(fixture.path()).unwrap().permissions().mode() & 0o777,
        0o600
    );
    let target = fixture.root.join("preserved.json");
    fs::rename(fixture.path(), &target).unwrap();
    let bytes = fs::read(&target).unwrap();
    symlink(&target, fixture.path()).unwrap();
    assert!(fixture.store.load(PLATFORM).is_err());
    assert!(fixture.store.recover_defaults(PLATFORM).is_err());
    assert_eq!(fs::read(target).unwrap(), bytes);
}
#[cfg(windows)]
#[test]
fn locked_windows_destination_is_never_deleted_to_force_replacement() {
    use std::os::windows::fs::OpenOptionsExt;
    let fixture = Fixture::new();
    fixture.store.load(PLATFORM).unwrap();
    fixture
        .store
        .flush_latest(Preferences::default(), PLATFORM)
        .unwrap();
    let before = fs::read(fixture.path()).unwrap();
    let locked = fs::OpenOptions::new()
        .read(true)
        .share_mode(1)
        .open(fixture.path())
        .unwrap();
    assert_eq!(
        fixture.store.flush_latest(fixture_preferences(), PLATFORM),
        Err(StoreError::Write)
    );
    assert_eq!(fs::read(fixture.path()).unwrap(), before);
    drop(locked);
    fixture
        .store
        .flush_latest(fixture_preferences(), PLATFORM)
        .unwrap();
}
