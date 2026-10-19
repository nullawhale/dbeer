import SwiftUI

struct ConnectionEditorView: View {
    @ObservedObject var model: WorkspaceModel
    let connection: SavedConnection?
    let onClose: () -> Void
    private let onConnect: (@MainActor (UUID) async -> Void)?

    private var draftState: SwiftUI.State<ConnectionDraft>
    private var loadingPasswordState: SwiftUI.State<Bool>
    private var passwordLoadFailedState = SwiftUI.State(initialValue: false)
    private var passwordLoadAttemptState = SwiftUI.State(initialValue: UUID())
    private var validationState = SwiftUI.State<String?>(initialValue: nil)

    init(model: WorkspaceModel, connection: SavedConnection?,
         onConnect: (@MainActor (UUID) async -> Void)? = nil, onClose: @escaping () -> Void) {
        self.model = model
        self.connection = connection
        self.onClose = onClose
        self.onConnect = onConnect
        draftState = SwiftUI.State(initialValue: ConnectionDraft(connection: connection))
        loadingPasswordState = SwiftUI.State(initialValue: connection != nil)
    }

    private var draft: ConnectionDraft {
        get { draftState.wrappedValue }
        nonmutating set { draftState.wrappedValue = newValue }
    }

    private var isBusy: Bool { model.isSavingConnection || loadingPasswordState.wrappedValue }
    private var canSave: Bool { !isBusy && !passwordLoadFailedState.wrappedValue && draft.isValid }

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 12) {
                engineMenu
                Text(connection == nil ? "New Connection" : "Edit Connection")
                    .font(.title2.weight(.semibold))
                Spacer()
            }
            .padding(24)
            Divider()
            Form {
                Section {
                    TextField("Name", text: binding(\.name), prompt: Text("Local \(draft.engine.displayName)"))
                        .accessibilityIdentifier("connectionName")
                    if draft.name.count > 128 {
                        Text("Use a name with up to 128 characters.")
                            .font(.caption).foregroundStyle(.orange)
                    }
                }
                Section("Connection") {
                    TextField("Host", text: binding(\.host))
                        .accessibilityIdentifier("Host")
                    TextField("Port", text: binding(\.port))
                        .accessibilityIdentifier("Port")
                    if !draft.port.isEmpty, !draft.hasValidPort {
                        Text("Enter a port from 1 to 65535.")
                            .font(.caption).foregroundStyle(.orange)
                    }
                    TextField("Database", text: binding(\.database))
                        .accessibilityIdentifier("Database")
                    TextField("User", text: binding(\.user))
                        .accessibilityIdentifier("User")
                    SecureField("Password", text: binding(\.password))
                        .textContentType(.password)
                        .accessibilityIdentifier("password")
                    if loadingPasswordState.wrappedValue {
                        HStack(spacing: 8) {
                            ProgressView().controlSize(.small)
                            Text("Reading saved password…")
                        }
                        .font(.caption).appSecondaryText()
                    } else if passwordLoadFailedState.wrappedValue {
                        Button("Retry Reading Saved Password") {
                            passwordLoadAttemptState.wrappedValue = UUID()
                        }.controlHover()
                        .connectionButtonFocus()
                        .accessibilityIdentifier("retryConnectionPassword")
                    } else {
                        Label("Passwords are saved in macOS Keychain", systemImage: "key")
                            .font(.caption).appSecondaryText()
                    }
                }
                Section("Security") {
                    Picker("TLS mode", selection: binding(\.sslMode)) {
                        ForEach(draft.engine.sslModes, id: \.self) { mode in
                            Text(mode).tag(mode)
                        }
                    }
                    // Leave room for the native 20 pt bezel and the Form's
                    // baseline offset instead of clipping it to the text row.
                    .frame(minHeight: 24)
                    .controlHover()
                    .connectionButtonFocus()
                    .accessibilityIdentifier("sslMode")
                    TextField("Trusted CA file", text: binding(\.sslRootCert), prompt: Text("Optional path to a PEM file"))
                        .accessibilityIdentifier("trustedCAFile")
                    if draft.sslMode == "disable" {
                        Text("TLS is disabled. Use this mode for a local test database.")
                            .font(.caption).appSecondaryText()
                    }
                }
                if connection?.id == model.activeConnectionId, connection != nil {
                    Text("Changes apply the next time you connect.")
                        .font(.caption).appSecondaryText()
                }
            }
            .formStyle(.grouped)
            .appFormSurface()
            .disabled(isBusy)

            if let error = validationState.wrappedValue ?? model.connectionsError {
                Label(error, systemImage: "exclamationmark.triangle")
                    .font(.callout).foregroundStyle(.orange)
                    .textSelection(.enabled)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.horizontal, 24).padding(.bottom, 16)
                    .accessibilityIdentifier("connectionEditorError")
            }
            Divider()
            HStack(spacing: 10) {
                Button("Cancel", action: close).controlHover()
                    .connectionButtonFocus()
                    .keyboardShortcut(.cancelAction)
                    .disabled(model.isSavingConnection)
                    .accessibilityIdentifier("cancelConnectionEditor")
                Spacer()
                if onConnect != nil || model.canConnect {
                    Button("Save and Connect") { save(connectAfterSaving: true) }.controlHover()
                        .connectionButtonFocus()
                        .disabled(!canSave)
                        .accessibilityIdentifier("saveAndConnect")
                }
                Button("Save") { save(connectAfterSaving: false) }.controlHover()
                    .buttonStyle(.borderedProminent)
                    .connectionButtonFocus()
                    .keyboardShortcut(.defaultAction)
                    .disabled(!canSave)
                    .accessibilityIdentifier("saveConnection")
            }
            .padding(20)
        }
        .frame(width: 520, height: 680)
        .tint(AppPalette.accent)
        .focusEffectDisabled()
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("connectionEditor")
        .interactiveDismissDisabled(model.isSavingConnection)
        .task(id: passwordLoadAttemptState.wrappedValue) {
            model.dismissConnectionsError()
            if let connection {
                loadingPasswordState.wrappedValue = true
                let password = await model.passwordForConnection(connection.id)
                guard !Task.isCancelled else { return }
                if let password {
                    draft.password = password
                    passwordLoadFailedState.wrappedValue = false
                } else { passwordLoadFailedState.wrappedValue = true }
            }
            loadingPasswordState.wrappedValue = false
        }
        .onDisappear { draft.password = "" }
    }

    private var engineMenu: some View {
        Menu {
            Picker("Database engine", selection: Binding(get: { draft.engine }, set: {
                draft.selectEngine($0)
                validationState.wrappedValue = nil
            })) {
                ForEach(DatabaseEngine.allCases) { engine in
                    Text(engine.displayName).tag(engine)
                }
            }.pickerStyle(.inline)
        } label: {
            DatabaseEngineIcon(engine: draft.engine, size: 28, contentInset: 4)
                .frame(width: 40, height: 40).contentShape(Rectangle())
        }
        .menuStyle(.borderlessButton).menuIndicator(.visible).fixedSize()
        .buttonStyle(.plain)
        .tint(.secondary)
        .controlHover().focusEffectDisabled()
        .disabled(isBusy)
        .accessibilityLabel("Database engine")
        .accessibilityValue(draft.engine.displayName)
        .accessibilityIdentifier("connectionEngine")
        .help("Choose database engine")
    }

    private func binding(_ keyPath: WritableKeyPath<ConnectionDraft, String>) -> Binding<String> {
        Binding(get: { draft[keyPath: keyPath] }, set: { value in
            draft[keyPath: keyPath] = value
            validationState.wrappedValue = nil
        })
    }

    private func save(connectAfterSaving: Bool) {
        guard canSave, let settings = draft.settings else {
            validationState.wrappedValue = "Enter a name, host, database, user, and a port from 1 to 65535."
            return
        }
        let name = draft.name.trimmingCharacters(in: .whitespacesAndNewlines)
        Task {
            let saved = await model.saveConnection(name: name, settings: settings, id: connection?.id)
            guard saved else { return }
            let savedId = model.selectedConnectionId
            close()
            if connectAfterSaving, let savedId {
                if let onConnect { await onConnect(savedId) }
                else { await model.connectSavedConnection(savedId) }
            }
        }
    }

    private func close() {
        draft.password = ""
        onClose()
    }
}

