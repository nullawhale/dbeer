//! Shared fixtures exercise the production metadata codec; execution is deferred.
use super::{BuildIdentity, BuildInfo, NativeTarget};
use serde::Deserialize;
use std::{fs, path::PathBuf};

#[derive(Deserialize)]
#[serde(rename_all = "camelCase")]
struct Cases {
    schema_version: u32,
    identity_cases: Vec<Case>,
    info_cases: Vec<Case>,
    hello_cases: Vec<Case>,
    native_cases: Vec<Native>,
}
#[derive(Deserialize)]
struct Case {
    name: String,
    file: String,
    valid: bool,
    canonical: Option<String>,
}
#[derive(Deserialize)]
struct Native {
    os: String,
    architecture: String,
    abi: String,
    target: Option<NativeTarget>,
}
fn root() -> PathBuf {
    PathBuf::from(env!("CARGO_MANIFEST_DIR")).join("../../protocol/fixtures/gpui-build-identity-v1")
}
fn read(file: &str) -> Vec<u8> {
    fs::read(root().join(file)).expect("shared product metadata fixture is readable")
}
fn cases() -> Cases {
    let cases: Cases = serde_json::from_slice(&read("cases.json")).unwrap();
    assert_eq!(cases.schema_version, 1);
    cases
}
fn canonical(value: &impl serde::Serialize) -> Vec<u8> {
    fn emit(value: &serde_json::Value, bytes: &mut Vec<u8>) {
        match value {
            serde_json::Value::Object(fields) => {
                let mut keys: Vec<_> = fields.keys().collect();
                keys.sort_unstable();
                bytes.push(b'{');
                for (index, key) in keys.iter().enumerate() {
                    if index != 0 {
                        bytes.push(b',');
                    }
                    bytes.extend(serde_json::to_vec(key).unwrap());
                    bytes.push(b':');
                    emit(&fields[*key], bytes);
                }
                bytes.push(b'}');
            }
            serde_json::Value::Array(values) => {
                bytes.push(b'[');
                for (index, value) in values.iter().enumerate() {
                    if index != 0 {
                        bytes.push(b',');
                    }
                    emit(value, bytes);
                }
                bytes.push(b']');
            }
            _ => bytes.extend(serde_json::to_vec(value).unwrap()),
        }
    }
    // The schema's accepted keys and values are ASCII. Explicitly sort every
    // object regardless of serde_json preserve_order feature unification.
    let mut bytes = Vec::new();
    emit(&serde_json::to_value(value).unwrap(), &mut bytes);
    bytes.push(b'\n');
    bytes
}
#[test]
fn shared_identity_bytes_and_strict_acceptance() {
    for case in cases().identity_cases {
        let parsed = BuildIdentity::parse(&read(&case.file));
        assert_eq!(parsed.is_ok(), case.valid, "{}", case.name);
        if let Ok(identity) = parsed {
            assert_eq!(canonical(&identity), read(case.canonical.as_ref().unwrap()));
        }
    }
}
#[test]
fn shared_info_envelopes_validate_nested_identity() {
    for case in cases().info_cases {
        let bytes = read(&case.file);
        let parsed = serde_json::from_slice::<BuildInfo>(&bytes)
            .ok()
            .filter(|info| bytes.len() <= 4160 && info.identity.validate().is_ok());
        assert_eq!(parsed.is_some(), case.valid, "{}", case.name);
        if let Some(info) = parsed {
            assert_eq!(canonical(&info), read(case.canonical.as_ref().unwrap()));
        }
    }
}
#[test]
fn shared_optional_hello_contract_values() {
    for case in cases().hello_cases {
        let bytes = read(&case.file);
        let parsed = BuildIdentity::optional_from_frame(&bytes, 16 * 1024 * 1024);
        let frame: serde_json::Value = serde_json::from_slice(&bytes).unwrap();
        if frame["type"] != "hello.ack" {
            // This corpus rejects wrong types as hello messages. General
            // transport preflight leaves non-hello shapes to its wire validator.
            assert!(!case.valid);
            assert!(parsed.unwrap().is_none());
            continue;
        }
        assert_eq!(parsed.is_ok(), case.valid, "{}", case.name);
        if let Ok(identity) = parsed {
            if let Some(file) = case.canonical {
                assert_eq!(canonical(&identity.unwrap()), read(&file));
            } else {
                assert!(identity.is_none());
            }
        }
    }
}
#[test]
fn shared_native_labels_keep_only_the_supported_products() {
    for case in cases().native_cases {
        assert_eq!(
            NativeTarget::from_native(&case.os, &case.architecture, &case.abi),
            case.target
        );
    }
}
