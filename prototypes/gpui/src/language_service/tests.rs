//! Prepared final-integration checks. Compilation is not execution evidence.
use super::*;
use super::{
    metadata::{CatalogOwner, CatalogPager, Relation},
    positions::{Position, offset_at},
    transport::sanitized_environment,
};
use crate::backend::{Column, ResultSet};
use std::{
    ffi::OsString,
    fs,
    path::{Path, PathBuf},
    process::Command,
    sync::OnceLock,
};

fn capture(source: &str) -> DocumentCapture {
    DocumentCapture {
        document_id: "document".into(),
        uri: "dbeer-sql:///fixture.sql".into(),
        version: 1,
        context: ContextKey::default(),
        process_generation: 1,
        editor_revision: None,
        dialect: Dialect::PostgreSQL,
        source: Arc::from(source),
    }
}

#[test]
fn framing_partial_concatenated_and_exact_utf8_length() {
    let frame = framing::encode(&json!({"jsonrpc":"2.0","result":"a\n\u{1f37a}"})).unwrap();
    let mut framer = framing::Framer::default();
    let mut result = Vec::new();
    for byte in &frame {
        result.extend(framer.append(&[*byte]).unwrap());
    }
    assert_eq!(result.len(), 1);
    assert_eq!(
        serde_json::from_slice::<Value>(&result[0]).unwrap()["result"],
        "a\n\u{1f37a}"
    );
    framer.finish().unwrap();
    let mut both = frame.clone();
    both.extend(frame);
    assert_eq!(framer.append(&both).unwrap().len(), 2);
}

#[test]
fn framing_rejects_duplicate_missing_negative_oversized_and_truncated() {
    for invalid in [
        "Content-Length: 1\r\nContent-Length: 1\r\n\r\n{",
        "Content-Type: application/json\r\n\r\n{}",
        "Content-Length: -1\r\n\r\n",
        "Content-Length: 4194305\r\n\r\n",
        "Content-Length: +1\r\n\r\n",
        "Content-Length: 0\r\n\r\n",
        "Content-Length 1\r\n\r\n",
    ] {
        assert!(
            framing::Framer::default()
                .append(invalid.as_bytes())
                .is_err()
        );
    }
    let mut framer = framing::Framer::default();
    framer.append(b"Content-Length: 2\r\n\r\n{").unwrap();
    assert_eq!(framer.finish(), Err(Error::InvalidFrame));
    assert!(
        framing::Framer::default()
            .append(&vec![b'x'; 8193])
            .is_err()
    );
    assert_eq!(
        framing::Framer::default().append(&vec![b'x'; framing::READ_CHUNK + 1]),
        Err(Error::Limit)
    );
}

