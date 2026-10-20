//! Lazy catalog tree and bounded service-session work. No SQL or identifier quoting lives here.
use super::*;
use backend::{CatalogRequest, ResultSet, TableColumnMetadata};
use gpui_kit::component::menu::{ContextMenuExt, DropdownMenu, PopupMenu, PopupMenuItem};
use live::{collect, connect_saved};
use std::collections::HashMap;
mod completion;
use completion::*;

pub(super) const OBJECT_GROUPS: &[(&str, &str)] = &[
    ("Tables", "table"),
    ("Views", "view"),
    ("Functions", "function"),
    ("Procedures", "procedure"),
    ("Triggers", "trigger"),
];
pub(super) const DETAIL_GROUPS: &[(&str, &str)] = &[
    ("Columns", "columns"),
    ("Keys", "keys"),
    ("Indexes", "indexes"),
    ("Constraints", "constraints"),
    ("Triggers", "triggers"),
];
#[derive(Clone, PartialEq, Eq, Hash)]
pub(super) struct CatalogObject {
    pub name: String,
    pub kind: String,
    /// Opaque helper identity, including PostgreSQL routine overload OIDs.
    pub identity: Option<String>,
}
impl CatalogObject {
    pub(super) fn relation(&self) -> bool {
        matches!(self.kind.as_str(), "table" | "view")
    }
}
#[derive(Clone, PartialEq, Eq, Hash)]
pub(super) enum NodeId {
    Schema(String),
    Group {
        schema: String,
        kind: String,
    },
    Object {
        schema: String,
        object: CatalogObject,
    },
    DetailGroup {
        schema: String,
        object: CatalogObject,
        kind: String,
    },
    Detail {
        schema: String,
        object: CatalogObject,
        kind: String,
        ordinal: usize,
    },
}
impl NodeId {
    pub(super) fn object(&self) -> Option<(&str, &CatalogObject)> {
        match self {
            Self::Object { schema, object }
            | Self::DetailGroup { schema, object, .. }
            | Self::Detail { schema, object, .. } => Some((schema, object)),
            _ => None,
        }
    }
    fn expandable(&self) -> bool {
        match self {
            Self::Schema(_) | Self::Group { .. } | Self::DetailGroup { .. } => true,
            Self::Object { object, .. } => object.relation(),
            _ => false,
        }
    }
    fn request(&self) -> Option<CatalogRequest> {
        match self {
            Self::Group { schema, kind } => Some(CatalogRequest {
                kind: "objects".into(),
                schema: schema.clone(),
                object_kind: kind.clone(),
                ..Default::default()
            }),
            Self::DetailGroup {
                schema,
                object,
                kind,
            } => Some(object_request(schema, object, kind)),
            _ => None,
        }
    }
}
pub(super) struct CatalogSchema {
    pub name: String,
    pub id: NodeId,
    pub expanded: bool,
    pub loaded: bool,
    pub children: Vec<CatalogSchema>,
    pub error: Option<String>,
    pub loading: bool,
    pub truncated: bool,
    /// Original ordinal metadata, including SQL NULL and exact native types.
    pub data: Option<ResultSet>,
}
impl CatalogSchema {
    pub(super) fn schema(name: String) -> Self {
        Self::new(name.clone(), NodeId::Schema(name))
    }
    fn new(name: String, id: NodeId) -> Self {
        Self {
            name,
            id,
            expanded: false,
            loaded: false,
            children: Vec::new(),
            error: None,
            loading: false,
            truncated: false,
            data: None,
        }
    }
    fn find_mut<'a>(nodes: &'a mut [Self], id: &NodeId) -> Option<&'a mut Self> {
        for node in nodes {
            if &node.id == id {
                return Some(node);
            }
            if let Some(found) = Self::find_mut(&mut node.children, id) {
                return Some(found);
            }
        }
        None
    }
    fn local_children(&self) -> Option<Vec<Self>> {
        match &self.id {
            NodeId::Schema(schema) => Some(
                OBJECT_GROUPS
                    .iter()
                    .map(|(label, kind)| {
                        Self::new(
                            (*label).into(),
                            NodeId::Group {
                                schema: schema.clone(),
                                kind: (*kind).into(),
                            },
                        )
                    })
                    .collect(),
            ),
            NodeId::Object { schema, object } if object.relation() => Some(
                DETAIL_GROUPS
                    .iter()
                    .map(|(label, kind)| {
                        Self::new(
                            (*label).into(),
                            NodeId::DetailGroup {
                                schema: schema.clone(),
                                object: object.clone(),
                                kind: (*kind).into(),
                            },
                        )
                    })
                    .collect(),
            ),
            _ => None,
        }
    }
}
/// Captured command target. Never log connection settings or object/SQL data.
#[derive(Clone)]
pub(super) struct CatalogTarget {
    pub profile: ProfileId,
    settings: ConnectionProfile,
    generation: u64,
    session: String,
    client: BackendClient,
    pub node: NodeId,
    search_revision: Option<u64>,
}
impl CatalogTarget {
    pub(super) fn changes_settings(&self) -> &ConnectionProfile {
        &self.settings
    }
    pub(super) fn changes_client(&self) -> &BackendClient {
        &self.client
    }
}
#[derive(Clone)]
pub(super) struct CatalogContext {
    profile: ProfileId,
    settings: ConnectionProfile,
    generation: u64,
    service_generation: u64,
    session: Option<String>,
    client: BackendClient,
}
impl CatalogContext {
    fn capture(profile: &mut Profile, client: BackendClient) -> Option<Self> {
        let settings = profile.config.clone()?;
        profile.generation += 1;
        Some(Self {
            profile: profile.id.clone(),
            settings,
            generation: profile.generation,
            service_generation: profile.service_generation,
            session: profile.session.clone(),
            client,
        })
    }
    fn matches(&self, profile: &Profile) -> bool {
        profile.id == self.profile
            && profile.generation == self.generation
            && profile.service_generation == self.service_generation
            && profile.config.as_ref() == Some(&self.settings)
            && profile.session == self.session
            && (profile.session.is_none()
                || profile.session_settings.as_ref() == Some(&self.settings))
    }
}
#[derive(Default)]
pub(super) struct CatalogState {
    pub selected: Option<CatalogTarget>,
    pub search: SearchState,
    completion: CompletionState,
}
#[derive(Default)]
pub(super) struct SearchState {
    pub revision: u64,
    pub query: String,
    debounce: Option<Task<()>>,
    ready: bool,
    pub entries: HashMap<ProfileId, SearchEntry>,
}
pub(super) struct SearchEntry {
    revision: u64,
    pub nodes: Vec<CatalogSchema>,
    pub loading: bool,
    pub error: Option<String>,
    pub truncated: bool,
}
pub(super) struct CatalogDocument {
    pub target: CatalogTarget,
    /// Atomically replaced with a successful browse snapshot, never persisted.
    pub columns: Vec<TableColumnMetadata>,
    pub structure: Option<ResultSet>,
    pub definition: Option<String>,
    pub loading: bool,
    pub table: Option<tables::TableDocument>,
}
#[derive(Clone)]
enum Work {
    Completion {
        revision: u64,
    },
    Table {
        target: Box<CatalogTarget>,
        document: DocumentId,
        request: tables::Request,
    },
    Node {
        id: NodeId,
        search_revision: Option<u64>,
    },
    Search {
        revision: u64,
        query: String,
    },
    Action {
        command: CommandId,
        target: Box<CatalogTarget>,
        document: Option<DocumentId>,
    },
}
struct WorkOutput {
    completion: Option<language_service::CatalogSnapshot>,
    sets: Vec<ResultSet>,
    truncated: bool,
    notice: String,
}
pub(super) fn object_request(schema: &str, object: &CatalogObject, kind: &str) -> CatalogRequest {
    CatalogRequest {
        kind: kind.into(),
        schema: schema.into(),
        object: object.name.clone(),
        object_kind: object.kind.clone(),
        identity: if matches!(kind, "definition" | "name") {
            object.identity.clone().unwrap_or_default()
        } else {
            String::new()
        },
        ..Default::default()
    }
}
/// Catalog fields are uniquely validated at the backend; do not use this for SQL rows.
fn value<'a>(set: &'a ResultSet, row: &'a [Option<String>], key: &str) -> Option<&'a str> {
    let index = set.columns.iter().position(|c| c.name == key)?;
    row.get(index)?.as_deref()
}
fn first_value<'a>(sets: &'a [ResultSet], key: &str) -> Option<&'a str> {
    let set = sets.first()?;
    value(set, set.rows.first()?, key)
}
fn object_nodes(set: &ResultSet) -> Vec<CatalogSchema> {
    set.rows
        .iter()
        .filter_map(|row| {
            let schema = value(set, row, "schema")?.to_string();
            let object = CatalogObject {
                name: value(set, row, "name")?.into(),
                kind: value(set, row, "kind")?.into(),
                identity: value(set, row, "identity").map(str::to_owned),
            };
            Some(CatalogSchema::new(
                object.name.clone(),
                NodeId::Object { schema, object },
            ))
        })
        .collect()
}
fn detail_nodes(id: &NodeId, set: &ResultSet) -> Vec<CatalogSchema> {
    let NodeId::DetailGroup {
        schema,
        object,
        kind,
    } = id
    else {
        return Vec::new();
    };
    set.rows
        .iter()
        .enumerate()
        .map(|(ordinal, row)| {
            let name = value(set, row, "name").unwrap_or("NULL");
            let label = if kind == "columns" {
                format!(
                    "{}: {}",
                    name,
                    value(set, row, "nativeType").unwrap_or("NULL")
                )
            } else {
                format!(
                    "{}: {}",
                    name,
                    value(set, row, "definition").unwrap_or("NULL")
                )
            };
            CatalogSchema::new(
                label,
                NodeId::Detail {
                    schema: schema.clone(),
                    object: object.clone(),
                    kind: kind.clone(),
                    ordinal,
                },
            )
        })
        .collect()
}
impl Work {
    fn requests(&self) -> Vec<CatalogRequest> {
        match self {
            Self::Completion { .. } => Vec::new(),
            Self::Table {
                target, request, ..
            } => {
                let (schema, object) = target.node.object().unwrap();
                vec![
                    object_request(schema, object, "columns"),
                    request.navigation.request(&target.node).unwrap(),
                    object_request(schema, object, "columns"),
                ]
            }
            Self::Node { id, .. } => id.request().into_iter().collect(),
            Self::Search { query, .. } => vec![CatalogRequest {
                kind: "search".into(),
                search: query.clone(),
                ..Default::default()
            }],
            Self::Action {
                command, target, ..
            } => {
                let Some((schema, object)) = target.node.object() else {
                    return Vec::new();
                };
                match command {
                    CommandId::CatalogInspect | CommandId::CatalogDefinition => {
                        let mut requests = Vec::new();
                        if object.relation() {
                            requests.push(object_request(schema, object, "columns"));
                        }
                        requests.push(object_request(schema, object, "definition"));
                        requests
                    }
                    CommandId::CatalogGenerateSelect => {
                        vec![object_request(schema, object, "select")]
                    }
                    CommandId::CatalogCopyName => vec![object_request(schema, object, "name")],
                    _ => Vec::new(),
                }
            }
        }
    }
}
impl Workspace {
    pub(super) fn start_table_work(
        &mut self,
        target: CatalogTarget,
        document: DocumentId,
        request: tables::Request,
        window: &mut Window,
        cx: &mut Context<Self>,
    ) {
        let work = Work::Table {
            target: Box::new(target.clone()),
            document,
            request,
        };
        let Some(index) = self.profile_index(&target.profile) else {
            self.retire_table_work(&work);
            return;
        };
        if !self.catalog_target_valid(&target) {
            self.retire_table_work(&work);
            return;
        }
        self.start_catalog_work(index, work.clone(), window, cx);
        if self.profiles[index].task.is_none() {
            self.retire_table_work(&work);
        }
    }
    fn table_work_valid(&self, work: &Work) -> bool {
        let Work::Table {
            target,
            document,
            request,
        } = work
        else {
            return true;
        };
        self.tabs
            .iter()
            .find(|t| t.id == *document)
            .is_some_and(|tab| {
                !self.closing
                    && !tab.snapshot_locked()
                    && tab.profile == target.profile
                    && tab.catalog_document.as_ref().is_some_and(|doc| {
                        doc.target.node == target.node
                            && doc.table.as_ref().is_some_and(|t| t.owns(request))
                    })
            })
    }
    fn retire_table_work(&mut self, work: &Work) {
        if let Work::Table {
            document, request, ..
        } = work
            && let Some(tab) = self.tabs.iter_mut().find(|t| t.id == *document)
            && let Some(doc) = &mut tab.catalog_document
            && let Some(table) = &mut doc.table
            && table.pending.as_ref() == Some(request)
        {
            table.fail(request);
            doc.loading = false;
            tab.error = true;
            tab.status =
                "The table request context changed. Connect explicitly if needed, then refresh."
                    .into();
        }
    }
    #[allow(clippy::too_many_arguments)]
    fn complete_table_work(
        &mut self,
        context: &CatalogContext,
        target: &CatalogTarget,
        id: DocumentId,
        request: &tables::Request,
        output: WorkOutput,
        window: &mut Window,
        cx: &mut Context<Self>,
    ) {
        let columns = match tables::validate_snapshot(
            &output.sets,
            &context.settings.engine,
            output.truncated,
        ) {
            Ok(columns) => columns,
            Err(message) => {
                let mut error = backend::BackendError::transport(message);
                error.connected = true;
                self.catalog_failure(
                    context,
                    Some(&Work::Table {
                        target: Box::new(target.clone()),
                        document: id,
                        request: request.clone(),
                    }),
                    &error,
                );
                return;
            }
        };
        let Some(tab) = self.tabs.iter_mut().find(|t| t.id == id) else {
            return;
        };
        let doc = tab.catalog_document.as_mut().unwrap();
        let table = doc.table.as_mut().unwrap();
        if !table.commit(request, output.sets[1].rows.len()) {
            return;
        }
        // Single UI turn: metadata, capabilities, rows and committed navigation publish together.
        // Task 16 may retain ordinal view state only when old/new metadata schemas match.
        let schema_changed = doc.columns != columns;
        doc.columns = columns;
        doc.structure = Some(output.sets[0].clone());
        doc.target = target.clone();
        doc.target.generation = context.generation;
        doc.loading = false;
        if schema_changed {
            table.filter_column = 0;
            tab.grid = None;
        }
        let no_key = !doc.columns.iter().any(|c| c.primary_key != 0);
        tab.result_sets = vec![output.sets[1].clone()];
        tab.selected_result = 0;
        tab.error = false;
        tab.status = if no_key {
            tables::NO_KEY_NOTICE.into()
        } else if output.notice.is_empty() {
            "Read-only table snapshot. A full page may have a following page; no total count was requested.".into()
        } else {
            output.notice.into()
        };
        self.render_live_result(id, window, cx);
        self.complete_changes_inspection(id);
    }
    pub(super) fn refresh_connection_flags(&mut self) {
        for profile in &mut self.profiles {
            if profile.config.is_some() {
                profile.loaded = profile.session.is_some()
                    || self
                        .tabs
                        .iter()
                        .any(|tab| tab.profile == profile.id && tab.session.is_some());
            }
        }
    }
    pub(super) fn catalog_target(&self, index: usize, node: NodeId) -> Option<CatalogTarget> {
        let profile = self.profiles.get(index)?;
        let client = self.backend.as_ref().filter(|c| c.is_alive())?;
        let settings = profile.config.clone()?;
        if profile.session_settings.as_ref() != Some(&settings) {
            return None;
        }
        Some(CatalogTarget {
            profile: profile.id.clone(),
            settings,
            generation: profile.generation,
            session: profile.session.clone()?,
            client: client.clone(),
            node,
            search_revision: None,
        })
    }
    pub(super) fn catalog_target_valid(&self, target: &CatalogTarget) -> bool {
        target
            .search_revision
            .is_none_or(|r| r == self.catalog.search.revision)
            && self.profiles.iter().any(|p| {
                p.id == target.profile
                    && p.generation == target.generation
                    && p.config.as_ref() == Some(&target.settings)
                    && p.session.as_ref() == Some(&target.session)
                    && p.session_settings.as_ref() == Some(&target.settings)
            })
            && target.client.is_alive()
            && self
                .backend
                .as_ref()
                .is_some_and(|c| c.same_instance(&target.client))
    }
    pub(super) fn catalog_action_available(
        &self,
        command: CommandId,
        target: &CatalogTarget,
    ) -> Result<(), &'static str> {
        if !self.catalog_target_valid(target) {
            return Err("The captured catalog connection changed. Select the object again.");
        }
        if self.profile(&target.profile).task.is_some() {
            return Err("Wait for the current catalog operation.");
        }
        match command {
            CommandId::CatalogRetrySearch if !self.catalog.search.query.is_empty() => Ok(()),
            CommandId::CatalogExpand | CommandId::CatalogRefresh if target.node.expandable() => {
                Ok(())
            }
            CommandId::CatalogInspect
            | CommandId::CatalogDefinition
            | CommandId::CatalogCopyName
                if target.node.object().is_some() =>
            {
                Ok(())
            }
            CommandId::CatalogOpenData | CommandId::CatalogGenerateSelect
                if target.node.object().is_some_and(|(_, o)| o.relation()) =>
            {
                Ok(())
            }
            _ => Err("Select an object that supports this catalog action."),
        }
    }
    pub(super) fn catalog_owner(&self, context: &CatalogContext) -> Option<usize> {
        self.profiles
            .iter()
            .position(|p| p.id == context.profile && p.generation == context.generation)
    }
    pub(super) fn catalog_valid(&self, context: &CatalogContext) -> Option<usize> {
        if !context.client.is_alive()
            || !self
                .backend
                .as_ref()
                .is_some_and(|c| c.same_instance(&context.client))
        {
            return None;
        }
        self.catalog_owner(context)
            .filter(|&i| context.matches(&self.profiles[i]))
    }
    pub(super) fn catalog_settings_match(&mut self, index: usize, cx: &mut Context<Self>) -> bool {
        let profile = &mut self.profiles[index];
        if profile.session.is_some() && profile.session_settings != profile.config {
            profile.status =
                "Disconnect the catalog session before using changed connection settings.".into();
            cx.notify();
            return false;
        }
        true
    }
    pub fn connect_profile(&mut self, index: usize, window: &mut Window, cx: &mut Context<Self>) {
        if self.closing
            || window.has_active_dialog(cx)
            || (self.file_request.is_some()
                || (self.export_request.is_some() || self.run_file.is_some()))
        {
            return;
        }
        if self.profiles[index].task.is_some() {
            let id = self.profiles[index].id.clone();
            self.invalidate_completion(&id, false);
            self.catalog.completion.refresh.insert(id);
            self.sync_assistance(cx);
            return;
        }
        let Some(settings) = self.profiles[index].config.clone() else {
            return;
        };
        if !self.catalog_settings_match(index, cx) {
            return;
        }
        let client = match if self.profiles[index].session.is_some() {
            self.profiles[index].session_client.clone().filter(|c|c.is_alive() && self.backend.as_ref().is_some_and(|current|current.same_instance(c)))
                .ok_or_else(||"Disconnect the original catalog session before reconnecting with another helper.".to_owned())
        } else {
            self.client()
        } {
            Ok(c) => c,
            Err(e) => {
                self.profiles[index].status = e.into();
                cx.notify();
                return;
            }
        };
        let id = self.profiles[index].id.clone();
        self.invalidate_completion(&id, true);
        self.sync_assistance(cx);
        let context = CatalogContext::capture(&mut self.profiles[index], client.clone()).unwrap();
        self.catalog.search.entries.remove(&context.profile);
        self.profiles[index].status = "Loading schemas...".into();
        self.profiles[index].expanded = true;
        self.profiles[index].task = Some(cx.spawn_in(window, async move |view, cx| {
            let mut current = context.clone();
            let result = async {
                client.handshake().await?;
                // Credentials are read only for the explicit Connect command, never search/load/actions.
                let session = match &context.session {
                    Some(s) => s.clone(),
                    None => connect_saved(&client, settings).await?.session_id,
                };
                let attached = view
                    .update_in(cx, |this, _, cx| {
                        let index = this.catalog_valid(&context)?;
                        let profile = &mut this.profiles[index];
                        if context.session.is_none() {
                            profile.service_generation += 1;
                        }
                        profile.session = Some(session.clone());
                        profile.session_client = Some(client.clone());
                        profile.session_settings = Some(context.settings.clone());
                        profile.loaded = true;
                        let mut attached = context.clone();
                        attached.service_generation = profile.service_generation;
                        attached.session = Some(session.clone());
                        cx.notify();
                        Some(attached)
                    })
                    .ok()
                    .flatten();
                let Some(attached) = attached else {
                    if context.session.is_none() {
                        let _ = client.disconnect(&session).await;
                    }
                    return Ok(None);
                };
                current = attached;
                let stream = view
                    .update_in(cx, |this, _, _| {
                        this.catalog_valid(&current).map(|_| {
                            client.catalog(
                                &session,
                                CatalogRequest {
                                    kind: "schemas".into(),
                                    ..Default::default()
                                },
                            )
                        })
                    })
                    .ok()
                    .flatten();
                match stream {
                    Some(stream) => collect(stream?).await.map(Some),
                    None => Ok(None),
                }
            }
            .await;
            _ = view.update_in(cx, |this, window, cx| {
                if let Some(index) = this.catalog_valid(&current) {
                    this.profiles[index].task = None;
                    match result {
                        Ok(Some(outcome)) => {
                            this.profiles[index].schemas = outcome
                                .result_sets
                                .first()
                                .map(|set| {
                                    set.rows
                                        .iter()
                                        .filter_map(|row| {
                                            value(set, row, "name")
                                                .map(|n| CatalogSchema::schema(n.into()))
                                        })
                                        .collect()
                                })
                                .unwrap_or_default();
                            this.profiles[index].status =
                                format!("{} schemas", this.profiles[index].schemas.len()).into();
                            this.catalog.selected = None;
                        }
                        Ok(None) => {}
                        Err(error) => this.catalog_failure(&current, None, &error),
                    }
                } else {
                    this.retire_catalog_task(&current);
                }
                this.pump_catalog_search(window, cx);
                cx.notify();
            });
        }));
        cx.notify();
    }
    fn retire_catalog_task(&mut self, context: &CatalogContext) {
        // Old-helper errors may clear only their original still-owned service; SQL terminals are untouched.
        if let Some(index) = self.catalog_owner(context) {
            self.profiles[index].task = None;
            if context.matches(&self.profiles[index]) && !context.client.is_alive() {
                if context.client.owned_process_exited() {
                    self.profiles[index].session = None;
                    self.profiles[index].session_settings = None;
                    self.profiles[index].session_client = None;
                }
                self.profiles[index].loaded = false;
                self.profiles[index].schemas.clear();
                self.profiles[index].status =
                    "Helper disconnected. Connect explicitly to retry.".into();
                self.catalog.search.entries.remove(&context.profile);
            }
            for tab in &mut self.tabs {
                let same_profile = tab.profile == context.profile;
                if let Some(doc) = &mut tab.catalog_document
                    && same_profile
                    && doc.target.client.same_instance(&context.client)
                    && doc.loading
                {
                    doc.loading = false;
                    tab.error = true;
                    tab.status =
                        "Catalog connection changed. Connect explicitly and Refresh to retry."
                            .into();
                }
            }
        }
    }
    fn catalog_failure(
        &mut self,
        context: &CatalogContext,
        work: Option<&Work>,
        error: &backend::BackendError,
    ) {
        let Some(index) = self.catalog_valid(context) else {
            self.retire_catalog_task(context);
            return;
        };
        self.profiles[index].status = error.message.clone().into();
        if let Some(Work::Completion { revision }) = work
            && self.completion_work_current(context, *revision)
        {
            self.catalog
                .completion
                .entries
                .get_mut(&context.profile)
                .unwrap()
                .status = "SQL assistance metadata refresh failed; previous metadata retained";
        }
        match work {
            Some(Work::Table {
                document, request, ..
            }) => {
                if let Some(tab) = self.tabs.iter_mut().find(|t| t.id == *document)
                    && let Some(doc) = &mut tab.catalog_document
                    && let Some(table) = &mut doc.table
                {
                    table.fail(request);
                    doc.loading = false;
                    tab.error = true;
                    tab.status = error.message.clone().into();
                }
            }
            Some(Work::Node {
                id,
                search_revision,
            }) => {
                if let Some(node) =
                    self.find_catalog_node_mut(&context.profile, id, *search_revision)
                {
                    node.loading = false;
                    node.error = Some(error.message.clone());
                }
            }
            Some(Work::Search { revision, .. }) if *revision == self.catalog.search.revision => {
                self.catalog.search.entries.insert(
                    context.profile.clone(),
                    SearchEntry {
                        revision: *revision,
                        nodes: Vec::new(),
                        loading: false,
                        error: Some(error.message.clone()),
                        truncated: false,
                    },
                );
            }
            Some(Work::Action {
                document: Some(id), ..
            }) => {
                if let Some(tab) = self.tabs.iter_mut().find(|t| t.id == *id) {
                    if let Some(doc) = &mut tab.catalog_document {
                        doc.loading = false;
                        if matches!(
                            work,
                            Some(Work::Action {
                                command: CommandId::CatalogInspect | CommandId::CatalogDefinition,
                                ..
                            })
                        ) && let Some(structure) = error.result_sets.first()
                        {
                            doc.structure = Some(structure.clone());
                            doc.columns = structure.table_metadata().unwrap_or_default();
                        }
                    }
                    tab.error = true;
                    tab.status = error.message.clone().into();
                }
            }
            _ => {}
        }
        if !error.connected {
            if context.client.owned_process_exited() {
                self.profiles[index].session = None;
                self.profiles[index].session_settings = None;
                self.profiles[index].session_client = None;
            }
            self.profiles[index].loaded = false;
            self.profiles[index].schemas.clear();
            self.catalog.search.entries.remove(&context.profile);
        }
    }
    #[cfg(feature = "native-smoke")]
    pub fn expand_schema(
        &mut self,
        index: usize,
        schema_index: usize,
        window: &mut Window,
        cx: &mut Context<Self>,
    ) {
        let Some(node) = self.profiles[index].schemas.get(schema_index) else {
            return;
        };
        if let Some(target) = self.catalog_target(index, node.id.clone()) {
            self.catalog_command(
                CommandId::CatalogExpand,
                CommandOrigin::Button,
                target,
                window,
                cx,
            );
        }
    }
    /// Compatibility entry for the existing smoke harness; uses the same captured command boundary.
    #[cfg(feature = "native-smoke")]
    pub fn open_object(
        &mut self,
        index: usize,
        schema: String,
        object: CatalogObject,
        window: &mut Window,
        cx: &mut Context<Self>,
    ) {
        if let Some(target) = self.catalog_target(index, NodeId::Object { schema, object }) {
            self.catalog_command(
                CommandId::CatalogGenerateSelect,
                CommandOrigin::Button,
                target,
                window,
                cx,
            );
        }
    }
    pub(super) fn dispatch_catalog(
        &mut self,
        command: CommandId,
        target: CatalogTarget,
        window: &mut Window,
        cx: &mut Context<Self>,
    ) {
        if self.catalog_action_available(command, &target).is_err() || self.closing {
            return;
        }
        self.catalog.selected = Some(target.clone());
        if command == CommandId::CatalogRetrySearch {
            self.retry_catalog_search(target.profile, window, cx);
            return;
        }
        let index = self.profile_index(&target.profile).unwrap();
        if command == CommandId::CatalogRefresh {
            self.invalidate_completion(&target.profile, true);
            self.sync_assistance(cx);
        }
        if matches!(
            command,
            CommandId::CatalogExpand | CommandId::CatalogRefresh
        ) {
            let Some(node) =
                self.find_catalog_node_mut(&target.profile, &target.node, target.search_revision)
            else {
                return;
            };
            if command == CommandId::CatalogExpand {
                node.expanded = !node.expanded;
                if !node.expanded {
                    cx.notify();
                    return;
                }
            } else {
                node.expanded = true;
            }
            if node.loaded && command == CommandId::CatalogExpand {
                cx.notify();
                return;
            }
            if let Some(children) = node.local_children() {
                node.children = children;
                node.loaded = true;
                node.error = None;
                self.pump_catalog_search(window, cx);
                cx.notify();
                return;
            }
            node.loading = true;
            node.error = None;
            self.start_catalog_work(
                index,
                Work::Node {
                    id: target.node,
                    search_revision: target.search_revision,
                },
                window,
                cx,
            );
            return;
        }
        let document = if matches!(
            command,
            CommandId::CatalogInspect | CommandId::CatalogDefinition | CommandId::CatalogOpenData
        ) {
            self.new_catalog_document(
                target.clone(),
                command == CommandId::CatalogOpenData,
                window,
                cx,
            )
        } else {
            None
        };
        if command == CommandId::CatalogOpenData {
            if let Some(id) = document {
                let table = self
                    .tabs
                    .iter_mut()
                    .find(|t| t.id == id)
                    .unwrap()
                    .catalog_document
                    .as_mut()
                    .unwrap()
                    .table
                    .as_mut()
                    .unwrap();
                let request = table.begin(tables::Navigation::default()).unwrap();
                self.start_table_work(target, id, request, window, cx);
            }
        } else {
            self.start_catalog_work(
                index,
                Work::Action {
                    command,
                    target: Box::new(target),
                    document,
                },
                window,
                cx,
            );
        }
    }
    fn find_catalog_node_mut(
        &mut self,
        profile: &ProfileId,
        id: &NodeId,
        search_revision: Option<u64>,
    ) -> Option<&mut CatalogSchema> {
        if let Some(revision) = search_revision {
            if self.catalog.search.revision != revision {
                return None;
            }
            return CatalogSchema::find_mut(
                &mut self.catalog.search.entries.get_mut(profile)?.nodes,
                id,
            );
        }
        let index = self.profile_index(profile)?;
        CatalogSchema::find_mut(&mut self.profiles[index].schemas, id)
    }
    fn start_catalog_work(
        &mut self,
        index: usize,
        work: Work,
        window: &mut Window,
        cx: &mut Context<Self>,
    ) {
        if self.closing || self.profiles[index].task.is_some() {
            return;
        }
        let Some(client) = self.profiles[index].session_client.clone().filter(|c| {
            c.is_alive()
                && self
                    .backend
                    .as_ref()
                    .is_some_and(|current| current.same_instance(c))
        }) else {
            return;
        };
        if !self.catalog_settings_match(index, cx) || self.profiles[index].session.is_none() {
            return;
        }
        let context = CatalogContext::capture(&mut self.profiles[index], client.clone()).unwrap();
        let session = context.session.clone().unwrap();
        // Retarget selection only to this same service/object, never to another selected node.
        if let Some(selected) = &mut self.catalog.selected
            && selected.profile == context.profile
        {
            selected.generation = context.generation;
        }
        self.profiles[index].task = Some(cx.spawn_in(window, async move |view, cx| {
            let result = async {
                if let Work::Completion { revision } = &work {
                    let owner = metadata_owner(&context, *revision);
                    let mut pager = language_service::metadata::CatalogPager::new(owner.clone());
                    while let Some(request) = pager.next_request() {
                        let page = request.page;
                        let stream = view
                            .update_in(cx, |this, _, _| {
                                this.completion_work_current(&context, *revision)
                                    .then(|| client.catalog(&session, request))
                            })
                            .ok()
                            .flatten();
                        let Some(stream) = stream else {
                            return Ok(None);
                        };
                        let outcome = collect(stream?).await;
                        let valid = view
                            .update_in(cx, |this, _, _| {
                                this.completion_work_current(&context, *revision)
                            })
                            .unwrap_or(false);
                        if !valid {
                            return Ok(None);
                        }
                        let outcome = outcome?;
                        if outcome.truncated {
                            return Err(metadata_error());
                        }
                        pager
                            .accept_page(&owner, page, &outcome.result_sets)
                            .map_err(|_| metadata_error())?;
                    }
                    let snapshot = pager.finish(&owner).map_err(|_| metadata_error())?;
                    return Ok(Some(WorkOutput {
                        completion: Some(snapshot),
                        sets: Vec::new(),
                        truncated: false,
                        notice: String::new(),
                    }));
                }
                let mut sets = Vec::new();
                let mut truncated = false;
                let mut notice = String::new();
                for request in work.requests() {
                    let stream = view
                        .update_in(cx, |this, _, _| {
                            this.catalog_valid(&context)?;
                            if this.closing {
                                return None;
                            }
                            if let Work::Search { revision, query } = &work
                                && (this.catalog.search.revision != *revision
                                    || this.catalog.search.query != *query)
                            {
                                return None;
                            }
                            if !this.table_work_valid(&work) {
                                return None;
                            }
                            if let Work::Action {
                                document: Some(id), ..
                            } = &work
                                && !this
                                    .tabs
                                    .iter()
                                    .any(|t| t.id == *id && t.profile == context.profile)
                            {
                                return None;
                            }
                            Some(client.catalog(&session, request))
                        })
                        .ok()
                        .flatten();
                    let Some(stream) = stream else {
                        return Ok(None);
                    };
                    let outcome = match collect(stream?).await {
                        Ok(outcome) => outcome,
                        Err(mut error) => {
                            // Inspection can retain readable columns after definition permission failure.
                            // A table refresh keeps its previous complete snapshot on every failure.
                            if matches!(
                                &work,
                                Work::Action {
                                    command: CommandId::CatalogInspect
                                        | CommandId::CatalogDefinition,
                                    ..
                                }
                            ) && !sets.is_empty()
                            {
                                error.result_sets = sets;
                            }
                            return Err(error);
                        }
                    };
                    truncated |= outcome.truncated;
                    if !outcome.display_notice.is_empty() {
                        notice = outcome.display_notice;
                    }
                    sets.extend(outcome.result_sets);
                }
                Ok::<_, backend::BackendError>(Some(WorkOutput {
                    completion: None,
                    sets,
                    truncated,
                    notice,
                }))
            }
            .await;
            _ = view.update_in(cx, |this, window, cx| {
                this.finish_catalog_work(&context, &work, result, window, cx);
            });
        }));
        cx.notify();
    }
    fn finish_catalog_work(
        &mut self,
        context: &CatalogContext,
        work: &Work,
        result: Result<Option<WorkOutput>, backend::BackendError>,
        window: &mut Window,
        cx: &mut Context<Self>,
    ) {
        if let Some(index) = self.catalog_valid(context) {
            self.profiles[index].task = None;
            // Errors and success payloads obey identical generation/search ownership checks.
            let current = !matches!(work, Work::Search { revision, query } if *revision != self.catalog.search.revision || *query != self.catalog.search.query)
                && !matches!(work, Work::Node { search_revision: Some(revision), .. } if *revision != self.catalog.search.revision);
            let current = current
                && !matches!(work,Work::Completion {revision} if !self.completion_work_current(context,*revision));
            if current && self.table_work_valid(work) {
                match result {
                    Ok(Some(output)) => {
                        self.complete_catalog_work(context, work, output, window, cx)
                    }
                    Ok(None) => {}
                    Err(error) => self.catalog_failure(context, Some(work), &error),
                }
            } else {
                self.retire_table_work(work);
            }
        } else {
            self.retire_catalog_task(context);
            self.retire_table_work(work);
        }
        self.pump_catalog_search(window, cx);
        cx.notify();
    }
    fn complete_catalog_work(
        &mut self,
        context: &CatalogContext,
        work: &Work,
        output: WorkOutput,
        window: &mut Window,
        cx: &mut Context<Self>,
    ) {
        if matches!(
            work,
            Work::Action {
                command: CommandId::CatalogGenerateSelect | CommandId::CatalogCopyName,
                ..
            }
        ) && (self.closing
            || (self.file_request.is_some()
                || (self.export_request.is_some() || self.run_file.is_some()))
            || window.has_active_dialog(cx)
            || window.has_active_prompt())
        {
            if let Some(index) = self.catalog_owner(context) {
                self.profiles[index].status =
                    "Finish the active workflow and retry the captured catalog action.".into();
            }
            return;
        }
        match work {
            Work::Completion { revision } => {
                if self.completion_work_current(context, *revision)
                    && let Some(snapshot) = output.completion
                {
                    let entry = self
                        .catalog
                        .completion
                        .entries
                        .get_mut(&context.profile)
                        .unwrap();
                    entry.status = if snapshot.truncated {
                        "SQL assistance metadata loaded with resource limits"
                    } else {
                        "SQL assistance metadata loaded"
                    };
                    entry.snapshot = snapshot;
                    entry.owner = Some(context.clone());
                    // Replacement has a fresh revision even with identical rows.
                    self.catalog.completion.revision += 1;
                    entry.revision = self.catalog.completion.revision;
                    self.sync_assistance(cx);
                }
            }
            Work::Table {
                target,
                document,
                request,
            } => {
                self.complete_table_work(context, target, *document, request, output, window, cx);
            }
            Work::Node {
                id,
                search_revision,
            } => {
                if let Some(node) =
                    self.find_catalog_node_mut(&context.profile, id, *search_revision)
                {
                    node.children = output
                        .sets
                        .first()
                        .map(|s| {
                            if matches!(id, NodeId::Group { .. }) {
                                object_nodes(s)
                            } else {
                                detail_nodes(id, s)
                            }
                        })
                        .unwrap_or_default();
                    node.truncated = output.truncated;
                    node.data = output.sets.into_iter().next();
                    node.loaded = true;
                    node.loading = false;
                    node.error = None;
                }
            }
            Work::Search { revision, .. } => {
                self.catalog.search.entries.insert(
                    context.profile.clone(),
                    SearchEntry {
                        revision: *revision,
                        nodes: output.sets.first().map(object_nodes).unwrap_or_default(),
                        loading: false,
                        error: None,
                        truncated: output.truncated,
                    },
                );
            }
            Work::Action {
                command,
                target,
                document,
            } => {
                match command {
                    CommandId::CatalogGenerateSelect => {
                        if let Some(sql) = first_value(&output.sets, "sql") {
                            // Adapter-generated source opens disconnected and is never assessed/executed here.
                            self.add_sql_tab_for_profile(
                                format!("{}.sql", target.node.object().unwrap().1.name),
                                sql.into(),
                                context.profile.clone(),
                                window,
                                cx,
                            );
                        } else {
                            self.profiles.iter_mut().find(|p| p.id == context.profile).unwrap().status = "The object is unavailable. Refresh the catalog and select it again.".into();
                        }
                    }
                    CommandId::CatalogCopyName => {
                        if let Some(name) = first_value(&output.sets, "name") {
                            cx.write_to_clipboard(ClipboardItem::new_string(name.to_owned()));
                        } else {
                            self.profiles.iter_mut().find(|p| p.id == context.profile).unwrap().status = "The object is unavailable. Refresh the catalog and select it again.".into();
                        }
                    }
                    CommandId::CatalogInspect | CommandId::CatalogDefinition => {
                        let Some(id) = document else {
                            return;
                        };
                        let Some(tab) = self
                            .tabs
                            .iter_mut()
                            .find(|t| t.id == *id && t.profile == context.profile)
                        else {
                            return;
                        };
                        let Some(doc) = tab.catalog_document.as_mut() else {
                            return;
                        };
                        if doc.target.node != target.node {
                            return;
                        }
                        let relation = target.node.object().is_some_and(|(_, o)| o.relation());
                        doc.target.generation = context.generation;
                        doc.loading = false;
                        if relation {
                            doc.structure = output.sets.first().cloned();
                            doc.columns = doc
                                .structure
                                .as_ref()
                                .and_then(|s| s.table_metadata().ok())
                                .unwrap_or_default();
                        }
                        doc.definition = Some(
                            first_value(&output.sets[usize::from(relation)..], "definition")
                                .unwrap_or("Definition is unavailable.")
                                .to_owned(),
                        );
                        let definition = doc
                            .definition
                            .clone()
                            .unwrap_or_else(|| "Definition is unavailable.".into());
                        tab.editor
                            .update(cx, |state, cx| state.set_value(definition, window, cx));
                        tab.status = "Structure and definition loaded.".into();
                        if let Some(tab) = self.tabs.iter_mut().find(|t| t.id == *id) {
                            tab.error = false;
                        }
                    }
                    _ => {}
                }
            }
        }
    }
    pub(super) fn schedule_catalog_search(&mut self, window: &mut Window, cx: &mut Context<Self>) {
        self.catalog.search.revision += 1;
        self.catalog.search.query = self.search.read(cx).value().trim().to_owned();
        self.catalog.search.entries.clear();
        self.catalog.search.ready = false;
        self.catalog.search.debounce = None;
        if self.catalog.search.query.is_empty() {
            return;
        }
        // One replaceable timer and one current query; never queue an RPC for each keystroke.
        let revision = self.catalog.search.revision;
        self.catalog.search.debounce = Some(cx.spawn_in(window, async move |view, cx| {
            cx.background_executor()
                .timer(Duration::from_millis(250))
                .await;
            _ = view.update_in(cx, |this, window, cx| {
                if this.catalog.search.revision == revision {
                    this.catalog.search.ready = true;
                    this.catalog.search.debounce = None;
                    this.pump_catalog_search(window, cx);
                    cx.notify();
                }
            });
        }));
    }
    fn pump_catalog_search(&mut self, window: &mut Window, cx: &mut Context<Self>) {
        if self.pump_completion(window, cx) {
            return;
        }
        self.sync_assistance(cx);
        if self.closing
            || (self.file_request.is_some()
                || (self.export_request.is_some() || self.run_file.is_some()))
            || !self.catalog.search.ready
            || self.catalog.search.query.is_empty()
        {
            return;
        }
        if self.catalog.search.query.len() > 1024 || self.catalog.search.query.contains('\0') {
            return;
        }
        let revision = self.catalog.search.revision;
        let query = self.catalog.search.query.clone();
        // Start at most one service RPC globally. Busy profile work drains before the latest search.
        if self.profiles.iter().any(|p| p.task.is_some()) {
            return;
        }
        for index in 0..self.profiles.len() {
            let p = &self.profiles[index];
            if p.config.is_none()
                || p.session.is_none()
                || p.config != p.session_settings
                || !self.backend.as_ref().is_some_and(|c| c.is_alive())
            {
                continue;
            }
            if self
                .catalog
                .search
                .entries
                .get(&p.id)
                .is_some_and(|e| e.revision == revision)
            {
                continue;
            }
            self.catalog.search.entries.insert(
                p.id.clone(),
                SearchEntry {
                    revision,
                    nodes: Vec::new(),
                    loading: true,
                    error: None,
                    truncated: false,
                },
            );
            self.start_catalog_work(index, Work::Search { revision, query }, window, cx);
            break;
        }
    }
    pub(super) fn retry_catalog_search(
        &mut self,
        profile: ProfileId,
        window: &mut Window,
        cx: &mut Context<Self>,
    ) {
        if self.closing
            || window.has_active_dialog(cx)
            || (self.file_request.is_some()
                || (self.export_request.is_some() || self.run_file.is_some()))
        {
            return;
        }
        self.catalog.search.entries.remove(&profile);
        self.pump_catalog_search(window, cx);
        cx.notify();
    }
    pub(super) fn new_catalog_document(
        &mut self,
        target: CatalogTarget,
        table: bool,
        window: &mut Window,
        cx: &mut Context<Self>,
    ) -> Option<DocumentId> {
        let (schema, object) = target.node.object()?;
        let (schema, object) = (schema.to_owned(), object.clone());
        let kind = if table {
            model::DocumentKind::Table {
                schema,
                object: object.name.clone(),
                object_kind: object.kind,
            }
        } else {
            model::DocumentKind::Inspection {
                schema,
                object: object.name.clone(),
                object_kind: object.kind,
                identity: object.identity,
            }
        };
        let id = self.add_document_for_profile(
            object.name,
            String::new(),
            target.profile.clone(),
            kind,
            window,
            cx,
        )?;
        let tab = self.tabs.iter_mut().find(|t| t.id == id)?;
        tab.catalog_document = Some(CatalogDocument {
            target,
            columns: Vec::new(),
            structure: None,
            definition: None,
            loading: true,
            table: table.then(|| tables::TableDocument::new(window, cx)),
        });
        if let Some(table) = tab
            .catalog_document
            .as_ref()
            .and_then(|doc| doc.table.as_ref())
        {
            let subscription = cx.subscribe_in(
                &table.filter_value,
                window,
                move |this, _, event, window, cx| {
                    if matches!(
                        event,
                        InputEvent::PressEnter {
                            secondary: false,
                            shift: false
                        }
                    ) {
                        this.table_command(id, tables::Action::AddFilter, window, cx);
                    }
                },
            );
            tab._subscriptions.push(subscription);
        }
        tab.status = if table {
            "Loading table metadata and rows..."
        } else {
            "Loading structure and definition..."
        }
        .into();
        self.schedule_documents(cx);
        Some(id)
    }
    pub(super) fn refresh_catalog_document(
        &mut self,
        id: DocumentId,
        window: &mut Window,
        cx: &mut Context<Self>,
    ) {
        if self.closing
            || window.has_active_dialog(cx)
            || (self.file_request.is_some()
                || (self.export_request.is_some() || self.run_file.is_some()))
        {
            return;
        }
        let Some(tab) = self.tabs.iter().find(|t| t.id == id) else {
            return;
        };
        let Some(doc) = &tab.catalog_document else {
            return;
        };
        let node = doc.target.node.clone();
        let profile = doc.target.profile.clone();
        let table = matches!(tab.kind, model::DocumentKind::Table { .. });
        let Some(index) = self.profile_index(&profile) else {
            return;
        };
        let Some(target) = self.catalog_target(index, node) else {
            return;
        };
        if table {
            self.table_command(id, tables::Action::Refresh, window, cx);
            return;
        }
        let command = if table {
            CommandId::CatalogOpenData
        } else {
            CommandId::CatalogInspect
        };
        if self.catalog_action_available(command, &target).is_err() {
            return;
        }
        self.tabs
            .iter_mut()
            .find(|t| t.id == id)
            .unwrap()
            .catalog_document
            .as_mut()
            .unwrap()
            .loading = true;
        self.start_catalog_work(
            index,
            Work::Action {
                command,
                target: Box::new(target),
                document: Some(id),
            },
            window,
            cx,
        );
    }
    pub fn live_catalog(
        &self,
        index: usize,
        query: &str,
        cx: &mut Context<Self>,
    ) -> impl IntoElement {
        let profile = &self.profiles[index];
        let id = profile.id.clone();
        let retry = self.catalog_target(index, NodeId::Schema(String::new()));
        let mut view = div()
            .flex()
            .flex_col()
            .gap_1()
            .ml_3()
            .mb_3()
            .child(
                div()
                    .text_xs()
                    .text_color(cx.theme().muted_foreground)
                    .child(profile.status.clone()),
            )
            .children(self.completion_status(&profile.id).map(|status| {
                div()
                    .text_xs()
                    .text_color(cx.theme().muted_foreground)
                    .child(status)
            }))
            .child(
                div().flex().gap_1().child(
                    Button::new(("connect-catalog", index))
                        .ghost()
                        .xsmall()
                        .label(if profile.session.is_some() {
                            "Refresh"
                        } else {
                            "Connect"
                        })
                        .disabled(profile.task.is_some() || self.closing)
                        .on_click(cx.listener(move |this, _, window, cx| {
                            this.command(
                                CommandId::Connect,
                                CommandOrigin::Button,
                                Some(id.clone()),
                                window,
                                cx,
                            )
                        })),
                ),
            );
        if !query.is_empty() {
            if profile.session.is_none() {
                return view.child(
                    div()
                        .text_xs()
                        .child("Connect explicitly to search this profile."),
                );
            }
            if self.catalog.search.query.len() > 1024 || self.catalog.search.query.contains('\0') {
                return view.child("Search must contain at most 1,024 bytes and no NUL.");
            }
            match self.catalog.search.entries.get(&profile.id) {
                Some(entry) => {
                    if entry.loading {
                        view = view.child("Searching...");
                    }
                    if let Some(error) = &entry.error {
                        view = view.child(div().text_xs().child(error.clone())).child(
                            Button::new(("search-retry", index))
                                .ghost()
                                .xsmall()
                                .label("Retry Search")
                                .disabled(self.closing || profile.task.is_some())
                                .on_click(cx.listener(move |this, _, window, cx| {
                                    if let Some(target) = retry.clone() {
                                        this.catalog_command(
                                            CommandId::CatalogRetrySearch,
                                            CommandOrigin::Button,
                                            target,
                                            window,
                                            cx,
                                        );
                                    }
                                })),
                        );
                    }
                    if !entry.loading && entry.error.is_none() && entry.nodes.is_empty() {
                        view = view.child("No matching objects");
                    }
                    if entry.truncated {
                        view = view.child("Search display limit reached. Refine the search.");
                    }
                    for node in &entry.nodes {
                        view = view.child(self.catalog_node(
                            index,
                            node,
                            0,
                            true,
                            Some(self.catalog.search.revision),
                            cx,
                        ));
                    }
                }
                None => {
                    view = view.child("Search pending...");
                }
            }
        } else {
            for node in &profile.schemas {
                view = view.child(self.catalog_node(index, node, 0, false, None, cx));
            }
        }
        view
    }
    fn catalog_node(
        &self,
        index: usize,
        node: &CatalogSchema,
        depth: usize,
        context: bool,
        search_revision: Option<u64>,
        cx: &mut Context<Self>,
    ) -> AnyElement {
        let target = self.catalog_target(index, node.id.clone()).map(|mut t| {
            t.search_revision = search_revision;
            t
        });
        let click = target.clone();
        let double = target.clone();
        let menu_target = target.clone();
        let button_target = target.clone();
        let view = cx.entity().downgrade();
        let button_view = view.clone();
        let expandable = node.id.expandable();
        let object = node.id.object().is_some();
        use std::hash::{Hash, Hasher};
        let mut hash = std::collections::hash_map::DefaultHasher::new();
        node.id.hash(&mut hash);
        let key = hash.finish();
        let identity = if matches!(&node.id, NodeId::Object { object, .. } if !object.relation()) {
            node.id
                .object()
                .and_then(|(_, o)| o.identity.as_ref())
                .map(|id| format!("{} [identity {}]", node.name, id))
        } else {
            None
        };
        let label = if node.loaded && expandable {
            format!(
                "{} ({}{})",
                node.name,
                node.children.len(),
                if node.truncated { "+" } else { "" }
            )
        } else {
            identity.unwrap_or_else(|| node.name.clone())
        };
        let name = if context {
            node.id
                .object()
                .map(|(schema, _)| {
                    format!("{} / {} / {}", self.profiles[index].name, schema, label)
                })
                .unwrap_or(label)
        } else {
            label
        };
        let mut tree = div().flex().flex_col().ml(px((depth * 10) as f32)).child(
            div()
                .id(SharedString::from(format!(
                    "catalog-node-{index}-{depth}-{key}",
                )))
                .flex()
                .items_center()
                .child(
                    Button::new(SharedString::from(format!(
                        "catalog-expand-{index}-{depth}-{key}",
                    )))
                    .ghost()
                    .xsmall()
                    .icon(if node.expanded {
                        IconName::ChevronDown
                    } else {
                        IconName::ChevronRight
                    })
                    .disabled(
                        !expandable
                            || target.is_none()
                            || self.closing
                            || self.profiles[index].task.is_some(),
                    )
                    .on_click(cx.listener(move |this, _, window, cx| {
                        if let Some(target) = click.clone() {
                            this.catalog_command(
                                CommandId::CatalogExpand,
                                CommandOrigin::Button,
                                target,
                                window,
                                cx,
                            );
                        }
                    })),
                )
                .child(div().flex_1().text_sm().child(name).on_mouse_down(
                    MouseButton::Left,
                    cx.listener(move |this, event: &MouseDownEvent, window, cx| {
                        if this.closing
                            || window.has_active_dialog(cx)
                            || (this.file_request.is_some() || this.export_request.is_some())
                        {
                            return;
                        }
                        if let Some(target) = double.clone() {
                            this.catalog.selected = Some(target.clone());
                            if event.click_count == 2 && object {
                                let command =
                                    if target.node.object().is_some_and(|(_, o)| o.relation()) {
                                        CommandId::CatalogOpenData
                                    } else {
                                        CommandId::CatalogInspect
                                    };
                                this.catalog_command(
                                    command,
                                    CommandOrigin::Button,
                                    target,
                                    window,
                                    cx,
                                );
                            }
                            cx.notify();
                        }
                    }),
                ))
                .child(
                    Button::new(SharedString::from(format!(
                        "catalog-actions-{index}-{depth}-{key}",
                    )))
                    .ghost()
                    .xsmall()
                    .icon(IconName::Ellipsis)
                    .disabled(target.is_none() || self.closing)
                    .dropdown_menu(move |menu, window, cx| {
                        Self::catalog_menu(
                            menu,
                            button_view.clone(),
                            button_target.clone(),
                            window,
                            cx,
                        )
                    }),
                )
                .context_menu(move |menu, window, cx| {
                    Self::catalog_menu(menu, view.clone(), menu_target.clone(), window, cx)
                }),
        );
        if node.truncated {
            tree = tree.child(div().text_xs().child("Catalog display limit reached."));
        }
        if node.loading {
            tree = tree.child(div().text_xs().child("Loading..."));
        }
        if let Some(error) = &node.error {
            let retry = target;
            tree = tree.child(div().text_xs().child(error.clone())).child(
                Button::new(SharedString::from(format!(
                    "catalog-retry-{index}-{depth}-{key}",
                )))
                .ghost()
                .xsmall()
                .label("Retry")
                .disabled(self.closing || self.profiles[index].task.is_some())
                .on_click(cx.listener(move |this, _, window, cx| {
                    if let Some(target) = retry.clone() {
                        this.catalog_command(
                            CommandId::CatalogRefresh,
                            CommandOrigin::Button,
                            target,
                            window,
                            cx,
                        );
                    }
                })),
            );
        }
        if node.expanded {
            if node.loaded && node.children.is_empty() {
                tree = tree.child(div().text_xs().child("No objects"));
            }
            for child in &node.children {
                tree = tree.child(self.catalog_node(
                    index,
                    child,
                    depth + 1,
                    false,
                    search_revision,
                    cx,
                ));
            }
        }
        tree.into_any_element()
    }
    fn catalog_menu(
        mut menu: PopupMenu,
        view: WeakEntity<Self>,
        target: Option<CatalogTarget>,
        window: &mut Window,
        cx: &mut App,
    ) -> PopupMenu {
        let Some(entity) = view.upgrade() else {
            return menu;
        };
        for command in [
            CommandId::CatalogInspect,
            CommandId::CatalogDefinition,
            CommandId::CatalogOpenData,
            CommandId::CatalogGenerateSelect,
            CommandId::CatalogCopyName,
            CommandId::CatalogRefresh,
        ] {
            let capture = entity
                .update(cx, |this, cx| {
                    target.clone().ok_or("No catalog target.").and_then(|t| {
                        this.capture_catalog_command(command, CommandOrigin::Menu, t, window, cx)
                    })
                })
                .ok();
            let view = view.clone();
            menu = menu.item(
                PopupMenuItem::new(command.title())
                    .disabled(capture.is_none())
                    .on_click(move |_, window, cx| {
                        if let Some(capture) = capture.clone() {
                            _ = view
                                .update(cx, |this, cx| this.dispatch_command(capture, window, cx));
                        }
                    }),
            );
        }
        menu
    }
    pub(super) fn catalog_document_pane(
        &self,
        window: &mut Window,
        cx: &mut Context<Self>,
    ) -> AnyElement {
        let tab = &self.tabs[self.active];
        let id = tab.id;
        let doc = tab.catalog_document.as_ref().unwrap();
        let profile = self.profile(&tab.profile);
        let (schema, object) = doc.target.node.object().unwrap();
        let header = div()
            .flex()
            .items_center()
            .gap_3()
            .p_3()
            .border_b_1()
            .border_color(cx.theme().border)
            .child(format!(
                "{} / {} / {} ({})",
                profile.name, schema, object.name, object.kind
            ))
            .children(
                object
                    .identity
                    .as_ref()
                    .map(|identity| div().text_xs().child(format!("Identity: {identity}"))),
            )
            .child(
                Button::new("catalog-document-refresh")
                    .small()
                    .label(if tab.error { "Retry" } else { "Refresh" })
                    .disabled(
                        !self.command_enabled(CommandId::CatalogRefreshDocument, window, cx)
                            || profile.session.is_none(),
                    )
                    .on_click(cx.listener(move |this, _, window, cx| {
                        this.command_for_document(CommandId::CatalogRefreshDocument, id, window, cx)
                    })),
            );
        let mut pane = div()
            .size_full()
            .flex()
            .flex_col()
            .child(header)
            .child(div().px_3().text_xs().child(tab.status.clone()));
        if doc.loading {
            pane = pane.child(div().px_3().child("Loading..."));
        }
        if matches!(tab.kind, model::DocumentKind::Table { .. }) {
            return pane
                .child(self.table_controls(id, window, cx))
                .child(
                    div()
                        .flex_1()
                        .min_h_0()
                        .child(self.results_pane(window, cx)),
                )
                .into_any_element();
        }
        if let Some(structure) = &doc.structure {
            let mut columns = div()
                .flex()
                .flex_col()
                .gap_1()
                .child(format!("Columns ({})", structure.rows.len()));
            // Inspect every ordinal field; NULL is visibly distinct from empty text and literal NULL.
            for (ordinal, row) in structure.rows.iter().enumerate() {
                let metadata = structure
                    .columns
                    .iter()
                    .zip(row)
                    .map(|(c, v)| {
                        format!(
                            "{} = {}",
                            c.name,
                            v.as_ref()
                                .map(|v| format!("{v:?}"))
                                .unwrap_or_else(|| "SQL NULL".into())
                        )
                    })
                    .collect::<Vec<_>>()
                    .join(" | ");
                columns = columns.child(div().text_xs().child(format!(
                    "{}: {}",
                    ordinal + 1,
                    metadata
                )));
            }
            pane = pane.child(
                div()
                    .id("catalog-structure")
                    .max_h(px(220.))
                    .overflow_y_scroll()
                    .p_3()
                    .child(columns),
            );
        }
        if doc.definition.is_some() {
            pane = pane.child(
                div()
                    .id("catalog-definition")
                    .flex_1()
                    .min_h_0()
                    .p_3()
                    .child(
                        controls::preview_editor(&tab.editor, cx)
                            .accessibility_guard(tab.accessibility_guard.clone())
                            .accessibility_id(format!("dbeer-object-definition-{}", tab.id.0))
                            .aria_label("Database object definition")
                            .readonly(true)
                            .h_full(),
                    ),
            );
        }
        pane.into_any_element()
    }
}

#[cfg(test)]
mod tests;
