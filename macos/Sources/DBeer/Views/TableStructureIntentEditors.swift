import Foundation
import SwiftUI

struct TableStructureIntentEditors: View {
    @ObservedObject var model: TableStructureEditorModel
    var allowCrossDatabase = false
    private var names: [String] { (model.baseline?.columns.map(\.name) ?? []).filter { name in !(model.draft.changes ?? []).contains { $0.drop && StructureTarget.sameIdentifier($0.name, name) } } + model.draft.columns.map(\.name).filter { !$0.isEmpty } }
    private var changes: [StructureColumnChange] { model.draft.changes ?? [] }
    private var indexes: [StructureIndexEdit] { model.draft.indexes ?? [] }
    private var keys: [StructureKeyEdit] { model.draft.keys ?? [] }
    private var canEdit: Bool { !model.isBusy && !model.closing && !model.invalidated && model.baseline != nil && model.outcome == nil }
    private var columnLimitReached: Bool { (model.baseline?.columns.count ?? 0) + model.draft.columns.count >= 128 }
    private var operationLimitReached: Bool { changes.count + indexes.count + keys.count >= 64 }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                if !model.create {
                    Button("Append Column") {
                        guard canEdit, (model.authoringAvailable || model.draft.columns.isEmpty), !columnLimitReached else { return }
                        model.draft.columns.append(TableStructureEditorModel.emptyColumn)
                    }.controlHover().disabled((!model.authoringAvailable && !model.draft.columns.isEmpty) || columnLimitReached)
                    if model.destructiveAvailable {
                        Button("Drop Column") {
                            guard canEdit, !operationLimitReached else { return }
                            model.draft.changes = changes + [.init(name: "", drop: true)]
                            model.draft.allowDestructive = nil
                        }.controlHover().disabled(operationLimitReached)
                    }
                    Button("Change Column") {
                        guard canEdit, !operationLimitReached else { return }
                        model.draft.changes = changes + [.init(name: "")]
                    }.controlHover().disabled(operationLimitReached || model.baseline?.columns.contains { model.authoringAvailable || $0.canModify == true } != true)
                }
                Button("Add Index Operation") {
                    guard canEdit, !operationLimitReached else { return }
                    model.draft.indexes = indexes + [.init(action: "add", name: "", columns: [])]
                }.controlHover().disabled(operationLimitReached)
                Button("Add Key Operation") {
                    guard canEdit, !operationLimitReached else { return }
                    model.draft.keys = keys + [.init(action: "add", kind: "unique", name: "", columns: [])]
                }.controlHover().disabled(operationLimitReached)
            }
            ForEach(changes.indices, id: \.self) { i in
                StructureColumnChangeEditor(change: changeBinding(i), columns: model.baseline?.columns ?? [],
                    engine: model.profile.engine, wideningAllowed: model.baseline?.dependencyProof == true, authoringAvailable: model.authoringAvailable, destructiveAvailable: model.conversionAvailable) {
                    guard canEdit, changes.indices.contains(i) else { return }
                    model.draft.changes?.remove(at: i)
                }
            }
            ForEach(indexes.indices, id: \.self) { i in
                StructureIndexIntentEditor(edit: indexBinding(i), existing: model.baseline?.indexes ?? [], names: names,
                    engine: model.profile.engine, advancedAvailable: model.indexAuthoringAvailable) {
                    guard canEdit, indexes.indices.contains(i) else { return }
                    model.draft.indexes?.remove(at: i)
                    model.draft.allowDestructive = nil
                }
            }
            ForEach(keys.indices, id: \.self) { i in
                StructureKeyIntentEditor(edit: keyBinding(i), existing: model.baseline?.keys ?? [], names: names,
                    engine: model.profile.engine, schema: model.schema, allowCrossDatabase: allowCrossDatabase) {
                    guard canEdit, keys.indices.contains(i) else { return }
                    model.draft.keys?.remove(at: i)
                    model.draft.allowDestructive = nil
                }
            }
            if model.draft.destructive {
                Toggle("Include destructive changes in Preview", isOn: Binding(get: { model.draft.allowDestructive == true }, set: {
                    guard canEdit else { return }
                    model.draft.allowDestructive = $0
                })).controlHover()
                Text("Removals, replacements, conversions, backfills and physical layout changes require confirmation of the exact generated SQL. Editing the selected operation clears this opt-in.")
                    .font(.caption).foregroundStyle(.orange)
            }
            if model.draft.requiresDestructiveAuthoring && !model.destructiveAvailable {
                Text("The destructive intent is retained. Reconnect with a helper advertising destructive structure authoring before Preview.").font(.caption).appSecondaryText()
            }
            if model.profile.engine != .sqlite && model.baseline?.dependencyProof != true {
                Text("Complete dependency visibility is unavailable. Type widening and referenced-key removal are blocked; Preview reports the reason.")
                    .font(.caption).appSecondaryText()
            }
        }.disabled(!canEdit)
    }

    private func changeBinding(_ i: Int) -> Binding<StructureColumnChange> {
        Binding(get: { changes.indices.contains(i) ? changes[i] : .init(name: "") }, set: {
            guard canEdit, changes.indices.contains(i) else { return }
            var updated = model.draft
            updated.changes?[i] = $0
            if model.conversionAvailable, $0.type != nil { updated.authoringVersion = 4 }
            updated.allowDestructive = nil
            model.draft = updated
        })
    }
    private func indexBinding(_ i: Int) -> Binding<StructureIndexEdit> {
        Binding(get: { indexes.indices.contains(i) ? indexes[i] : .init(action: "add", name: "") }, set: { value in
            guard canEdit, indexes.indices.contains(i) else { return }
            let requiresOptIn = indexes[i].action != "add" || value.action != "add"
            model.draft.indexes?[i] = value
            if requiresOptIn { model.draft.allowDestructive = nil }
        })
    }
    private func keyBinding(_ i: Int) -> Binding<StructureKeyEdit> {
        Binding(get: { keys.indices.contains(i) ? keys[i] : .init(action: "add", kind: "unique", name: "") }, set: { value in
            guard canEdit, keys.indices.contains(i) else { return }
            let requiresOptIn = keys[i].action != "add" || value.action != "add"
            model.draft.keys?[i] = value
            if requiresOptIn { model.draft.allowDestructive = nil }
        })
    }
}