#[test]
fn json_rejects_duplicate_identity_keys_malformed_and_excessive_depth() {
    assert_eq!(
        framing::decode(br#"{"jsonrpc":"2.0","id":1,"id":2,"result":null}"#),
        Err(Error::InvalidMessage)
    );
    assert_eq!(
        framing::decode(br#"{"jsonrpc":"2.0","params":{"version":1,"version":2}}"#),
        Err(Error::InvalidMessage)
    );
    assert_eq!(framing::decode(b"{"), Err(Error::InvalidMessage));
    let nested = format!("{}0{}", "[".repeat(256), "]".repeat(256));
    assert_eq!(
        framing::decode(nested.as_bytes()),
        Err(Error::InvalidMessage)
    );
    assert_eq!(
        framing::decode(br#"{"result":null}"#).unwrap()["result"],
        Value::Null
    );
}

#[test]
fn utf16_crlf_surrogates_and_byte_boundaries_roundtrip() {
    let source = "a\u{1f37a}\r\nb\rc\nd";
    for offset in (0..=source.len()).filter(|offset| source.is_char_boundary(*offset)) {
        if source.as_bytes().get(offset.wrapping_sub(1)) == Some(&b'\r')
            && source.as_bytes().get(offset) == Some(&b'\n')
        {
            assert_eq!(position_at(source, offset), Err(Error::InvalidPosition));
        } else {
            let position = position_at(source, offset).unwrap();
            assert_eq!(offset_at(source, position), Ok(offset));
        }
    }
    assert_eq!(
        offset_at(
            source,
            Position {
                line: 0,
                character: 2
            }
        ),
        Err(Error::InvalidPosition)
    );
    assert_eq!(position_at(source, 2), Err(Error::InvalidPosition));
    assert_eq!(
        offset_at(
            source,
            Position {
                line: 4,
                character: 0
            }
        ),
        Err(Error::InvalidPosition)
    );
    assert_eq!(label_range("a\u{1f37a}b", [1, 3]), Ok(1..5));
    assert_eq!(
        label_range("a\u{1f37a}b", [1, 2]),
        Err(Error::InvalidPosition)
    );
}

#[test]
fn environment_allowlist_is_case_insensitive_windows_compatible_and_excludes_secrets() {
    let environment = [
        ("SystemRoot", "C:\\Windows"),
        ("WinDir", "C:\\Windows"),
        ("Temp", "C:\\Temp"),
        ("TMP", "C:\\Temp"),
        ("PGPASSWORD", "private"),
        ("MYSQL_PWD", "private"),
        ("DBEER_GPUI_HELPER_PATH", "private"),
        ("PATH", "private"),
        ("DYLD_INSERT_LIBRARIES", "private"),
        ("LD_PRELOAD", "private"),
        ("HOME", "private"),
        ("GODEBUG", "private"),
        ("HTTPS_PROXY", "private"),
    ]
    .map(|(key, value)| (OsString::from(key), OsString::from(value)));
    let windows = sanitized_environment(environment.clone(), true);
    assert_eq!(windows.len(), 6);
    for name in ["SYSTEMROOT", "WINDIR", "TEMP", "TMP", "LANG", "LC_ALL"] {
        assert!(windows.iter().any(|(key, _)| key == name));
    }
    let unix = sanitized_environment(environment, false);
    assert_eq!(unix.len(), 2);
    assert!(unix.iter().all(|(key, _)| key == "LANG" || key == "LC_ALL"));
}

#[test]
fn completion_rejects_unsafe_edits_and_preserves_match_coordinates() {
    let source = capture("select \u{1f37a}co");
    let response = json!({"items":[
        {"label":"\u{1f37a}column","textEdit":{"newText":"safe","range":{"start":{"line":0,"character":9},"end":{"line":0,"character":11}}},"data":{"dbeerMatchRanges":[[0,2],[2,4]]}},
        {"label":"snippet","insertTextFormat":2},
        {"label":"extra","additionalTextEdits":[]},
        {"label":"surrogate","textEdit":{"newText":"bad","range":{"start":{"line":0,"character":8},"end":{"line":0,"character":9}}}}
    ]});
    let result = parse_completion(response, source, 13).unwrap();
    assert_eq!(result.items.len(), 1);
    assert_eq!(result.items[0].replacement_range, 11..13);
    assert_eq!(result.items[0].match_ranges, vec![0..4, 4..6]);
    assert_eq!(result.items[0].replacement, "safe");
}

#[test]
fn signature_and_diagnostics_validate_exact_captured_source() {
    let help = parse_signature(json!({"signatures":[{"label":"f(\u{1f37a})","parameters":[{"label":[2,4]}],"activeParameter":0}],"activeSignature":0}), capture("f(")).unwrap().unwrap();
    assert_eq!(help.signatures[0].parameter_ranges, vec![2..6]);
    assert_eq!(help.signatures[0].active_parameter, Some(0));
    assert!(
        parse_signature(
            json!({"signatures":[{"label":"f(\u{1f37a})","parameters":[{"label":[2,3]}]}]}),
            capture("f(")
        )
        .is_err()
    );
    assert!(parse_signature(Value::Null, capture("")).unwrap().is_none());
    let diagnostics = parse_diagnostics(json!({"diagnostics":[
        {"message":"valid","range":{"start":{"line":0,"character":0},"end":{"line":0,"character":2}}},
        {"message":"invalid","range":{"start":{"line":0,"character":0},"end":{"line":0,"character":1}}}
    ]}), capture("\u{1f37a}")).unwrap();
    assert_eq!(diagnostics.diagnostics.len(), 1);
    assert_eq!(diagnostics.diagnostics[0].range, 0..4);
}

fn owner() -> CatalogOwner {
    CatalogOwner {
        profile_id: "opaque".into(),
        settings_revision: 1,
        service_generation: 7,
        catalog_revision: 9,
    }
}
fn metadata_page(count: usize) -> ResultSet {
    ResultSet {
        columns: [
            "name",
            "kind",
            "schema",
            "columns",
            "foreignKeys",
            "signatures",
        ]
        .iter()
        .enumerate()
        .map(|(index, name)| Column {
            index,
            name: (*name).into(),
            engine: "postgresql".into(),
            native_type: "text".into(),
            type_oid: 0,
            encoding: None,
        })
        .collect(),
        rows: (0..count)
            .map(|index| {
                vec![
                    Some(format!("relation_{index}")),
                    Some("table".into()),
                    Some("public".into()),
                    Some("[\"column\"]".into()),
                    Some("[]".into()),
                    Some("[]".into()),
                ]
            })
            .collect(),
        row_count: count as u64,
        displayed_row_count: count,
        ..Default::default()
    }
}

#[test]
fn paginated_metadata_requires_original_owner_and_atomic_complete_pages() {
    let owner = owner();
    let mut pager = CatalogPager::new(owner.clone());
    assert_eq!(pager.next_request().unwrap().page, 0);
    assert!(!pager.accept_page(&owner, 0, &[metadata_page(200)]).unwrap());
    assert_eq!(pager.next_request().unwrap().page, 1);
    let mut stale = owner.clone();
    stale.service_generation += 1;
    assert_eq!(
        pager.accept_page(&stale, 1, &[metadata_page(0)]),
        Err(Error::Stale)
    );
    let mut truncated = metadata_page(1);
    truncated.truncated = true;
    assert_eq!(
        pager.accept_page(&owner, 1, &[truncated]),
        Err(Error::Limit)
    );
    assert!(pager.accept_page(&owner, 1, &[metadata_page(1)]).unwrap());
    let snapshot = pager.finish(&owner).unwrap();
    assert_eq!(snapshot.relations().len(), 201);
    assert_eq!(snapshot.relations()[0].columns, vec!["column"]);
}

#[test]
fn catalog_payload_is_bounded_without_losing_all_large_relation_names() {
    let snapshot = CatalogSnapshot::bounded((0..2100).map(|index| Relation {
        schema: "public".into(),
        name: format!("relation_{index}"),
        kind: "table".into(),
        columns: vec!["x".repeat(1024); 2000],
        foreign_keys: Vec::new(),
        signatures: Vec::new(),
    }));
    assert!(snapshot.truncated);
    assert!(snapshot.relations().len() <= 2048);
    assert!(serde_json::to_vec(snapshot.relations()).unwrap().len() <= 3 * 1024 * 1024);
}

// Final integration builds this std-only fixture locally once. No shell/PATH
// fake process ever substitutes for the production exact --language-server arg.
fn fixture_binary() -> &'static Path {
    static BINARY: OnceLock<PathBuf> = OnceLock::new();
    BINARY.get_or_init(|| {
        let root = Path::new(env!("CARGO_MANIFEST_DIR"))
            .join("../../build/gpui/task23-core-fixtures")
            .join(uuid::Uuid::new_v4().to_string());
        fs::create_dir_all(&root).unwrap();
        let binary = root.join(if cfg!(windows) { "base.exe" } else { "base" });
        let rustc = std::env::var_os("RUSTC")
            .map(PathBuf::from)
            .unwrap_or_else(|| {
                std::env::var_os("CARGO")
                    .or_else(|| option_env!("CARGO").map(OsString::from))
                    .map(PathBuf::from)
                    .filter(|cargo| cargo.is_absolute())
                    .map(|cargo| {
                        cargo.with_file_name(if cfg!(windows) { "rustc.exe" } else { "rustc" })
                    })
                    .unwrap_or_else(|| PathBuf::from("rustc"))
            });
        let status = Command::new(rustc)
            .arg("--edition=2024")
            .arg(
                Path::new(env!("CARGO_MANIFEST_DIR"))
                    .join("fixtures/language-service/fake_helper.rs"),
            )
            .arg("-o")
            .arg(&binary)
            .stdout(std::process::Stdio::null())
            .stderr(std::process::Stdio::null())
            .status()
            .unwrap();
        assert!(status.success(), "Compile the owned fixture.");
        binary
    })
}
pub(crate) fn fake(mode: &str) -> PathBuf {
    let base = fixture_binary();
    let path = base.parent().unwrap().join(format!(
        "{mode}-{}{}",
        uuid::Uuid::new_v4(),
        if cfg!(windows) { ".exe" } else { "" }
    ));
    fs::copy(base, &path).unwrap();
    path
}

#[test]
fn owned_fake_helper_has_no_session_or_credential_api_and_rejects_stale_versions() {
    smol::block_on(async {
        let path = fake("normal");
        let service = LanguageService::spawn(&path).unwrap();
        let old = service
            .update(
                "doc",
                "select",
                Dialect::PostgreSQL,
                ContextKey::default(),
                CatalogSnapshot::default(),
            )
            .unwrap();
        service.initialize().await.unwrap();
        assert!(service.capture_current(&old));
        let completion = service.completion(&old, 6).await.unwrap();
        assert_eq!(completion.items[0].label, "safe");
        let changed = service
            .update(
                "doc",
                "select x",
                Dialect::PostgreSQL,
                ContextKey::default(),
                CatalogSnapshot::default(),
            )
            .unwrap();
        assert!(!service.capture_current(&old));
        assert!(service.capture_current(&changed));
        let mut context = ContextKey {
            settings_revision: 1,
            ..ContextKey::default()
        };
        let settings = service
            .update(
                "doc",
                "select x",
                Dialect::PostgreSQL,
                context.clone(),
                CatalogSnapshot::default(),
            )
            .unwrap();
        assert!(!service.capture_current(&changed));
        context.catalog_revision = 1;
        let catalog = service
            .update(
                "doc",
                "select x",
                Dialect::PostgreSQL,
                context.clone(),
                CatalogSnapshot::default(),
            )
            .unwrap();
        assert!(!service.capture_current(&settings));
        context.profile_id = Some("another".into());
        let profile = service
            .update(
                "doc",
                "select x",
                Dialect::MySQL,
                context,
                CatalogSnapshot::default(),
            )
            .unwrap();
        assert_ne!(catalog.uri, profile.uri);
        service.close("doc");
        assert!(!service.capture_current(&profile));
        service.shutdown().await;
        assert!(!service.available());
        let replacement = LanguageService::spawn(&path).unwrap();
        assert_ne!(
            replacement.process_generation(),
            service.process_generation()
        );
        assert!(!replacement.capture_current(&old));
        replacement.shutdown().await;
    });
}

#[test]
fn timeout_and_future_drop_cancel_only_the_owned_request_and_shutdown_reaps() {
    smol::block_on(async {
        let path = fake("stall");
        let mut service = LanguageService::spawn(&path).unwrap();
        service.initialize().await.unwrap();
        // This check owns a request deadline, not cold executable startup.
        Arc::get_mut(&mut service.inner).unwrap().timeout = Duration::from_millis(75);
        let capture = service
            .update(
                "doc",
                "select",
                Dialect::PostgreSQL,
                ContextKey::default(),
                CatalogSnapshot::default(),
            )
            .unwrap();
        assert!(matches!(
            service.completion(&capture, 6).await,
            Err(Error::Timeout)
        ));
        let request = service
            .request_at("textDocument/completion", &capture, 6)
            .unwrap();
        request.cancel();
        assert!(matches!(request.finish().await, Err(Error::Cancelled)));
        let request = service
            .request_at("textDocument/completion", &capture, 6)
            .unwrap();
        drop(request);
        let started = std::time::Instant::now();
        service.shutdown().await;
        assert!(started.elapsed() < Duration::from_secs(3));
    });
}

#[test]
fn malformed_peer_remote_error_and_process_loss_are_sanitized() {
    smol::block_on(async {
        for mode in ["malformed", "remote", "die"] {
            let service = LanguageService::spawn(fake(mode)).unwrap();
            service.initialize().await.unwrap();
            let capture = service
                .update(
                    "doc",
                    "select",
                    Dialect::PostgreSQL,
                    ContextKey::default(),
                    CatalogSnapshot::default(),
                )
                .unwrap();
            let error = match service.completion(&capture, 6).await {
                Err(error) => error,
                Ok(_) => panic!("Expected fixed failure."),
            };
            assert!(!error.to_string().contains("PRIVATE_PEER_MESSAGE"));
            assert!(!error.to_string().contains("select"));
            if mode == "remote" {
                assert_eq!(error, Error::Remote);
                assert!(service.available());
            }
            service.shutdown().await;
        }
    });
}

#[test]
fn document_bounds_close_previous_snapshot_instead_of_reusing_old_text() {
    smol::block_on(async {
        let service = LanguageService::spawn(fake("normal")).unwrap();
        service.initialize().await.unwrap();
        let capture = service
            .update(
                "doc",
                "small",
                Dialect::PostgreSQL,
                ContextKey::default(),
                CatalogSnapshot::default(),
            )
            .unwrap();
        assert!(matches!(
            service.update(
                "doc",
                "x".repeat(LanguageService::MAX_DOCUMENT_BYTES + 1),
                Dialect::PostgreSQL,
                ContextKey::default(),
                CatalogSnapshot::default()
            ),
            Err(Error::Limit)
        ));
        assert!(!service.capture_current(&capture));
        service.shutdown().await;
        // Exercise document retention independently of writer queue scheduling.
        let service = LanguageService::spawn(fake("normal")).unwrap();
        for index in 0..32 {
            service
                .update(
                    &format!("doc{index}"),
                    "",
                    Dialect::PostgreSQL,
                    ContextKey::default(),
                    CatalogSnapshot::default(),
                )
                .unwrap();
        }
        assert!(matches!(
            service.update(
                "overflow",
                "",
                Dialect::PostgreSQL,
                ContextKey::default(),
                CatalogSnapshot::default()
            ),
            Err(Error::Limit)
        ));
        service.shutdown().await;
    });
}

#[test]
fn pending_requests_apply_backpressure_and_drop_releases_capacity() {
    smol::block_on(async {
        let service = LanguageService::spawn(fake("stall")).unwrap();
        service.initialize().await.unwrap();
        let capture = service
            .update(
                "doc",
                "select",
                Dialect::PostgreSQL,
                ContextKey::default(),
                CatalogSnapshot::default(),
            )
            .unwrap();
        let mut requests = Vec::new();
        for _ in 0..32 {
            requests.push(
                service
                    .request_at("textDocument/completion", &capture, 6)
                    .unwrap(),
            );
        }
        assert!(matches!(
            service.request_at("textDocument/completion", &capture, 6),
            Err(Error::Backpressure)
        ));
        drop(requests.pop());
        let replacement = service
            .request_at("textDocument/completion", &capture, 6)
            .unwrap();
        drop(replacement);
        drop(requests);
        service.shutdown().await;
    });
}

#[test]
fn delayed_completion_cannot_publish_after_source_or_profile_context_change() {
    smol::block_on(async {
        for mode in ["slow", "slow-remote"] {
            let service = LanguageService::spawn(fake(mode)).unwrap();
            service.initialize().await.unwrap();
            let capture = service
                .update(
                    "doc",
                    "select",
                    Dialect::PostgreSQL,
                    ContextKey::default(),
                    CatalogSnapshot::default(),
                )
                .unwrap();
            let (result, ()) = smol::future::zip(service.completion(&capture, 6), async {
                smol::Timer::after(Duration::from_millis(10)).await;
                let context = ContextKey {
                    profile_id: Some("changed".into()),
                    settings_revision: 1,
                    catalog_revision: 1,
                };
                service
                    .update(
                        "doc",
                        "select new",
                        Dialect::MySQL,
                        context,
                        CatalogSnapshot::default(),
                    )
                    .unwrap();
            })
            .await;
            assert!(matches!(result, Err(Error::Stale)));
            service.shutdown().await;
        }
    });
}

#[test]
fn owned_shutdown_preserves_an_unrelated_language_server_process() {
    smol::block_on(async {
        let foreign_path = fake("normal");
        let mut foreign = Command::new(&foreign_path)
            .arg("--language-server")
            .env_clear()
            .envs(sanitized_environment(std::env::vars_os(), cfg!(windows)))
            .stdin(std::process::Stdio::piped())
            .stdout(std::process::Stdio::null())
            .stderr(std::process::Stdio::null())
            .spawn()
            .unwrap();
        let service = LanguageService::spawn(fake("normal")).unwrap();
        service.initialize().await.unwrap();
        service.shutdown().await;
        assert!(foreign.try_wait().unwrap().is_none());
        foreign.kill().unwrap();
        foreign.wait().unwrap();
    });
}
