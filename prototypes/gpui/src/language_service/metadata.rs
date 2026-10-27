//! Pure completion metadata paging. This module has no connection/session API.
use super::{Error, Result};
use crate::backend::{
    CatalogRequest, CompletionMetadata, ForeignKey, FunctionSignature, ResultSet,
};
use serde::Serialize;
use std::sync::Arc;

const MAX_ENTRIES: usize = 2048;
const MAX_BYTES: usize = 3 * 1024 * 1024;
const MAX_LOAD_BYTES: usize = 8 * 1024 * 1024;

#[derive(Clone, Serialize)]
#[serde(rename_all = "camelCase")]
pub struct Relation {
    pub schema: String,
    pub name: String,
    pub kind: String,
    pub columns: Vec<String>,
    pub foreign_keys: Vec<ForeignKey>,
    pub signatures: Vec<FunctionSignature>,
}
impl From<CompletionMetadata> for Relation {
    fn from(value: CompletionMetadata) -> Self {
        Self {
            schema: value.schema,
            name: value.name,
            kind: value.kind,
            columns: value.columns,
            foreign_keys: value.foreign_keys,
            signatures: value.signatures,
        }
    }
}

/// Immutable bounded payload. Opaque profile/settings/session identities never
/// enter this serializable DTO or the offline child environment.
#[derive(Clone, Default)]
pub struct CatalogSnapshot {
    relations: Arc<[Relation]>,
    pub truncated: bool,
}
impl CatalogSnapshot {
    pub fn relations(&self) -> &[Relation] {
        &self.relations
    }

    /// Match the Go server's configuration limits, preserving deterministic
    /// useful prefixes. No SQL completion/ranking/quoting logic lives here.
    pub fn bounded(relations: impl IntoIterator<Item = Relation>) -> Self {
        let mut result = Vec::new();
        let mut bytes = 0;
        let mut columns = 0;
        let mut key_columns = 0;
        let mut parameters = 0;
        let mut truncated = false;
        for mut relation in relations {
            if result.len() == MAX_ENTRIES {
                truncated = true;
                break;
            }
            if !matches!(relation.kind.as_str(), "table" | "view" | "function")
                || relation.name.is_empty()
                || relation.name.len() > 1024
                || relation.schema.len() > 1024
            {
                truncated = true;
                continue;
            }
            let original = relation.columns.len();
            relation.columns.retain(|column| column.len() <= 1024);
            relation
                .columns
                .truncate(32_768_usize.saturating_sub(columns));
            truncated |= original != relation.columns.len();
            let original = relation.foreign_keys.len();
            relation.foreign_keys.retain(|key| {
                key.name.len() <= 1024
                    && !key.target_table.is_empty()
                    && key.target_table.len() <= 1024
                    && key.target_schema.len() <= 1024
                    && !key.columns.is_empty()
                    && key.columns.len() <= 32
                    && key.columns.iter().all(|pair| {
                        !pair.source.is_empty()
                            && !pair.target.is_empty()
                            && pair.source.len() <= 1024
                            && pair.target.len() <= 1024
                    })
            });
            relation.foreign_keys.truncate(64);
            let mut relation_keys = 0;
            relation.foreign_keys.retain(|key| {
                if key_columns + relation_keys + key.columns.len() > 8192 {
                    return false;
                }
                relation_keys += key.columns.len();
                true
            });
            truncated |= original != relation.foreign_keys.len();
            let original = relation.signatures.len();
            relation.signatures.retain(|signature| {
                !signature.return_type.is_empty()
                    && signature.return_type.len() <= 4096
                    && signature.parameters.len() <= 256
                    && signature.parameters.iter().all(|parameter| {
                        parameter.name.len() <= 1024
                            && !parameter.native_type.is_empty()
                            && parameter.native_type.len() <= 1024
                            && parameter.position <= 256
                    })
            });
            relation.signatures.truncate(32);
            let mut relation_parameters = 0;
            relation.signatures.retain(|signature| {
                if parameters + relation_parameters + signature.parameters.len() > 8192 {
                    return false;
                }
                relation_parameters += signature.parameters.len();
                true
            });
            // The Swift facade supplies ordinal positions for legacy omitted 0.
            for signature in &mut relation.signatures {
                for (index, parameter) in signature.parameters.iter_mut().enumerate() {
                    if parameter.position == 0 {
                        parameter.position = (index + 1) as u32;
                    }
                }
            }
            truncated |= original != relation.signatures.len();
            let length = serde_json::to_vec(&relation).map_or(MAX_BYTES + 1, |value| value.len());
            if bytes + length + result.len() + 2 > MAX_BYTES {
                // Keep names from large relations rather than losing every
                // later name to one oversized column/signature collection.
                relation.columns.clear();
                relation.foreign_keys.clear();
                relation.signatures.clear();
                truncated = true;
                let length =
                    serde_json::to_vec(&relation).map_or(MAX_BYTES + 1, |value| value.len());
                if bytes + length + result.len() + 2 > MAX_BYTES {
                    break;
                }
                bytes += length;
            } else {
                bytes += length;
                columns += relation.columns.len();
                key_columns += relation_keys;
                parameters += relation_parameters;
            }
            result.push(relation);
        }
        Self {
            relations: result.into(),
            truncated,
        }
    }
}