private struct StructureColumnChangeEditor: View {
    @Binding var change: StructureColumnChange
    let columns: [StructureObservedColumn]
    let engine: DatabaseEngine
    let wideningAllowed: Bool
    var authoringAvailable = false
    var destructiveAvailable = false
    let remove: () -> Void
    private var old: StructureObservedColumn? { columns.first { StructureTarget.sameIdentifier($0.name, change.name) } }

    var body: some View {
        GroupBox(change.drop ? "Drop Existing Column" : "Existing Column Change") {
            VStack(alignment: .leading, spacing: 8) {
                HStack {
                    StructureExactNamePicker(title: "Column", placeholder: "Choose column", names: columns.filter { change.drop || authoringAvailable || $0.canModify == true }.map(\.name),
                        selection: Binding(get: { change.name }, set: { change = .init(name: $0, drop: change.drop) }))
                    if !change.drop {
                        Picker("Nullability", selection: Binding(get: { change.nullable.map { $0 ? "nullable" : "required" } ?? "keep" }, set: {
                            change.nullable = $0 == "keep" ? nil : $0 == "nullable"
                        })) {
                            Text("Keep nullability").tag("keep")
                            Text("Allow NULL").tag("nullable")
                            Text("Require NOT NULL").tag("required")
                        }.controlHover().disabled(old?.canModify != true || change.generated != nil || change.identity != nil)
                    }
                    ControlIconButton(systemName: "minus.circle", action: remove).help("Remove this local column change").accessibilityLabel("Remove column change")
                }
                if let old {
                    Text("Current: " + (old.nativeType.isEmpty ? "No declared type" : old.nativeType) + " · " + (old.nullable ? "NULL" : "NOT NULL"))
                        .font(.caption).textSelection(.enabled)
                    Text("Current default: " + (old.defaultExpression ?? "No explicit default reported"))
                        .font(.caption).textSelection(.enabled)
                    if change.drop {
                        Text("DROP permanently removes this column and its stored values. Preview lists known affected dependencies and refuses unproven or implicit external removals.").font(.caption).foregroundStyle(.orange)
                    } else {
                    if authoringAvailable {
                        Toggle("Rename column", isOn: Binding(get: { change.renameTo != nil }, set: { change.renameTo = $0 ? "" : nil })).controlHover()
                        if change.renameTo != nil {
                            TextField("Exact resulting column name", text: Binding(get: { change.renameTo ?? "" }, set: { change.renameTo = $0 })).textFieldStyle(.roundedBorder)
                        }
                    }
                        typeFields(old)
                    TableStructureDefaultEditor(selection: $change.default, engine: engine, allowsKeep: true, authoringAvailable: authoringAvailable)
                        .disabled(old.canModify != true || change.generated != nil || change.identity != nil)
                    if authoringAvailable && engine != .sqlite {
                        TableStructureGenerationEditor(selection: Binding(get: { change.generated }, set: {
                            change.generated = $0
                            if $0 != nil { change.identity = nil; change.type = nil; change.nullable = nil; change.default = nil }
                        }), allowsKeep: true)
                        TableStructureIdentityEditor(selection: Binding(get: { change.identity }, set: {
                            change.identity = $0
                            if $0 != nil { change.generated = nil; change.type = nil; change.nullable = nil; change.default = nil }
                        }), engine: engine, allowsKeep: true)
                        Text("Generation and identity are separate attribute changes. Keep preserves existing settings; Preview checks the server version and prerequisites.").font(.caption).appSecondaryText()
                    }
                    }
                    Text(engine == .sqlite ? "SQLite native DROP requires version 3.35 or later and complete dependency proof. Type, USING, encoding and collation conversions require a separately reviewed table reconstruction, which is unavailable in this direct-DDL editor." : "Keep leaves that attribute unchanged. Widening requires a column without dependencies; Preview verifies support and lock/rebuild risks.")
                        .font(.caption).appSecondaryText()
                } else {
                    Text("Choose a column. Preview checks dependencies and the selected operation’s engine support.").font(.caption).appSecondaryText()
                }
            }.frame(maxWidth: .infinity, alignment: .leading)
        }
    }
    @ViewBuilder private func typeFields(_ old: StructureObservedColumn) -> some View {
    HStack {
        Picker("Type", selection: Binding(get: { change.type?.kind ?? "keep" }, set: { kind in
            if engine == .sqlite {
                change.type = ["integer", "real", "text", "blob", "sqliteNumeric", "any"].contains(kind) ? .init(kind: kind) : nil
                return
            }
            if destructiveAvailable {
                change.type = kind == "keep" ? nil : .init(kind: kind,
                    length: kind == "varchar" ? old.editableType?.length ?? 255 : nil,
                    precision: kind == "numeric" ? old.editableType?.precision ?? 10 : nil,
                    scale: kind == "numeric" ? old.editableType?.scale ?? 0 : nil,
                    reference: kind == "reference" ? .init(schema: "", name: "") : nil)
                return
            }
            switch kind {
            case "bigint": change.type = .init(kind: "bigint")
            case "varchar": change.type = .init(kind: "varchar", length: (old.editableType?.length ?? 0) + 1)
            default: change.type = nil
            }
        })) {
            Text("Keep type").tag("keep")
            if engine == .sqlite {
                Text("INTEGER").tag("integer")
                Text("REAL").tag("real")
                Text("TEXT").tag("text")
                Text("BLOB").tag("blob")
                Text("NUMERIC").tag("sqliteNumeric")
                Text("ANY").tag("any")
            } else if destructiveAvailable {
                ForEach(engine == .postgresql ? ["integer", "bigint", "boolean", "numeric", "varchar", "text"] : ["integer", "bigint", "numeric", "varchar", "text"], id: \.self) { Text($0).tag($0) }
            } else if old.editableType?.kind == "integer" { Text("Widen to BIGINT").tag("bigint") }
            if change.type?.kind == "reference" { Text("Custom conversion · requires migration").tag("reference") }
            if !destructiveAvailable, old.editableType?.kind == "varchar", (old.editableType?.length ?? 16_383) < 16_383 { Text("Increase VARCHAR length").tag("varchar") }
        }.controlHover().disabled(engine == .sqlite || old.canModify != true || change.generated != nil || change.identity != nil || !destructiveAvailable && !wideningAllowed)
        if change.type?.kind == "varchar" {
            TextField("New length", value: Binding(get: { change.type?.length ?? 0 }, set: { change.type?.length = $0 }), format: .number)
                .textFieldStyle(.roundedBorder).frame(width: 95).accessibilityLabel("New VARCHAR length")
        }
    }
    if change.type?.kind == "numeric" {
        HStack {
            TextField("Precision", value: Binding(get: { change.type?.precision ?? 10 }, set: { change.type?.precision = $0 }), format: .number)
            TextField("Scale", value: Binding(get: { change.type?.scale ?? 0 }, set: { change.type?.scale = $0 }), format: .number)
        }.textFieldStyle(.roundedBorder).frame(width: 250)
    }
    if change.type?.kind == "reference" {
        Text("The custom type conversion is retained, but this direct-DDL editor supports only built-in conversion targets. Preserve custom casts and support code through a separately reviewed migration.").font(.caption).foregroundStyle(.orange)
        HStack {
            TextField("Exact type schema", text: Binding(get: { change.type?.reference?.schema ?? "" }, set: { change.type?.reference?.schema = $0 }))
            TextField("Exact type name", text: Binding(get: { change.type?.reference?.name ?? "" }, set: { change.type?.reference?.name = $0 }))
        }.textFieldStyle(.roundedBorder)
    }
    if destructiveAvailable || change.usingExpression != nil || change.unsigned != nil || change.charset != nil || change.collation != nil {
        TableStructureConversionEditor(change: $change, engine: engine).disabled(!destructiveAvailable)
        if !destructiveAvailable { Text("The conversion intent is retained. Reconnect with a helper advertising destructive structure authoring before Preview.").font(.caption).appSecondaryText() }
    }
    }

}

