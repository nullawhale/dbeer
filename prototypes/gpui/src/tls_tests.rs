//! Prepared real-helper TLS matrix. Run at final integration against private,
//! owned PostgreSQL/MySQL fixtures; never infer native TLS from compilation.
use crate::{
    backend::{Connection, ExecutionPolicy},
    live_tests,
};
use serde::Deserialize;
use std::{collections::HashSet, path::PathBuf};

#[derive(Deserialize)]
#[serde(rename_all = "camelCase", deny_unknown_fields)]
struct Case {
    engine: String,
    scenario: String,
    host: String,
    port: u16,
    database: String,
    user: String,
    password_file: PathBuf,
    ssl_root_cert: Option<String>,
}
const SCENARIOS: &[(&str, &str, bool)] = &[
    ("disable", "disable", true),
    ("require", "require", true),
    ("trusted-ca", "verify-ca", true),
    ("trusted-host", "verify-full", true),
    ("ca-only-hostname-mismatch", "verify-ca", true),
    ("hostname-mismatch", "verify-full", false),
    ("untrusted-ca", "verify-ca", false),
    ("untrusted-host", "verify-full", false),
    ("missing-ca", "verify-full", false),
    ("unreadable-ca", "verify-full", false),
];

#[test]
fn real_helper_postgresql_and_mysql_tls_matrix_never_downgrades_or_executes_sql() {
    let Some(path) = std::env::var_os("DBEER_GPUI_TLS_MANIFEST") else {
        assert!(
            std::env::var("DBEER_REQUIRE_GPUI_TLS").as_deref() != Ok("1"),
            "Required owned TLS fixtures are unavailable."
        );
        return;
    };
    // Manifest and password files are generated privately under ignored build/.
    // Only the manifest path enters environment; no credentials enter diagnostics.
    let bytes = std::fs::read(path).expect("Read the owned TLS case manifest.");
    assert!(
        bytes.len() <= crate::startup::MAX_INPUT_BYTES,
        "TLS manifest is oversized."
    );
    let cases: Vec<Case> = serde_json::from_slice(&bytes)
        .unwrap_or_else(|_| panic!("Invalid owned TLS case manifest."));
    let mut seen = HashSet::new();
    smol::block_on(async {
        let client = live_tests::client().await;
        for case in cases {
            assert!(
                matches!(case.engine.as_str(), "postgresql" | "mysql"),
                "Unsupported TLS fixture engine."
            );
            let (mode, succeeds) = if case.engine == "postgresql"
                && matches!(case.scenario.as_str(), "allow" | "prefer")
            {
                (case.scenario.as_str(), true)
            } else {
                SCENARIOS
                    .iter()
                    .find(|(scenario, _, _)| *scenario == case.scenario)
                    .map(|(_, mode, succeeds)| (*mode, *succeeds))
                    .expect("Unknown TLS scenario.")
            };
            assert!(
                seen.insert((case.engine.clone(), case.scenario.clone())),
                "Duplicate TLS case."
            );
            let mut password = std::fs::read_to_string(case.password_file)
                .unwrap_or_else(|_| panic!("Read the owned TLS password file."));
            if password.ends_with('\n') {
                password.pop();
                if password.ends_with('\r') {
                    password.pop();
                }
            }
            let settings = Connection {
                engine: case.engine.clone(),
                host: case.host,
                port: case.port,
                database: case.database,
                user: case.user,
                password,
                ssl_mode: mode.into(),
                ssl_root_cert: case.ssl_root_cert,
                policy: ExecutionPolicy {
                    environment: "unspecified".into(),
                    read_only: false,
                },
            };
            // One connect, no retries/SQL/credential persistence. The Go adapter
            // decides trust and hostname verification for the exact requested mode.
            match live_tests::bounded(client.connect(settings)).await {
                Ok(outcome) => {
                    assert!(succeeds, "An invalid TLS connection was accepted.");
                    assert!(
                        live_tests::bounded(client.disconnect(&outcome.session_id))
                            .await
                            .is_ok(),
                        "TLS fixture disconnect failed."
                    );
                }
                Err(error) => {
                    assert!(!succeeds, "A valid TLS connection failed.");
                    assert!(
                        !error.connected && !error.outcome_unknown,
                        "TLS failure retained a session or unknown outcome."
                    );
                }
            }
        }
        drop(client); // The final client owner requests acknowledged shutdown.
    });
    for engine in ["postgresql", "mysql"] {
        for (scenario, _, _) in SCENARIOS {
            assert!(
                seen.contains(&(engine.to_string(), scenario.to_string())),
                "A required TLS scenario is missing."
            );
        }
    }
    for scenario in ["allow", "prefer"] {
        assert!(
            seen.contains(&("postgresql".into(), scenario.into())),
            "A PostgreSQL TLS mode is missing."
        );
    }
}
