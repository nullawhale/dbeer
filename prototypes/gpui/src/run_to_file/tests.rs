use super::*;
#[test]
fn exactly_one_statement_preserves_exact_fragment_and_rejects_client_or_incomplete_sql() {
    for source in [
        "SELECT 1;SELECT 2",
        "SELECT 'unterminated",
        "\\copy x to y",
        "DELIMITER $$\nSELECT 1$$",
    ] {
        let fragment = sql::resolve(
            sql::SourceText::new(source.to_owned()),
            0..source.len(),
            sql::Dialect::PostgreSQL,
            false,
        );
        assert!(fragment.is_none() || validate(&fragment.unwrap()).is_err());
    }
    let source = "-- heading\r\nSELECT '😀', 'NULL', 9007199254740993.123456789;";
    let fragment = sql::resolve(
        sql::SourceText::new(source.to_owned()),
        0..source.len(),
        sql::Dialect::PostgreSQL,
        false,
    )
    .unwrap();
    validate(&fragment).unwrap();
    assert_eq!(fragment.statements().len(), 1);
    assert!(
        fragment.statements()[0]
            .sql()
            .contains("9007199254740993.123456789")
    );
}
#[test]
fn target_fingerprint_streams_binary_and_captures_explicit_absence_and_edits() {
    let directory = std::env::temp_dir().join(format!("dbeer-run-file-{}", uuid::Uuid::new_v4()));
    fs::create_dir(&directory).unwrap();
    let directory = fs::canonicalize(directory).unwrap();
    let path = directory.join("result.json");
    let absent = capture_destination(&path).unwrap();
    assert!(!absent.exists);
    fs::write(&path, [0, 255, 0, 13, 10]).unwrap();
    let captured = capture_destination(&path).unwrap();
    assert!(captured.exists);
    assert_eq!(captured.size, 5);
    assert_eq!(captured.sha256.len(), 64);
    fs::write(&path, [0, 254, 0, 13, 10]).unwrap();
    assert_ne!(captured.sha256, capture_destination(&path).unwrap().sha256);
    fs::remove_dir_all(directory).unwrap();
}
#[cfg(unix)]
#[test]
fn symlink_target_and_parent_are_refused() {
    let root = std::env::temp_dir().join(format!("dbeer-run-link-{}", uuid::Uuid::new_v4()));
    fs::create_dir(&root).unwrap();
    let root = fs::canonicalize(root).unwrap();
    fs::write(root.join("original"), b"keep").unwrap();
    std::os::unix::fs::symlink(root.join("original"), root.join("link")).unwrap();
    assert!(capture_destination(&root.join("link")).is_err());
    std::os::unix::fs::symlink(&root, root.join("parent")).unwrap();
    assert!(capture_destination(&root.join("parent/out")).is_err());
    fs::remove_dir_all(root).unwrap();
}

