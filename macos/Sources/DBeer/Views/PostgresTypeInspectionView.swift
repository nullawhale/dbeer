import SwiftUI

/// Type metadata and generated DDL share the captured connection context. The
/// callbacks deliberately leave execution to an ordinary SQL document.
struct PostgresTypeInspectionView: View {
    @ObservedObject var model: PostgresTypeInspectionModel
    let refresh: () -> Void
    let preview: (TypeChange) -> Void
    let discardPreview: () -> Void
    let stop: () -> Void
    let openSQL: () -> Void
    let close: () -> Void

    private enum Section: Hashable { case definition, values, dependencies }
    private enum Operation: String, CaseIterable, Hashable, Identifiable {
        case renameType, addEnumValue, renameEnumValue
        var id: String { rawValue }
        var title: String {
            switch self {
            case .renameType: "Rename Type"
            case .addEnumValue: "Add Enum Value at End"
            case .renameEnumValue: "Rename Enum Value"
            }
        }
    }
    private enum DependencyScope: String, CaseIterable, Identifiable {
        case all, incoming, outgoing
        var id: String { rawValue }
        var title: String {
            switch self {
            case .all: "All Direct Dependencies"
            case .incoming: "Incoming · Uses This Type"
            case .outgoing: "Outgoing · Used by This Type"
            }
        }
    }

    private var section = SwiftUI.State(initialValue: Section.definition)
    private var operation = SwiftUI.State(initialValue: Operation.renameType)
    private var newName = SwiftUI.State(initialValue: "")
    private var value = SwiftUI.State(initialValue: "")
    private var selectedEnumPosition = SwiftUI.State<Int?>(initialValue: nil)
    private var dependencyScope = SwiftUI.State(initialValue: DependencyScope.all)

    private var operationSelection: Binding<Operation> {
        Binding(get: { operation.wrappedValue }, set: { discardPreview(); operation.wrappedValue = $0 })
    }
    private var nameInput: Binding<String> {
        Binding(get: { newName.wrappedValue }, set: { discardPreview(); newName.wrappedValue = $0 })
    }
    private var valueInput: Binding<String> {
        Binding(get: { value.wrappedValue }, set: { discardPreview(); value.wrappedValue = $0 })
    }
    private var enumSelection: Binding<Int?> {
        Binding(get: { selectedEnumPosition.wrappedValue }, set: { discardPreview(); selectedEnumPosition.wrappedValue = $0 })
    }

