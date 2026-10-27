use std::sync::atomic::{AtomicU64, Ordering};
static PUBLICATION: AtomicU64 = AtomicU64::new(0);
pub(crate) fn publication_status() -> u64 {
    PUBLICATION.load(Ordering::Acquire)
}
pub(super) fn publication(accepted: bool) {
    let old = PUBLICATION.load(Ordering::Relaxed);
    PUBLICATION.store(
        (old & !1).wrapping_add(2) | u64::from(accepted),
        Ordering::Release,
    );
}
// DBeer maintained patch: explicitly promoted native targets, not private metadata.
use gpui::{ClipboardEntry, ClipboardItem};

pub(super) fn formats(item: &ClipboardItem) -> Vec<(String, Vec<u8>)> {
    let Some(ClipboardEntry::String(text)) = item.entries.first() else {
        return Vec::new();
    };
    let Some(metadata) = &text.metadata else {
        return Vec::new();
    };
    if metadata.len() > 64 * 1024 * 1024 {
        return Vec::new();
    }
    let Ok(value) = serde_json::from_str::<serde_json::Value>(metadata) else {
        return Vec::new();
    };
    let Some(object) = value.as_object().filter(|o| o.len() == 1) else {
        return Vec::new();
    };
    let Some(entries) = object
        .get("dbeerNativeClipboardV1")
        .and_then(|v| v.as_array())
        .filter(|a| a.len() == 3)
    else {
        return Vec::new();
    };
    let names = [
        "dev.dbeer.result-selection+json",
        "application/vnd.dbeer.result-selection+json",
        "text/tab-separated-values",
    ];
    let mut output = Vec::new();
    for (entry, name) in entries.iter().zip(names) {
        if entry.as_object().is_none_or(|o| o.len() != 2)
            || entry.get("mime").and_then(|v| v.as_str()) != Some(name)
        {
            return Vec::new();
        }
        let Some(data) = entry.get("data").and_then(|v| v.as_str()) else {
            return Vec::new();
        };
        output.push((name.to_owned(), data.as_bytes().to_vec()));
    }
    if output[0].1 != output[1].1 || output[2].1 != text.text.as_bytes() {
        return Vec::new();
    }
    output
}

#[cfg(test)]
mod tests {
    use super::*;
    #[test]
    fn ordinary_metadata_and_unknown_formats_never_become_external_targets() {
        let before = publication_status();
        publication(false);
        assert_ne!(publication_status(), before);
        assert_eq!(publication_status() & 1, 0);
        publication(true);
        assert_eq!(publication_status() & 1, 1);
        assert!(
            formats(&ClipboardItem::new_string_with_metadata(
                "text".into(),
                "{}".into()
            ))
            .is_empty()
        );
        let entries = [
            "dev.dbeer.result-selection+json",
            "application/vnd.dbeer.result-selection+json",
            "text/tab-separated-values",
        ]
        .map(|mime| serde_json::json!({"mime": mime, "data": "synthetic"}));
        let item = ClipboardItem::new_string_with_metadata(
            "synthetic".into(),
            serde_json::json!({"dbeerNativeClipboardV1": entries}).to_string(),
        );
        assert_eq!(formats(&item).len(), 3);
        assert_eq!(formats(&item)[0].1, b"synthetic");
        for invalid in [
            "{}",
            "{\"dbeerNativeClipboardV1\":[]}",
            "{\"dbeerNativeClipboardV1\":[{\"mime\":\"text/html\",\"data\":\"synthetic\"}]}",
        ] {
            assert!(
                formats(&ClipboardItem::new_string_with_metadata(
                    "synthetic".into(),
                    invalid.into()
                ))
                .is_empty()
            );
        }
    }
}