private struct StructureIndexIntentEditor: View {
    @Binding var edit: StructureIndexEdit
    let existing: [StructureIndex]
    let names: [String]
    let engine: DatabaseEngine
    let advancedAvailable: Bool
    let remove: () -> Void
    private var available: [StructureIndex] { existing.filter { $0.editIntent(action: "replace", engine: engine, advancedAllowed: advancedAvailable) != nil } }

    var body: some View {
        GroupBox(engine == .sqlite ? "Ordinary BTREE Index" : "Index") {
            VStack(alignment: .leading, spacing: 8) {
                HStack {
                    StructureActionPicker(action: Binding(get: { edit.action }, set: {
                        guard $0 != edit.action else { return }
                        edit = .init(action: $0, name: "", columns: $0 == "drop" ? nil : [])
                    }))
                    if edit.action == "add" {
                        TextField("Exact index name", text: $edit.name).textFieldStyle(.roundedBorder)
                    } else {
                        StructureExactNamePicker(title: "Index", placeholder: "Choose index", names: available.map(\.name),
                            selection: Binding(get: { edit.name }, set: selectExisting))
                    }
                    ControlIconButton(systemName: "minus.circle", action: remove).help("Remove this local index operation").accessibilityLabel("Remove index operation")
                }
                if edit.action != "drop" {
                    if engine == .postgresql {
                        Toggle("Unique index", isOn: Binding(get: { edit.unique == true }, set: { edit.unique = $0 ? true : nil })).controlHover()
                    }
                    if advancedAvailable || edit.definition != nil {
                        Toggle("Advanced definition", isOn: Binding(get: { edit.definition != nil }, set: { enabled in
                            if enabled { edit.definition = .init(method: "btree", terms: (edit.columns ?? []).map { .init(column: $0) }); edit.columns = nil }
                            else { edit.columns = edit.definition?.terms.compactMap(\.column) ?? []; edit.definition = nil }
                        })).controlHover().disabled(!advancedAvailable)
                    }
                    if edit.definition != nil {
                        StructureIndexDefinitionEditor(definition: Binding(get: { edit.definition ?? .init(method: "btree", terms: []) }, set: { edit.definition = $0 }), names: names, engine: engine)
                            .disabled(!advancedAvailable)
                        if !advancedAvailable { Text("This helper does not advertise advanced index authoring. The definition is retained; reconnect with a compatible helper before Preview.").font(.caption).appSecondaryText() }
                    } else {
                        StructureOrderedColumnsEditor(title: "Columns in index order", options: names,
                            columns: Binding(get: { edit.columns ?? [] }, set: { edit.columns = $0 }))
                    }
                }
                if edit.action != "add", available.isEmpty {
                    Text("There are no supported standalone indexes to select. Indexes owned by a key must be changed through that key.").font(.caption).appSecondaryText()
                }
                if engine == .mysql { Text("Use a Unique key operation for MySQL uniqueness.").font(.caption).appSecondaryText() }
            }
        }
    }
    private func selectExisting(_ name: String) {
        if name.isEmpty { edit = .init(action: edit.action, name: "", columns: edit.action == "drop" ? nil : []); return }
        guard let index = available.first(where: { StructureTarget.sameIdentifier($0.name, name) }),
              let intent = index.editIntent(action: edit.action, engine: engine, advancedAllowed: advancedAvailable) else { return }
        edit = intent
    }
}