    private var isEnum: Bool { model.reference.objectKind == "enum" }
    private var isBusy: Bool { model.isLoading || model.isPreparingPreview }
    private var showsPreview: Bool { model.preview != nil || model.isPreparingPreview }
    private var selectedEnumValue: PostgresEnumValue? {
        model.enumValues?.first { $0.position == selectedEnumPosition.wrappedValue }
    }
    private var operations: [Operation] {
        guard let details = model.details else { return [] }
        return Operation.allCases.filter {
            switch $0 {
            case .renameType: details.renameSupported
            case .addEnumValue: details.addEnumValueSupported
            case .renameEnumValue: details.renameEnumValueSupported
            }
        }
    }
    private var change: TypeChange? {
        guard operations.contains(operation.wrappedValue), model.invalidationReason == nil, !isBusy else { return nil }
        switch operation.wrappedValue {
        case .renameType:
            guard !newName.wrappedValue.isEmpty else { return nil }
            return TypeChange(operation: "renameType", newName: newName.wrappedValue)
        case .addEnumValue:
            return TypeChange(operation: "addEnumValue", value: value.wrappedValue)
        case .renameEnumValue:
            guard let selectedEnumValue else { return nil }
            return TypeChange(operation: "renameEnumValue", oldValue: selectedEnumValue.label, value: value.wrappedValue)
        }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            header
            if let invalidation = model.invalidationReason {
                notice(invalidation, identifier: "postgresTypeInvalidation")
            }
            if let cancellation = model.cancellationNotice {
                notice(cancellation, identifier: "postgresTypeCancellation")
            }
            if showsPreview { ddlPreview }
            else { metadata }
        }
        .padding(20)
        .frame(minWidth: 620, idealWidth: 800, maxWidth: .infinity, minHeight: 620, idealHeight: 740, maxHeight: .infinity)
        .tint(AppPalette.accent)
        .focusEffectDisabled()
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("postgresTypeInspection")
        .onAppear { reconcileOperation() }
        .onChange(of: model.enumValues?.map(\.position)) { _, positions in
            if let selected = selectedEnumPosition.wrappedValue, positions?.contains(selected) != true {
                enumSelection.wrappedValue = nil
            }
        }
        .onChange(of: operations) { _, choices in
            if !choices.contains(operation.wrappedValue) { reconcileOperation() }
        }
    }

    private func reconcileOperation() {
        if !operations.contains(operation.wrappedValue), let first = operations.first {
            operationSelection.wrappedValue = first
        }
    }

    private var header: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(alignment: .top, spacing: 12) {
                VStack(alignment: .leading, spacing: 4) {
                    Text(showsPreview ? "DDL Preview" : "PostgreSQL Type").font(.title2)
                    Text(verbatim: model.title).font(.system(.callout, design: .monospaced))
                        .textSelection(.enabled).fixedSize(horizontal: false, vertical: true)
                        .accessibilityIdentifier("postgresTypeIdentity")
                }
                Spacer(minLength: 0)
                if isBusy { ProgressView().controlSize(.small) }
                if isBusy {
                    Button("Stop", action: stop).controlHover()
                        .accessibilityIdentifier("stopPostgresTypeInspection")
                }
                Button("Done", action: close).controlHover().keyboardShortcut(.cancelAction)
                    .accessibilityIdentifier("dismissPostgresTypeInspection")
            }
            Text("Source: \(model.profileName) · PostgreSQL · \(model.details?.typeKind.capitalized ?? (isEnum ? "Enum" : "User-defined Type")) · \(model.reference.policy.label)")
                .font(.caption).appSecondaryText().textSelection(.enabled)
                .fixedSize(horizontal: false, vertical: true)
                .accessibilityIdentifier("postgresTypeSource")
        }
    }

    private var metadata: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                ControlSegmentPicker("Inspect", selection: section.projectedValue, choices: sections)
                    .labelsHidden().accessibilityIdentifier("postgresTypeSections")
                Spacer(minLength: 0)
                Button("Refresh", action: refresh).controlHover().disabled(isBusy)
                    .accessibilityIdentifier("refreshPostgresTypeInspection")
            }
            Group {
                switch section.wrappedValue {
                case .definition: definition
                case .values: enumValues
                case .dependencies: dependencies
                }
            }
            .frame(maxWidth: .infinity, minHeight: 160, maxHeight: .infinity, alignment: .topLeading)
            Divider()
            operationForm
        }
    }

    private var sections: [ControlSegmentPicker<Section>.Choice] {
        var result: [ControlSegmentPicker<Section>.Choice] = [.init("Definition", value: .definition)]
        if isEnum { result.append(.init("Enum Values", value: .values)) }
        result.append(.init("Dependencies", value: .dependencies))
        return result
    }

    private var definition: some View {
        ScrollView([.vertical, .horizontal]) {
            VStack(alignment: .leading, spacing: 10) {
                if let error = model.metadataError { notice(error, identifier: "postgresTypeMetadataError") }
                if let details = model.details {
                    if let owner = details.owner { LabeledContent("Owner", value: owner).font(.caption) }
                    if let description = details.details, !description.isEmpty {
                        Text(verbatim: description).font(.callout).textSelection(.enabled)
                    }
                    if details.definitionStatus != .complete {
                        notice(details.definitionStatus == .partial
                            ? "Partial definition: some properties cannot be reconstructed. Review the details and limitations before using this SQL."
                            : "A complete CREATE definition is unavailable for this type. Structured metadata and operation limitations are shown instead.",
                            identifier: "postgresTypeDefinitionLimitation")
                    }
                    if let sql = details.definition, !sql.isEmpty {
                        Text(verbatim: sql).font(.system(.callout, design: .monospaced)).textSelection(.enabled)
                            .accessibilityIdentifier("postgresTypeDefinition")
                    }
                } else if model.isLoading {
                    Text("Loading type metadata…").appSecondaryText()
                } else if model.metadataError == nil {
                    Text("Type metadata is unavailable. Refresh to try again.").appSecondaryText()
                }
            }.frame(maxWidth: .infinity, alignment: .topLeading).padding(.trailing, 8)
        }
        .accessibilityIdentifier("postgresTypeDefinitionSection")
    }

    private var enumValues: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("PostgreSQL order is preserved. Quoted labels show empty text and whitespace explicitly.")
                .font(.caption).appSecondaryText().fixedSize(horizontal: false, vertical: true)
            if let error = model.enumValuesError { notice(error, identifier: "postgresEnumValuesError") }
            if let values = model.enumValues {
                if !model.enumValuesComplete {
                    notice("The enum value list is incomplete. Missing labels or ordering cannot be inferred from this response.",
                           identifier: "postgresEnumValuesIncomplete")
                }
                if values.isEmpty {
                    Text(model.enumValuesComplete ? "This enum has no values." : "No values were returned in this incomplete response.")
                        .font(.callout).appSecondaryText().accessibilityIdentifier("postgresEnumValuesEmpty")
                } else {
                    Table(values, selection: enumSelection) {
                        TableColumn("Position") { item in Text(item.position.formatted()).monospacedDigit() }.width(65)
                        TableColumn("Exact Label") { item in
                            Text(verbatim: Self.labelDisplay(item.label)).font(.system(.callout, design: .monospaced))
                                .textSelection(.enabled).help(Self.labelDisplay(item.label))
                                .accessibilityIdentifier("postgresEnumValue-\(item.position)")
                        }.width(min: 200, ideal: 430)
                        TableColumn("Server Sort Order") { item in Text(verbatim: item.sortOrder).monospacedDigit() }.width(125)
                    }.accessibilityIdentifier("postgresEnumValuesTable")
                }
            } else if model.isLoading { Text("Loading enum values…").appSecondaryText() }
            else if model.enumValuesError == nil { Text("Enum values are unavailable.").appSecondaryText() }
        }.accessibilityIdentifier("postgresEnumValuesSection")
    }

    private var filteredDependencies: [PostgresTypeDependency] {
        (model.dependencies ?? []).filter { dependencyScope.wrappedValue == .all || $0.direction == dependencyScope.wrappedValue.rawValue }
    }

    private var dependencies: some View {
        VStack(alignment: .leading, spacing: 8) {
            Picker("Scope", selection: dependencyScope.projectedValue) {
                ForEach(DependencyScope.allCases) { scope in Text(scope.title).tag(scope) }
            }.controlHover().accessibilityIdentifier("postgresTypeDependencyScope")
            Text("This list contains direct pg_depend catalog links, including column subobjects, automatic arrays, and extension relationships. Ownership, role references, and other shared-cluster dependencies are excluded. Dynamic SQL references may not be recorded.")
                .font(.caption).appSecondaryText().fixedSize(horizontal: false, vertical: true)
                .accessibilityIdentifier("postgresTypeDependencyNotice")
            if let error = model.dependenciesError { notice(error, identifier: "postgresTypeDependenciesError") }
            if model.dependencies != nil {
                if !model.dependenciesComplete {
                    notice("The dependency list is incomplete. This response cannot establish that the type has no other dependencies.",
                           identifier: "postgresTypeDependenciesIncomplete")
                }
                if filteredDependencies.isEmpty {
                    Text(model.dependenciesComplete ? "No direct pg_depend links in this scope." : "No dependencies were returned in this incomplete scope.")
                        .font(.callout).appSecondaryText().accessibilityIdentifier("postgresTypeDependenciesEmpty")
                } else {
                    Table(filteredDependencies) {
                        TableColumn("Direction") { item in Text(item.direction.capitalized) }.width(80)
                        TableColumn("Kind") { item in Text(verbatim: item.objectKind) }.width(min: 70, ideal: 90)
                        TableColumn("Object") { item in
                            Text(verbatim: item.objectIdentity).font(.system(.callout, design: .monospaced))
                                .textSelection(.enabled).help(item.objectIdentity)
                                .accessibilityIdentifier("postgresTypeDependency-\(item.id)")
                        }.width(min: 180, ideal: 350)
                        TableColumn("Dependency Class") { item in Text(verbatim: item.dependencyClass) }.width(min: 100, ideal: 130)
                    }.accessibilityIdentifier("postgresTypeDependenciesTable")
                }
            } else if model.isLoading { Text("Loading dependencies…").appSecondaryText() }
            else if model.dependenciesError == nil { Text("Dependencies are unavailable.").appSecondaryText() }
        }.accessibilityIdentifier("postgresTypeDependenciesSection")
    }

    private var operationForm: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Generate DDL").font(.headline)
            Text("Preview does not change the server. Open a SQL tab, then use Run for the normal execution policy and confirmation.")
                .font(.caption).appSecondaryText().fixedSize(horizontal: false, vertical: true)
            if let limitations = model.details?.operationLimitations, !limitations.isEmpty {
                Text(verbatim: limitations).font(.caption).textSelection(.enabled)
                    .fixedSize(horizontal: false, vertical: true).accessibilityIdentifier("postgresTypeOperationLimitations")
            }
            Text(isEnum
                ? "Enum values can be appended or renamed. Removal, reordering, and CASCADE are not provided; generated DDL has no automatic rollback guarantee."
                : "Only supported rename operations are offered. Type replacement, CASCADE, and migration planning are outside this inspector; generated DDL has no automatic rollback guarantee.")
                .font(.caption).appSecondaryText().fixedSize(horizontal: false, vertical: true)
                .accessibilityIdentifier("postgresTypeOperationBoundary")
            if let hint = model.details?.permissionHint, !hint.isEmpty {
                Text(verbatim: hint).font(.caption).appSecondaryText().textSelection(.enabled)
                    .fixedSize(horizontal: false, vertical: true).accessibilityIdentifier("postgresTypePermissionHint")
            }
            if operations.isEmpty {
                if !model.isLoading {
                    Text("DDL preview is unavailable for this type. Review the operation limitations above.")
                        .font(.callout).appSecondaryText().accessibilityIdentifier("postgresTypeOperationsUnavailable")
                }
            } else {
                Picker("Operation", selection: operationSelection) {
                    ForEach(operations) { choice in Text(choice.title).tag(choice) }
                }.controlHover().accessibilityIdentifier("postgresTypeOperation")
                operationFields
                if operation.wrappedValue == .addEnumValue {
                    notice("A newly added enum value can be used only after its transaction commits.",
                           identifier: "postgresTypeEnumCommitWarning")
                }
                HStack {
                    Text("Input is preserved exactly, including whitespace and empty enum labels.")
                        .font(.caption2).appSecondaryText().fixedSize(horizontal: false, vertical: true)
                    Spacer(minLength: 8)
                    Button("Preview DDL") { if let change { preview(change) } }
                        .controlHover().disabled(change == nil).keyboardShortcut(.return, modifiers: .command)
                        .accessibilityIdentifier("previewPostgresTypeDDL")
                }
            }
            if let error = model.previewError { notice(error, identifier: "postgresTypePreviewError") }
        }
    }

    @ViewBuilder private var operationFields: some View {
        switch operation.wrappedValue {
        case .renameType:
            TextField("New type name", text: nameInput).textFieldStyle(.roundedBorder)
                .accessibilityIdentifier("postgresTypeNewName")
        case .addEnumValue:
            TextField("New enum label (empty is valid)", text: valueInput).textFieldStyle(.roundedBorder)
                .accessibilityIdentifier("postgresTypeNewEnumValue")
        case .renameEnumValue:
            Picker("Existing Label", selection: enumSelection) {
                Text("Select an enum value").tag(Int?.none)
                ForEach(model.enumValues ?? []) { item in
                    Text(verbatim: "\(item.position). \(Self.labelDisplay(item.label))").tag(Optional(item.position))
                }
            }.controlHover().accessibilityIdentifier("postgresTypeOldEnumValue")
            TextField("Replacement enum label (empty is valid)", text: valueInput).textFieldStyle(.roundedBorder)
                .accessibilityIdentifier("postgresTypeNewEnumValue")
        }
    }

    private var ddlPreview: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Destination: SQL tab for \(model.profileName) in the \(model.destinationPane == .left ? "left" : "right") pane")
                .font(.callout).fixedSize(horizontal: false, vertical: true)
                .accessibilityIdentifier("postgresTypeDDLDestination")
            Text("Opening the tab does not connect or execute. Run checks the exact SQL under the connection's current policy. Refresh this inspector explicitly after execution.")
                .font(.caption).appSecondaryText().fixedSize(horizontal: false, vertical: true)
            if let generated = model.preview {
                previewChange(generated.change)
                if generated.change.operation == "addEnumValue" {
                    notice("A newly added enum value can be used only after its transaction commits.",
                           identifier: "postgresTypeEnumCommitWarning")
                }
                if let warnings = generated.warnings, !warnings.isEmpty {
                    notice(warnings, identifier: "postgresTypeDDLWarnings")
                }
                ScrollView([.vertical, .horizontal]) {
                    Text(verbatim: generated.sql).font(.system(.callout, design: .monospaced)).textSelection(.enabled)
                        .frame(maxWidth: .infinity, alignment: .topLeading).padding(12)
                }
                .background(.primary.opacity(0.035), in: RoundedRectangle(cornerRadius: 5))
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .accessibilityIdentifier("postgresTypeDDLPreview")
                Text("This is ordinary qualified-name SQL. Server permissions and current object state remain authoritative; no automatic retry or transaction wrapper is added.")
                    .font(.caption).appSecondaryText().fixedSize(horizontal: false, vertical: true)
                HStack {
                    Button("Back to Type", action: discardPreview).controlHover()
                        .accessibilityIdentifier("discardPostgresTypePreview")
                    Spacer()
                    Button("Open SQL Tab", action: openSQL).controlHover()
                        .disabled(!model.canOpenSQLDraft).keyboardShortcut(.defaultAction)
                        .accessibilityIdentifier("openPostgresTypeSQLTab")
                }
            } else {
                Text("Generating DDL preview…").appSecondaryText()
                Spacer()
                Button("Cancel Preview", action: discardPreview).controlHover()
                    .accessibilityIdentifier("discardPostgresTypePreview")
            }
        }
    }

    private func notice(_ text: String, identifier: String) -> some View {
        Text(verbatim: text).font(.caption).foregroundStyle(.orange).textSelection(.enabled)
            .fixedSize(horizontal: false, vertical: true).accessibilityIdentifier(identifier)
    }

    private func previewChange(_ change: TypeChange) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Text("Operation: \(Operation(rawValue: change.operation)?.title ?? change.operation)").font(.headline)
            if let name = change.newName {
                Text(verbatim: "New type name: " + String(reflecting: name))
                    .font(.system(.caption, design: .monospaced)).textSelection(.enabled)
            }
            if let previous = change.oldValue {
                Text(verbatim: "Existing enum label: " + Self.labelDisplay(previous))
                    .font(.system(.caption, design: .monospaced)).textSelection(.enabled)
            }
            if let next = change.value {
                Text(verbatim: "New enum label: " + Self.labelDisplay(next))
                    .font(.system(.caption, design: .monospaced)).textSelection(.enabled)
            }
        }
        .fixedSize(horizontal: false, vertical: true)
        .accessibilityElement(children: .combine)
        .accessibilityIdentifier("postgresTypeDDLChange")
    }

    static func labelDisplay(_ label: String) -> String {
        label.isEmpty ? "\"\" (empty label)" : String(reflecting: label)
    }
}