/// Created only by the connected catalog scheduler from its original captured
/// context. Compare it plus the actual original BackendClient/session before
/// dispatch and after every page. Revisions must never be reused for new owners.
#[derive(Clone, Debug, PartialEq, Eq)]
pub struct CatalogOwner {
    pub profile_id: String,
    pub settings_revision: u64,
    pub service_generation: u64,
    pub catalog_revision: u64,
}

/// Sequential 200-object protocol pages; publication is atomic only at finish.
/// A failed/stale/truncated page leaves the caller's previous snapshot intact.
pub struct CatalogPager {
    owner: CatalogOwner,
    page: u32,
    relations: Vec<Relation>,
    bytes: usize,
    complete: bool,
    capped: bool,
}
impl CatalogPager {
    pub fn new(owner: CatalogOwner) -> Self {
        Self {
            owner,
            page: 0,
            relations: Vec::new(),
            bytes: 0,
            complete: false,
            capped: false,
        }
    }
    pub fn next_request(&self) -> Option<CatalogRequest> {
        (!self.complete).then(|| CatalogRequest {
            kind: "completion".into(),
            page: self.page,
            ..Default::default()
        })
    }
    pub fn accept_page(
        &mut self,
        owner: &CatalogOwner,
        page: u32,
        sets: &[ResultSet],
    ) -> Result<bool> {
        if owner != &self.owner || page != self.page || self.complete {
            return Err(Error::Stale);
        }
        let [set] = sets else {
            return Err(Error::InvalidMessage);
        };
        if set.truncated || set.rows.len() > 200 {
            return Err(Error::Limit);
        }
        let metadata = set
            .completion_metadata()
            .map_err(|_| Error::InvalidMessage)?;
        let mut page_relations = Vec::new();
        let mut page_bytes = 0;
        for value in metadata {
            let relation = Relation::from(value);
            page_bytes += serde_json::to_vec(&relation)
                .map_err(|_| Error::InvalidMessage)?
                .len();
            if self.bytes + page_bytes > MAX_LOAD_BYTES {
                return Err(Error::Limit);
            }
            page_relations.push(relation);
        }
        self.bytes += page_bytes;
        self.relations.extend(page_relations);
        self.page += 1;
        self.capped = self.page == 50 && set.rows.len() == 200;
        self.complete = set.rows.len() < 200 || self.page == 50;
        Ok(self.complete)
    }
    pub fn finish(self, owner: &CatalogOwner) -> Result<CatalogSnapshot> {
        if owner != &self.owner || !self.complete {
            return Err(Error::Stale);
        }
        let mut snapshot = CatalogSnapshot::bounded(self.relations);
        snapshot.truncated |= self.capped;
        Ok(snapshot)
    }
}