private struct StructureKeyIntentEditor: View {
    @Binding var edit: StructureKeyEdit
    let existing: [StructureKey]
    let names: [String]
    let engine: DatabaseEngine
    let schema: String
    var allowCrossDatabase = false
    let remove: () -> Void
    private var available: [StructureKey] { existing.filter { $0.supported && $0.kind == edit.kind } }

    var body: some View {
        GroupBox("Primary, Unique or Foreign Key") {
            VStack(alignment: .leading, spacing: 8) {
                HStack {
                    StructureActionPicker(action: Binding(get: { edit.action }, set: { reset(action: $0, kind: edit.kind) }))
                    Picker("Kind", selection: Binding(get: { edit.kind }, set: { reset(action: edit.action, kind: $0) })) {
                        Text("Primary").tag("primary"); Text("Unique").tag("unique"); Text("Foreign").tag("foreign")
                    }.controlHover()
                    ControlIconButton(systemName: "minus.circle", action: remove).help("Remove this local key operation").accessibilityLabel("Remove key operation")
                }
                if edit.action == "add" {
                    TextField("Exact constraint name", text: $edit.name).textFieldStyle(.roundedBorder)
                        .disabled(engine == .mysql && edit.kind == "primary")
                } else {
                    StructureExactNamePicker(title: "Key", placeholder: "Choose key", names: available.map(\.name),
                        selection: Binding(get: { edit.name }, set: selectExisting))
                }
                if edit.action != "drop" {
                    StructureOrderedColumnsEditor(title: "Source columns in key order", options: names,
                        columns: Binding(get: { edit.columns ?? [] }, set: { edit.columns = $0 }))
                    if edit.kind == "foreign" { foreignKeyFields }
                }
                if edit.action != "add", available.isEmpty {
                    Text("No supported key of this kind is available. Unsupported keys and external dependencies cannot be removed implicitly.")
                        .font(.caption).appSecondaryText()
                }
            }
        }
    }

