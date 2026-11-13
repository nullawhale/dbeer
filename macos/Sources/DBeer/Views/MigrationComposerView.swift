import AppKit
import SwiftUI
import UniformTypeIdentifiers

struct MigrationComposerView: View {
    @ObservedObject var model: MigrationComposerModel
    let initialTarget: StructureTarget
    let close: () -> Void
    private var objectSchema = SwiftUI.State(initialValue: "")
    private var objectTable = SwiftUI.State(initialValue: "")
    private var createObject = SwiftUI.State(initialValue: false)
    private var repairSchema = SwiftUI.State(initialValue: "")
    private var repairTable = SwiftUI.State(initialValue: "")
    private var confirmClose = SwiftUI.State(initialValue: false)
    private var confirmReplace = SwiftUI.State(initialValue: false)
    private var confirmRetained = SwiftUI.State(initialValue: false)
    var makeSavePanel: @MainActor () -> NSSavePanel = { NSSavePanel() }
    var makeOpenPanel: @MainActor () -> NSOpenPanel = { NSOpenPanel() }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Text("Multi-object Migration").font(.title2)
                Spacer()
                Text(model.profile.name + " · " + model.profile.policy.label).appSecondaryText()
            }
            Text("Select each table intent and each external foreign-key repair independently. All targets use this profile and server. Preview reads metadata; Apply executes only the exact reviewed plan.")
                .font(.caption).appSecondaryText()
            files
            ScrollView {
                VStack(alignment: .leading, spacing: 14) {
                    if model.report == nil { objects; repairs }
                    if let plan = model.preview { MigrationPlanReviewView(plan: plan) }
                    if let report = model.report {
                        MigrationExecutionReportView(report: report)
                        Button("Save Execution Report…") { saveReport(report) }.controlHover().disabled(model.isBusy || model.closing)
                    }
                    if !model.observations.isEmpty {
                        DisclosureGroup("Explicitly reconciled current structures") {
                            ForEach(Array(model.observations.enumerated()), id: \.offset) { _, baseline in
                                DisclosureGroup(baseline.target.schema + "." + baseline.target.table) { TableStructureBaselineDetails(baseline: baseline) }
                            }
                        }
                    }
                    if model.retainedIntentNeedsReview, !model.reconciliationRequired {
                        Text("Reconciliation observed current structures. Retained intent still includes every originally selected entry; remove completed or obsolete work before requesting a fresh review.")
                            .font(.caption).foregroundStyle(.orange)
                        Button("Review Retained Intent for a New Plan…") { confirmRetained.wrappedValue = true }.controlHover().disabled(model.isBusy || model.closing)
                    }
                    previousReports
                    if let notice = model.notice { Text(notice).font(.caption).appSecondaryText().textSelection(.enabled) }
                    if let error = model.error { Text(error).foregroundStyle(.orange).textSelection(.enabled) }
                }.frame(maxWidth: .infinity, alignment: .leading)
            }.frame(minHeight: 260, idealHeight: 490, maxHeight: 650)
            footer
        }.padding(20).frame(width: 930).frame(minHeight: 420, idealHeight: 730, maxHeight: 900)
        .interactiveDismissDisabled()
        .onAppear {
            objectSchema.wrappedValue = initialTarget.schema; objectTable.wrappedValue = initialTarget.table
            repairSchema.wrappedValue = initialTarget.schema
        }
        .sheet(item: Binding(get: { model.objectEditor }, set: { if $0 == nil { model.cancelObjectEditor() } })) { editor in
            MigrationObjectIntentView(editor: editor, stage: model.stageObject, cancel: model.cancelObjectEditor)
        }
        .confirmationDialog("Close this migration composer? Save portable intent and execution reports if they are needed after this workspace session.", isPresented: confirmClose.projectedValue) {
            Button("Close", role: .destructive, action: close)
            Button("Keep Open", role: .cancel) {}
        }
        .confirmationDialog("Replace the selected intent with a portable draft? It will stay disconnected and require a fresh review.", isPresented: confirmReplace.projectedValue) {
            Button("Open Draft", role: .destructive) { openDraft() }
            Button("Cancel", role: .cancel) {}
        }
        .confirmationDialog("Review every retained entry before a new Preview. Previously applied or unknown work is never retried automatically.", isPresented: confirmRetained.projectedValue) {
            Button("Review Retained Selection") { model.reviewRetainedIntent() }
            Button("Cancel", role: .cancel) {}
        }
    }
    private var files: some View {
        HStack {
            Menu("Migration") {
                Button("Open Portable Intent…") { if model.hasIntent { confirmReplace.wrappedValue = true } else { openDraft() } }.disabled(!model.canOpenDraft)
                Button("Save Portable Intent") { saveDraft(saveAs: false) }.disabled(model.isBusy || model.closing || !model.portableDraft.valid)
                Button("Save Portable Intent As…") { saveDraft(saveAs: true) }.disabled(model.isBusy || model.closing || !model.portableDraft.valid)
                Divider()
                Button("Export Reviewed SQL…", action: exportSQL).disabled(model.isBusy || model.closing || model.exportablePlan == nil)
                Button("Open Saved Execution Report…", action: openReport).disabled(model.isBusy || model.closing)
            }.fixedSize().controlHover().accessibilityIdentifier("migrationFiles")
            if let label = model.draftFileLabel { Text(label).font(.caption).appSecondaryText().textSelection(.enabled).lineLimit(1) }
            Spacer()
        }
    }
    private var objects: some View {
        GroupBox("Selected object intent (\(model.draft.objects.count)/16)") {
            VStack(alignment: .leading, spacing: 10) {
                HStack {
                    TextField("Exact schema/database", text: objectSchema.projectedValue).textFieldStyle(.roundedBorder)
                    TextField("Exact table name", text: objectTable.projectedValue).textFieldStyle(.roundedBorder)
                    Toggle("Create", isOn: createObject.projectedValue).controlHover().fixedSize()
                    Button("Load & Edit Object…") {
                        Task { await model.editObject(nil, target: .init(schema: objectSchema.wrappedValue, table: objectTable.wrappedValue, create: createObject.wrappedValue)) }
                    }.controlHover().disabled(!model.editable || model.draft.objects.count >= 16 || objectSchema.wrappedValue.isEmpty || objectTable.wrappedValue.isEmpty)
                }
                ForEach(model.draft.objects, id: \.id) { object in
                    VStack(alignment: .leading, spacing: 6) {
                        HStack {
                            Text(object.target.schema + "." + object.target.table + (object.target.create ? " · create" : "")).font(.headline).textSelection(.enabled)
                            Spacer()
                            Button("Edit Intent…") { Task { await model.editObject(object, target: object.target) } }.controlHover()
                            ControlIconButton(systemName: "minus.circle") { model.removeObject(object.id) }.accessibilityLabel("Remove selected object")
                        }
                        DisclosureGroup("Prerequisites and retained typed intent") {
                            VStack(alignment: .leading, spacing: 6) {
                                Text("Object ID: " + object.id).font(.caption).textSelection(.enabled)
                                Text("Run this object after the selected prerequisites. Preview also verifies foreign-key prerequisites and rejects cycles or missing proof.").font(.caption).appSecondaryText()
                                ForEach(model.draft.objects.filter { $0.id != object.id }, id: \.id) { prerequisite in
                                    Toggle(prerequisite.target.schema + "." + prerequisite.target.table, isOn: Binding(get: { object.after.contains(prerequisite.id) }, set: {
                                        model.setPrerequisite(objectID: object.id, prerequisiteID: prerequisite.id, selected: $0)
                                    })).controlHover()
                                }
                                TableStructureDraftSummary(draft: object.draft)
                                if object.draft.destructive, object.draft.allowDestructive != true {
                                    Text("Renew destructive consent by editing this object's intent before Preview.").font(.caption).foregroundStyle(.orange)
                                }
                            }
                        }
                    }.padding(8).background(.quaternary.opacity(0.3), in: RoundedRectangle(cornerRadius: 5))
                }
            }.disabled(!model.editable).frame(maxWidth: .infinity, alignment: .leading)
        }
    }
    private var repairs: some View {
        GroupBox("Individually selected external foreign-key repairs (\(model.draft.repairs.count)/16)") {
            VStack(alignment: .leading, spacing: 10) {
                Text("Load an exact external owner, then choose each foreign key explicitly. Loading a table never chooses, drops or replaces a dependency. Unselected incoming dependencies block Preview.")
                    .font(.caption).appSecondaryText()
                HStack {
                    TextField("External owner schema/database", text: repairSchema.projectedValue).textFieldStyle(.roundedBorder)
                    TextField("External owner table", text: repairTable.projectedValue).textFieldStyle(.roundedBorder)
                    Button("Load Owner") { Task { await model.loadRepairTarget(.init(schema: repairSchema.wrappedValue, table: repairTable.wrappedValue, create: false)) } }
                        .controlHover().disabled(!model.editable || repairSchema.wrappedValue.isEmpty || repairTable.wrappedValue.isEmpty)
                }
                if let baseline = model.repairBaseline {
                    Text("Loaded: " + baseline.target.schema + "." + baseline.target.table).font(.caption).textSelection(.enabled)
                    ForEach((baseline.keys ?? []).filter { $0.kind == "foreign" && $0.supported }, id: \.name) { key in
                        Button("Select repair for " + key.name) { model.selectRepair(key: key) }.controlHover().disabled(model.draft.repairs.count >= 16)
                    }
                    if (baseline.keys ?? []).filter({ $0.kind == "foreign" && $0.supported }).isEmpty { Text("No supported foreign keys were reported for this owner.").font(.caption).appSecondaryText() }
                }
                ForEach(model.draft.repairs, id: \.id) { repair in
                    MigrationRepairEditor(repair: repairBinding(repair.id), engine: model.profile.engine) { model.removeRepair(repair.id) }
                }
            }.disabled(!model.editable).frame(maxWidth: .infinity, alignment: .leading)
        }
    }
    private func repairBinding(_ id: String) -> Binding<StructureMigrationRepair> {
        Binding(get: { model.draft.repairs.first { $0.id == id } ?? .init(id: id, target: .init(schema: "", table: "", create: false), key: "", action: "drop") }, set: { value in
            guard model.editable, let i = model.draft.repairs.firstIndex(where: { $0.id == id }) else { return }; model.draft.repairs[i] = value
        })
    }
    private var previousReports: some View {
        Group {
            if !model.history.isEmpty {
                DisclosureGroup("Independent retained execution reports") {
                    ForEach(model.history) { report in
                        DisclosureGroup(report.outcome.state + " · " + report.id) {
                            MigrationExecutionReportView(report: report)
                            Button("Save This Report…") { saveReport(report) }.controlHover().disabled(model.isBusy || model.closing)
                        }
                    }
                }
            }
        }
    }
    private var footer: some View {
        HStack {
            if model.isBusy { ProgressView().controlSize(.small); Button("Stop") { Task { await model.stop() } }.controlHover().disabled(model.closing) }
            Spacer()
            if model.report != nil {
                Button("Check Execution Status") { Task { await model.checkStatus() } }.controlHover().disabled(!model.canCheckStatus)
                Button("Reconcile Current Structures") { Task { await model.reconcile() } }.controlHover().disabled(!model.canReconcile)
            }
            Button("Preview Migration SQL") { Task { await model.preparePreview() } }.controlHover().disabled(!model.canPreview)
            Button("Apply Reviewed Migration…") { Task { await model.apply() } }.controlHover().disabled(!model.canApply)
            Button("Close") {
                if model.hasIntent || model.report != nil { confirmClose.wrappedValue = true } else { close() }
            }.controlHover().disabled(model.isBusy || model.closing).keyboardShortcut(.cancelAction)
        }
    }
    private func saveDraft(saveAs: Bool) {
        let expected = model.portableDraft
        if !saveAs, let url = model.draftFileURL, let version = model.draftFileVersion { Task { await model.saveDraft(to: url, expected: expected, version: version) }; return }
        chooseSave(name: "migration.dbeermigration", extension: "dbeermigration", maximumBytes: MigrationDraftDocument.maximumBytes) { url, version in
            Task { await model.saveDraft(to: url, expected: expected, version: version) }
        }
    }
    private func openDraft() {
        let expected = model.portableDraft
        chooseOpen(extension: "dbeermigration") { url in Task { await model.openDraft(from: url, expected: expected) } }
    }
    private func exportSQL() {
        guard let expected = model.exportablePlan else { return }
        chooseSave(name: "migration.sql", extension: "sql", maximumBytes: 8 * 1_024 * 1_024) { url, version in Task { await model.exportSQL(to: url, expected: expected, version: version) } }
    }
    private func saveReport(_ expected: MigrationExecutionDocument) {
        chooseSave(name: "migration-execution.dbeermigrationreport", extension: "dbeermigrationreport", maximumBytes: MigrationExecutionDocument.maximumBytes) { url, version in
            Task { await model.saveReport(to: url, expected: expected, version: version) }
        }
    }
    private func openReport() { chooseOpen(extension: "dbeermigrationreport") { url in Task { await model.openReport(from: url) } } }
    private func chooseOpen(extension suffix: String, selected: @escaping @MainActor (URL) -> Void) {
        let panel = makeOpenPanel(); panel.allowsMultipleSelection = false; panel.canChooseDirectories = false
        panel.allowedContentTypes = [UTType(filenameExtension: suffix, conformingTo: .json) ?? .json]
        panel.begin { response in guard response == .OK, let url = panel.url else { return }; selected(url) }
    }
    private func chooseSave(name: String, extension suffix: String, maximumBytes: Int, selected: @escaping @MainActor (URL, SQLFileVersion?) -> Void) {
        let panel = makeSavePanel(); panel.nameFieldStringValue = name
        panel.allowedContentTypes = [UTType(filenameExtension: suffix) ?? .data]
        panel.begin { response in
            guard response == .OK, let url = panel.url else { return }
            do { selected(url, try StructureDraftStore.destinationVersion(url, maximumBytes: maximumBytes)) }
            catch { model.setFileError(error) }
        }
    }
}