fn fake(mode: &str) -> crate::fault_test_support::Fixture {
    crate::fault_test_support::Fixture::new("run-to-file", mode)
}
fn request(root: &Path) -> backend::ExportRequest {
    backend::ExportRequest {
        path: root.join("output.json").to_str().unwrap().to_owned(),
        format: backend::ExportFormat::Json,
        null_marker: None,
        destination: Some(backend::ExportDestination {
            exists: false,
            identity: None,
            parent_identity: None,
            size: 0,
            sha256: String::new(),
            modified_nanoseconds: None,
        }),
    }
}
#[test]
fn fake_helper_progress_past_display_budget_exact_authorization_one_submission_late_stop_and_loss()
{
    for mode in [
        "success",
        "hold",
        "helper-loss",
        "publication-failure",
        "mutated-target",
    ] {
        let fixture = fake(mode);
        let root = &fixture.directory;
        let client = &fixture.client;
        smol::block_on(async {
            let export = request(root);
            let source = "INSERT fixture RETURNING exact_values".to_owned();
            let assessment = crate::live_tests::bounded(client.assess_operations(
                "original-sql",
                vec![backend::OperationRequest::Execute {
                    sql: source.clone(),
                    export: Some(export.clone()),
                }],
            ))
            .await
            .unwrap();
            let mut submitted = export;
            if mode == "mutated-target" {
                submitted.null_marker = Some("different".into())
            }
            let stream = client
                .run_to_file("original-sql", source, submitted, assessment.authorization)
                .unwrap();
            let mut progress = false;
            let mut cancelled = false;
            loop {
                let event = crate::live_tests::bounded(stream.events.recv())
                    .await
                    .unwrap();
                match event {
                    Ok(backend::QueryEvent::Started) => {}
                    Ok(backend::QueryEvent::ExportProgress {
                        result_index,
                        row_count,
                    }) => {
                        assert!(result_index > 1024 && row_count == 9001);
                        progress = true;
                        if mode == "hold" {
                            assert_eq!(
                                crate::live_tests::bounded(
                                    client.cancel("original-sql", &stream.query_id)
                                )
                                .await
                                .unwrap()
                                .status,
                                "accepted"
                            );
                            cancelled = true
                        }
                    }
                    Ok(backend::QueryEvent::Chunk { .. }) => {
                        panic!("Full progress must not become retained rows.")
                    }
                    Ok(backend::QueryEvent::Finished(outcome)) => {
                        assert!(matches!(mode, "success" | "hold"));
                        assert!(progress);
                        assert_eq!(outcome.export.unwrap().row_count, 9001);
                        assert_eq!(
                            outcome.transaction_status,
                            backend::TransactionStatus::Transaction
                        );
                        if mode == "hold" {
                            assert!(cancelled)
                        }
                        break;
                    }
                    Err(error) => {
                        if mode == "helper-loss" {
                            assert!(error.outcome_unknown);
                            assert!(!error.sql_completed)
                        } else if mode == "publication-failure" {
                            assert!(error.sql_completed);
                            assert!(!error.outcome_unknown);
                            assert!(
                                error.export_publication
                                    == Some(backend::ExportPublication::NotPublished)
                            );
                            assert!(
                                error.transaction_status
                                    == Some(backend::TransactionStatus::Transaction)
                            )
                        } else {
                            assert!(mode == "mutated-target" && error.category == "policy")
                        }
                        break;
                    }
                }
            }
        });
        let log = fixture.log();
        assert_eq!(log.lines().filter(|s| *s == "execute").count(), 1);
        assert_eq!(log.lines().filter(|s| *s == "operation.assess").count(), 1);
        assert!(!log.lines().any(|s| s == "catalog" || s == "connect"));
        // Fixture Drop observes this exact owned child exit before file cleanup.
        drop(fixture);
    }
}

#[test]
fn older_helper_without_capability_refuses_captured_export_before_sql() {
    let fixture = fake("legacy-helper");
    let root = &fixture.directory;
    let client = &fixture.client;
    assert!(
        client
            .run_to_file("original-sql", "SELECT 1".into(), request(root), None)
            .is_err()
    );
    let log = fixture.log();
    assert!(!log.lines().any(|c| c == "execute"));
    drop(fixture);
}

#[cfg(windows)]
#[test]
fn ordinary_and_verbatim_drive_and_unc_paths_compare_without_retargeting() {
    for (left, right) in [
        (r"C:\exports", r"\\?\C:\EXPORTS"),
        (r"\\server\share\exports", r"\\?\UNC\SERVER\SHARE\exports"),
        (r"\\server\share", r"\\?\unc\server\SHARE"),
    ] {
        assert!(same_path(Path::new(left), Path::new(right)));
    }
    assert!(!same_path(
        Path::new(r"\\server\share"),
        Path::new(r"\\?\UNC\server\other")
    ));
    assert!(!same_path(
        Path::new(r"C:\exports"),
        Path::new(r"\\?\D:\exports")
    ));
}