struct ConnectionDraft {
    var name: String
    var engine: DatabaseEngine
    var host: String
    var port: String
    var database: String
    var user: String
    var password = ""
    var sslMode: String
    var sslRootCert: String

    init(connection: SavedConnection?) {
        name = connection?.name ?? ""
        engine = connection?.engine ?? .postgresql
        host = connection?.host ?? "localhost"
        port = connection.map { String($0.port) } ?? String(engine.defaultPort)
        database = connection?.database ?? engine.defaultDatabase
        user = connection?.user ?? engine.defaultUser
        sslMode = connection?.sslMode ?? "verify-full"
        sslRootCert = connection?.sslRootCert ?? ""
    }

    mutating func selectEngine(_ next: DatabaseEngine) {
        guard next != engine else { return }
        if port == String(engine.defaultPort) { port = String(next.defaultPort) }
        if database == engine.defaultDatabase { database = next.defaultDatabase }
        if user == engine.defaultUser { user = next.defaultUser }
        if !next.sslModes.contains(sslMode) { sslMode = "verify-full" }
        engine = next
    }

    var isValid: Bool {
        let cleanName = name.trimmingCharacters(in: .whitespacesAndNewlines)
        return settings != nil && !cleanName.isEmpty && cleanName.count <= 128
    }

    var hasValidPort: Bool {
        guard let value = Int(port.trimmingCharacters(in: .whitespacesAndNewlines)) else { return false }
        return (1...65_535).contains(value)
    }

    var settings: ConnectionSettings? {
        let cleanedHost = host.trimmingCharacters(in: .whitespacesAndNewlines)
        let cleanedDatabase = database.trimmingCharacters(in: .whitespacesAndNewlines)
        let cleanedUser = user.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let portNumber = Int(port.trimmingCharacters(in: .whitespacesAndNewlines)),
              (1...65_535).contains(portNumber), !cleanedHost.isEmpty, !cleanedDatabase.isEmpty,
              !cleanedUser.isEmpty, engine.sslModes.contains(sslMode) else { return nil }
        let rootCert = sslRootCert.trimmingCharacters(in: .whitespacesAndNewlines)
        return ConnectionSettings(host: cleanedHost, port: portNumber, database: cleanedDatabase,
            user: cleanedUser, password: password, sslMode: sslMode,
            sslRootCert: rootCert.isEmpty ? nil : rootCert, engine: engine)
    }
}