    private var foreignKeyFields: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                TextField("Referenced schema/database", text: Binding(get: { edit.reference?.schema ?? schema }, set: { ensureReference(); edit.reference?.schema = $0 }))
                    .textFieldStyle(.roundedBorder).disabled(engine == .mysql && !allowCrossDatabase)
                TextField("Exact referenced table name", text: Binding(get: { edit.reference?.table ?? "" }, set: { ensureReference(); edit.reference?.table = $0 }))
                    .textFieldStyle(.roundedBorder)
            }
            StructureOrderedColumnsEditor(title: "Referenced columns in matching order", options: nil,
                columns: Binding(get: { edit.referenceColumns ?? [] }, set: { edit.referenceColumns = $0 }))
            HStack {
                Picker("ON UPDATE", selection: Binding(get: { edit.onUpdate ?? "NO ACTION" }, set: { edit.onUpdate = $0 })) {
                    ForEach(StructureKeyEdit.actions, id: \.self) { Text($0).tag($0) }
                }.controlHover()
                Picker("ON DELETE", selection: Binding(get: { edit.onDelete ?? "NO ACTION" }, set: { edit.onDelete = $0 })) {
                    ForEach(StructureKeyEdit.actions, id: \.self) { Text($0).tag($0) }
                }.controlHover()
            }
            Text("Source and referenced columns must have the same count and matching order. Enter each identifier as one name, including any dots or commas. Preview verifies the referenced key, types and collation; SET NULL requires nullable source columns.")
                .font(.caption).appSecondaryText()
            if engine == .mysql { Text(allowCrossDatabase ? "Preview proves references within this connected server; another profile cannot become an executable target." : "The referenced table must be in this database.").font(.caption).appSecondaryText() }
        }
    }
    private func reset(action: String, kind: String) {
        guard action != edit.action || kind != edit.kind else { return }
        let foreign = action != "drop" && kind == "foreign"
        edit = .init(action: action, kind: kind, name: action == "add" && kind == "primary" && engine == .mysql ? "PRIMARY" : "",
            columns: action == "drop" ? nil : [], reference: foreign ? .init(schema: schema, table: "", create: false) : nil,
            referenceColumns: foreign ? [] : nil, onUpdate: foreign ? "NO ACTION" : nil, onDelete: foreign ? "NO ACTION" : nil)
    }
    private func selectExisting(_ name: String) {
        if name.isEmpty {
            let foreign = edit.action != "drop" && edit.kind == "foreign"
            edit = .init(action: edit.action, kind: edit.kind, name: "", columns: edit.action == "drop" ? nil : [],
                reference: foreign ? .init(schema: schema, table: "", create: false) : nil, referenceColumns: foreign ? [] : nil,
                onUpdate: foreign ? "NO ACTION" : nil, onDelete: foreign ? "NO ACTION" : nil)
            return
        }
        guard let key = available.first(where: { StructureTarget.sameIdentifier($0.name, name) }) else { return }
        let foreign = edit.action != "drop" && key.kind == "foreign"
        edit.name = key.name
        edit.columns = edit.action == "drop" ? nil : key.columns
        edit.reference = foreign ? key.reference : nil
        edit.referenceColumns = foreign ? key.referenceColumns : nil
        edit.onUpdate = foreign ? key.onUpdate ?? "NO ACTION" : nil
        edit.onDelete = foreign ? key.onDelete ?? "NO ACTION" : nil
    }
    private func ensureReference() {
        if edit.reference == nil { edit.reference = .init(schema: schema, table: "", create: false) }
    }
}

