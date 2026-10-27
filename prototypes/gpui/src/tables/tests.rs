use super::{MAX_PAGE, Navigation, OPERATORS, ReplacementLocks, validate_snapshot};
use crate::{backend, catalog};
use backend::{CatalogFilter, CatalogRequest, FilterOperator};

fn set(names: &[&str], rows: Vec<Vec<Option<&str>>>) -> backend::ResultSet {
    backend::ResultSet {
        columns: names
            .iter()
            .enumerate()
            .map(|(index, name)| backend::Column {
                index,
                name: (*name).into(),
                engine: "postgresql".into(),
                native_type: "text".into(),
                type_oid: 25,
                encoding: None,
            })
            .collect(),
        rows: rows
            .into_iter()
            .map(|r| r.into_iter().map(|v| v.map(str::to_owned)).collect())
            .collect(),
        ..Default::default()
    }
}
fn metadata() -> backend::ResultSet {
    set(
        &[
            "name",
            "nativeType",
            "nullable",
            "default",
            "generated",
            "primaryKey",
            "editable",
            "editReason",
        ],
        vec![vec![
            Some("id"),
            Some("numeric(65,30)"),
            Some("true"),
            None,
            Some(""),
            Some("1"),
            Some("true"),
            Some(""),
        ]],
    )
}
fn node() -> catalog::NodeId {
    catalog::NodeId::Object {
        schema: "a.b\"😀".into(),
        object: catalog::CatalogObject {
            name: "x`; DROP TABLE y".into(),
            kind: "table".into(),
            identity: Some("opaque-id".into()),
        },
    }
}
#[test]
fn all_nine_operators_keep_exact_typed_values_and_adapter_object_identity() {
    for &(operator, _) in OPERATORS {
        for value in [
            "",
            "NULL",
            "0",
            "9007199254740993.000000000000000001",
            "AP8=",
            "NaN",
            "1e999999999",
            "%%%",
            "A",
            "x' OR 1=1 --",
            "%_\\",
        ] {
            let null_operator =
                matches!(operator, FilterOperator::IsNull | FilterOperator::IsNotNull);
            let nav = Navigation {
                filters: vec![CatalogFilter {
                    column: "quoted \" column".into(),
                    operator,
                    value: (!null_operator).then(|| value.into()),
                }],
                ..Default::default()
            };
            let request = nav.request(&node()).unwrap();
            assert_eq!(request.kind, "browse");
            assert_eq!(request.object, "x`; DROP TABLE y");
            assert!(request.identity.is_empty());
            assert_eq!(
                request.filters[0].value.as_deref(),
                (!null_operator).then_some(value)
            );
            let roundtrip: CatalogRequest =
                serde_json::from_str(&serde_json::to_string(&request).unwrap()).unwrap();
            assert!(roundtrip == request);
        }
    }
}
#[test]
fn limits_reject_overflow_and_accidental_string_null_operator_values() {
    let mut nav = Navigation {
        page: MAX_PAGE,
        ..Default::default()
    };
    assert!(nav.request(&node()).is_some());
    nav.page = MAX_PAGE + 1;
    assert!(nav.request(&node()).is_none());
    nav.page = u32::MAX;
    assert!(nav.request(&node()).is_none());
    nav.page = 0;
    nav.filters.push(CatalogFilter {
        column: "id".into(),
        operator: FilterOperator::IsNull,
        value: Some("NULL".into()),
    });
    assert!(nav.request(&node()).is_none());
    nav.filters[0].operator = FilterOperator::Eq;
    nav.filters[0].value = None;
    assert!(nav.request(&node()).is_none());
}
#[test]
fn complete_metadata_brackets_rows_and_rejects_ddl_width_ordinal_engine_and_partial_pages() {
    let meta = metadata();
    for count in [0, 1, 199, 200] {
        let rows = set(&["id"], vec![vec![Some("0")]; count]);
        let sets = [meta.clone(), rows, meta.clone()];
        let parsed = validate_snapshot(&sets, "postgresql", false).unwrap();
        assert_eq!(parsed[0].native_type, "numeric(65,30)");
        assert_eq!(parsed[0].primary_key, 1);
        assert_eq!(parsed[0].default, None);
    }
    let rows = set(&["id"], vec![vec![Some("NULL")]]);
    let mut sets = [meta.clone(), rows, meta.clone()];
    sets[2].rows[0][4] = Some("generated expression".into());
    assert!(validate_snapshot(&sets, "postgresql", false).is_err());
    sets[2] = meta.clone();
    sets[1].rows[0].push(None);
    assert!(validate_snapshot(&sets, "postgresql", false).is_err());
    sets[1] = set(&["new_name"], vec![]);
    assert!(validate_snapshot(&sets, "postgresql", false).is_err());
    sets[1] = set(&["id"], vec![]);
    sets[1].columns[0].index = 1;
    assert!(validate_snapshot(&sets, "postgresql", false).is_err());
    sets[1].columns[0].index = 0;
    sets[1].columns[0].engine = "mysql".into();
    assert!(validate_snapshot(&sets, "postgresql", false).is_err());
    sets[1] = set(&["id"], vec![vec![None]; 201]);
    assert!(validate_snapshot(&sets, "postgresql", false).is_err());
    sets[1] = set(&["id"], vec![]);
    assert!(validate_snapshot(&sets, "postgresql", true).is_err());
    sets[0].rows.clear();
    sets[2].rows.clear();
    assert!(validate_snapshot(&sets, "postgresql", false).is_err());
}
#[test]
fn every_future_replacement_lock_blocks_navigation_without_edit_implementation() {
    let mut locks = ReplacementLocks::default();
    assert!(!locks.locked());
    locks.inline_draft = true;
    assert!(locks.locked());
    locks.inline_draft = false;
    locks.staged_changes = 1;
    assert!(locks.locked());
    locks.staged_changes = 0;
    locks.previewing = true;
    assert!(locks.locked());
    locks.previewing = false;
    locks.applying = true;
    assert!(locks.locked());
    locks.applying = false;
    locks.outcome_unknown = true;
    assert!(locks.locked());
    locks.outcome_unknown = false;
    locks.closing = true;
    assert!(locks.locked());
}