private struct MigrationObjectIntentView: View {
    @ObservedObject var editor: TableStructureEditorModel
    let stage: () -> Void
    let cancel: () -> Void
    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Migration Object Intent").font(.title2)
            Text(editor.target.schema + "." + editor.target.table).textSelection(.enabled)
            Text("These typed edits are staged locally. The complete migration Preview reviews every selected object and repair together.").font(.caption).appSecondaryText()
            ScrollView {
                VStack(alignment: .leading, spacing: 12) {
                    if let baseline = editor.baseline { DisclosureGroup("Loaded current structure") { TableStructureBaselineDetails(baseline: baseline) } }
                    TableStructureDraftFields(model: editor, allowCrossDatabase: true)
                    if let error = editor.error { Text(error).foregroundStyle(.orange) }
                }
            }.frame(minHeight: 260, idealHeight: 490, maxHeight: 620)
            HStack { Spacer(); Button("Cancel", action: cancel).controlHover().keyboardShortcut(.cancelAction); Button("Stage Object Intent", action: stage).controlHover() }
        }.padding(20).frame(width: 850).interactiveDismissDisabled()
    }
}

private struct MigrationRepairEditor: View {
    @Binding var repair: StructureMigrationRepair
    let engine: DatabaseEngine
    let remove: () -> Void
    var body: some View {
        GroupBox(repair.target.schema + "." + repair.target.table + " · " + repair.key) {
            VStack(alignment: .leading, spacing: 8) {
                HStack {
                    Picker("Repair", selection: Binding(get: { repair.action }, set: { action in
                        repair.action = action
                        repair.replacement = action == "replace" ? .init(action: "add", kind: "foreign", name: repair.key, columns: [], reference: .init(schema: repair.target.schema, table: "", create: false), referenceColumns: [], onUpdate: "NO ACTION", onDelete: "NO ACTION") : nil
                    })) { Text("Drop and add reviewed replacement").tag("replace"); Text("Permanently drop this foreign key").tag("drop") }.controlHover()
                    ControlIconButton(systemName: "minus.circle", action: remove).accessibilityLabel("Remove selected foreign-key repair")
                }
                if repair.action == "replace" {
                    Text("Enter the exact resulting source/reference identifiers after any reviewed renames. No expression or SQL is rewritten automatically.").font(.caption).appSecondaryText()
                    StructureOrderedColumnsEditor(title: "Source columns in matching order", options: nil, columns: replacementColumns(reference: false))
                    HStack {
                        TextField("Referenced schema/database", text: referenceField(schema: true)).textFieldStyle(.roundedBorder)
                        TextField("Exact referenced table", text: referenceField(schema: false)).textFieldStyle(.roundedBorder)
                    }
                    StructureOrderedColumnsEditor(title: "Referenced columns in matching order", options: nil, columns: replacementColumns(reference: true))
                    HStack {
                        Picker("ON UPDATE", selection: actionField(update: true)) { ForEach(StructureKeyEdit.actions, id: \.self) { Text($0).tag($0) } }.controlHover()
                        Picker("ON DELETE", selection: actionField(update: false)) { ForEach(StructureKeyEdit.actions, id: \.self) { Text($0).tag($0) } }.controlHover()
                    }
                }
                Text(repair.action == "drop" ? "This deliberately leaves the selected constraint absent. Preview discloses loss of referential enforcement." : "The selected foreign key is absent between its drop and successful replacement. Concurrent writes may make replacement fail.")
                    .font(.caption).foregroundStyle(.orange)
            }.frame(maxWidth: .infinity, alignment: .leading)
        }
    }
    private func replacementColumns(reference: Bool) -> Binding<[String]> {
        Binding(get: { (reference ? repair.replacement?.referenceColumns : repair.replacement?.columns) ?? [] }, set: {
            if reference { repair.replacement?.referenceColumns = $0 } else { repair.replacement?.columns = $0 }
        })
    }
    private func referenceField(schema: Bool) -> Binding<String> {
        Binding(get: { (schema ? repair.replacement?.reference?.schema : repair.replacement?.reference?.table) ?? "" }, set: {
            if schema { repair.replacement?.reference?.schema = $0 } else { repair.replacement?.reference?.table = $0 }
        })
    }
    private func actionField(update: Bool) -> Binding<String> {
        Binding(get: { (update ? repair.replacement?.onUpdate : repair.replacement?.onDelete) ?? "NO ACTION" }, set: {
            if update { repair.replacement?.onUpdate = $0 } else { repair.replacement?.onDelete = $0 }
        })
    }
}