private struct StructureActionPicker: View {
    @Binding var action: String
    var body: some View {
        Picker("Action", selection: $action) {
            Text("Add").tag("add"); Text("Remove").tag("drop"); Text("Replace").tag("replace")
        }.controlHover().frame(width: 170)
    }
}

/// Data tags distinguish canonical-equivalent Unicode identifiers. Strings are
/// never split or normalized before they reach the typed draft.
struct StructureExactNamePicker: View {
    let title: String
    let placeholder: String
    let names: [String]
    @Binding var selection: String
    private var choices: [String] {
        var seen = Set<Data>()
        return names.filter { seen.insert(Data($0.utf8)).inserted }
    }
    var body: some View {
        Picker(title, selection: Binding(get: { Data(selection.utf8) }, set: { bytes in
            if bytes.isEmpty { selection = "" }
            else if let name = choices.first(where: { Data($0.utf8) == bytes }) { selection = name }
        })) {
            Text(placeholder).tag(Data())
            ForEach(Array(choices.enumerated()), id: \.offset) { _, name in Text(name).tag(Data(name.utf8)) }
            if !selection.isEmpty, !choices.contains(where: { StructureTarget.sameIdentifier($0, selection) }) {
                Text(selection + " · unavailable").tag(Data(selection.utf8))
            }
        }.controlHover()
    }
}

struct StructureOrderedColumnsEditor: View {
    let title: String
    let options: [String]?
    @Binding var columns: [String]
    private var remaining: [String]? { options?.filter { option in !columns.contains { StructureTarget.sameIdentifier($0, option) } } }
    var body: some View {
        VStack(alignment: .leading, spacing: 5) {
            Text(title).font(.caption)
            ForEach(columns.indices, id: \.self) { i in
                HStack {
                    Text(String(i + 1)).frame(width: 18)
                    if let options {
                        StructureExactNamePicker(title: "Column \(i + 1)", placeholder: "Choose column", names: options,
                            selection: columnBinding(i)).labelsHidden().accessibilityLabel("\(title), position \(i + 1)")
                    } else {
                        TextField("Exact column name", text: columnBinding(i)).textFieldStyle(.roundedBorder)
                            .accessibilityLabel("\(title), position \(i + 1)")
                    }
                    ControlIconButton(systemName: "arrow.up") {
                        guard i > 0, columns.indices.contains(i) else { return }; columns.swapAt(i, i - 1)
                    }.disabled(i == 0).help("Move column earlier").accessibilityLabel("Move column earlier")
                    ControlIconButton(systemName: "arrow.down") {
                        guard columns.indices.contains(i), columns.indices.contains(i + 1) else { return }; columns.swapAt(i, i + 1)
                    }.disabled(i + 1 >= columns.count).help("Move column later").accessibilityLabel("Move column later")
                    ControlIconButton(systemName: "minus.circle") {
                        guard columns.indices.contains(i) else { return }; columns.remove(at: i)
                    }.help("Remove this column from the local key/index draft").accessibilityLabel("Remove ordered column")
                }
            }
            Button("Add Ordered Column") {
                if let options { guard let next = options.first(where: { option in !columns.contains { StructureTarget.sameIdentifier($0, option) } }) else { return }; columns.append(next) }
                else { columns.append("") }
            }.controlHover().disabled(columns.count >= 32 || remaining?.isEmpty == true)
        }
    }
    private func columnBinding(_ i: Int) -> Binding<String> {
        Binding(get: { columns.indices.contains(i) ? columns[i] : "" }, set: { if columns.indices.contains(i) { columns[i] = $0 } })
    }
}
