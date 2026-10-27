use super::*;
fn fixture() -> (backend::ResultSet, Vec<backend::TableColumnMetadata>) {
    let columns = [
        "id", "part", "label", "bytes", "amount", "moment", "computed",
    ]
    .into_iter()
    .enumerate()
    .map(|(index, name)| backend::Column {
        index,
        name: name.into(),
        engine: "postgresql".into(),
        native_type: if index == 3 {
            "bytea"
        } else if index == 4 {
            "numeric"
        } else if index == 5 {
            "timestamp"
        } else {
            "text"
        }
        .into(),
        type_oid: if index == 3 { 17 } else { 25 },
        encoding: (index == 3).then(|| "base64".into()),
    })
    .collect::<Vec<_>>();
    let metadata = columns
        .iter()
        .enumerate()
        .map(|(i, c)| backend::TableColumnMetadata {
            name: c.name.clone(),
            native_type: c.native_type.clone(),
            nullable: i > 1,
            default: (i == 2).then(|| "'base'".into()),
            generated: if i == 6 {
                "stored".into()
            } else {
                String::new()
            },
            primary_key: if i < 2 { i as u32 + 1 } else { 0 },
            editable: i != 6,
            edit_reason: if i == 6 {
                "Computed column".into()
            } else {
                String::new()
            },
        })
        .collect();
    let set = backend::ResultSet {
        columns,
        rows: vec![vec![
            Some("1".into()),
            Some("A".into()),
            Some("base".into()),
            Some("AAEC/w==".into()),
            Some("9007199254740993.12345678901234567890".into()),
            Some("2026-10-19 10:11:12.123456".into()),
            Some("2".into()),
        ]],
        ..Default::default()
    };
    (set, metadata)
}
#[test]
fn original_cas_is_immutable_and_reverting_updates_clears_pending() {
    let (set, meta) = fixture();
    let frozen = set.clone();
    let mut d = Draft::new(&set, meta, 17, &[41]).unwrap();
    assert!(d.set(41, 2, backend::CellValue::Text("NULL".into())));
    let request = d.request("s".into(), "t".into());
    assert!(request.valid());
    assert_eq!(request.changes[0].original.len(), 7);
    assert!(request.changes[0].original[0] == backend::CellValue::Text("1".into()));
    assert!(request.changes[0].original[1] == backend::CellValue::Text("A".into()));
    assert!(
        request.changes[0].original[4]
            == backend::CellValue::Text("9007199254740993.12345678901234567890".into())
    );
    assert!(d.set(41, 2, backend::CellValue::Text("base".into())));
    assert_eq!(d.pending(), 0);
    assert_eq!(set, frozen);
}
#[test]
fn explicit_default_null_empty_text_binary_and_exact_temporal_never_coerce() {
    let (set, meta) = fixture();
    let mut d = Draft::new(&set, meta, 7, &[1]).unwrap();
    for value in [
        backend::CellValue::Null,
        backend::CellValue::Default,
        backend::CellValue::Text("".into()),
        backend::CellValue::Text("NULL".into()),
        backend::CellValue::Text("DEFAULT".into()),
    ] {
        assert!(d.set(1, 2, value.clone()));
        assert!(d.rows[0].values[2] == value);
    }
    for value in ["", "AAEC/w==", "AAE=\r\n"] {
        assert!(d.set(1, 3, backend::CellValue::Binary(value.into())));
    }
    let before = d.rows[0].values[3].clone();
    assert!(!d.set(1, 3, backend::CellValue::Binary("not base64".into())));
    assert!(d.rows[0].values[3] == before);
    assert!(!d.set(1, 0, backend::CellValue::Null));
    assert!(!d.set(1, 6, backend::CellValue::Default));
    assert!(d.set(
        1,
        4,
        backend::CellValue::Text("1.0000000000000000000000000000001".into())
    ));
    assert!(d.set(
        1,
        5,
        backend::CellValue::Text("2026-10-19 10:11:12.123456+00".into())
    ));
    let json = serde_json::to_string(&d.request("s".into(), "t".into())).unwrap();
    assert!(json.contains("1.0000000000000000000000000000001"));
    assert!(json.contains("123456+00"));
}
#[test]
fn insertion_defaults_generated_values_stable_ids_and_delete_update_semantics_match_swift() {
    let (set, meta) = fixture();
    let mut d = Draft::new(&set, meta, 3, &[100]).unwrap();
    assert!(d.set(100, 2, backend::CellValue::Text("changed".into())));
    let inserted = d.insert().unwrap();
    assert_ne!(inserted, 100);
    assert!(
        d.rows[1]
            .values
            .iter()
            .all(|v| *v == backend::CellValue::Default)
    );
    assert_eq!(d.pending(), 2);
    assert!(
        d.request("s".into(), "t".into()).changes[1]
            .values
            .is_empty()
    );
    d.delete(&[100]);
    let request = d.request("s".into(), "t".into());
    assert!(request.changes[0].kind == backend::ChangeKind::Delete);
    assert!(request.changes[0].values.is_empty());
    assert!(!d.set(100, 2, backend::CellValue::Null));
    d.delete(&[inserted]);
    assert_eq!(d.rows.len(), 1);
    let later = d.insert().unwrap();
    assert!(later > inserted);
    d.discard();
    assert_eq!(d.rows.len(), 1);
    assert_eq!(d.pending(), 0);
    assert_eq!(d.rows[0].id, 100);
    assert!(d.rows[0].values[2] == backend::CellValue::Text("base".into()));
}
#[test]
fn capability_reasons_come_from_metadata_and_never_from_native_type_whitelists() {
    let (set, mut meta) = fixture();
    assert!(readonly_reason(true, true, false, &meta).is_none());
    assert!(
        readonly_reason(false, true, false, &meta)
            .unwrap()
            .contains("Views")
    );
    assert!(
        readonly_reason(true, false, false, &meta)
            .unwrap()
            .contains("Connect")
    );
    assert!(
        readonly_reason(true, true, true, &meta)
            .unwrap()
            .contains("Readonly")
    );
    for m in &mut meta {
        m.primary_key = 0;
    }
    assert!(
        readonly_reason(true, true, false, &meta)
            .unwrap()
            .contains("primary key")
    );
    meta[0].primary_key = 1;
    for m in &mut meta {
        m.editable = false;
        m.edit_reason = "Data editing requires an InnoDB table with a primary key.".into();
    }
    assert!(
        readonly_reason(true, true, false, &meta)
            .unwrap()
            .contains("InnoDB")
    );
    for m in &mut meta {
        m.edit_reason = "This table contains an unsupported type and is read only.".into();
    }
    assert!(
        readonly_reason(true, true, false, &meta)
            .unwrap()
            .contains("unsupported type")
    );
    // MySQL can reject just one column; a helper-approved unfamiliar type stays editable.
    meta[2].editable = true;
    meta[2].native_type = "future adapter type".into();
    assert!(readonly_reason(true, true, false, &meta).is_none());
    assert!(ColumnPolicy::new(&set.columns[2], &meta[2]).editable);
    for m in &mut meta {
        m.editable = false;
        m.generated = "identity always".into();
        m.edit_reason = "The server generates this value.".into();
    }
    assert!(readonly_reason(true, true, false, &meta).is_none());
}
#[test]
fn duplicate_metadata_is_ordinal_and_default_clipboard_is_swift_v1() {
    let (mut set, mut meta) = fixture();
    set.columns[1].name = "id".into();
    meta[1].name = "id".into();
    let d = Draft::new(&set, meta.clone(), 1, &[1]).unwrap();
    assert_eq!(d.fingerprint.metadata[0].primary_key, 1);
    assert_eq!(d.fingerprint.metadata[1].primary_key, 2);
    meta.swap(0, 1);
    assert!(Draft::new(&set, meta, 1, &[1]).is_some());
    let v = clipboard(&backend::CellValue::Default);
    assert_eq!(v.kind, "default");
    assert_eq!(v.tsv(), "<DEFAULT>");
    assert_eq!(
        clipboard(&backend::CellValue::Text("DEFAULT".into())).kind,
        "text"
    );
    assert_eq!(
        clipboard(&backend::CellValue::Text("".into())).tsv(),
        "\"\""
    );
    assert_eq!(clipboard(&backend::CellValue::Null).tsv(), "\\N");
    set.columns[2].index = 0;
    assert!(Draft::new(&set, d.fingerprint.metadata, 1, &[1]).is_none());
}
