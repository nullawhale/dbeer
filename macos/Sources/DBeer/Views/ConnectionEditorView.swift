import SwiftUI
import AppKit

struct ConnectionEditorView: View {
    @ObservedObject var model: WorkspaceModel
    let connection: SavedConnection?
    let onClose: () -> Void
    private let onConnect: (@MainActor (UUID, SSHSettings?) async -> Void)?

    private var draftState: SwiftUI.State<ConnectionDraft>
    private var loadingPasswordState: SwiftUI.State<Bool>
    private var passwordLoadFailedState = SwiftUI.State(initialValue: false)
    private var passwordLoadAttemptState = SwiftUI.State(initialValue: UUID())
    private var validationState = SwiftUI.State<String?>(initialValue: nil)

    init(model: WorkspaceModel, connection: SavedConnection?,
         onConnect: (@MainActor (UUID, SSHSettings?) async -> Void)? = nil, onClose: @escaping () -> Void) {
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
                    TextField(draft.engine == .cassandra ? "Contact points" : "Host", text: binding(\.host))
                        .accessibilityIdentifier("Host")
                    TextField("Port", text: binding(\.port))
                        .accessibilityIdentifier("Port")
                    if !draft.port.isEmpty, !draft.hasValidPort {
                        Text("Enter a port from 1 to 65535.")
                            .font(.caption).foregroundStyle(.orange)
                    }
                    TextField(draft.engine == .cassandra ? "Keyspace (optional)" : "Database", text: binding(\.database))
                        .accessibilityIdentifier("Database")
                    if draft.engine == .cassandra {
                        TextField("Local datacenter (optional)", text: binding(\.localDatacenter))
                            .accessibilityIdentifier("localDatacenter")
                        Picker("Consistency", selection: binding(\.consistency)) {
                            ForEach(CassandraSettings.consistencyLevels, id: \.self) { Text($0).tag($0) }
                        }.frame(minHeight: 24).controlHover().connectionButtonFocus()
                            .accessibilityIdentifier("cassandraConsistency")
                        Text("Separate contact points with commas. Leave user and password empty for a cluster without authentication.")
                            .font(.caption).appSecondaryText()
                    }
                    TextField(draft.engine == .cassandra ? "User (optional)" : "User", text: binding(\.user))
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
                    Picker("Environment", selection: Binding(get: { draft.policy.environment }, set: { draft.policy.environment = $0 })) {
                        ForEach(ConnectionEnvironment.allCases) { environment in
                            Text(environment.label).tag(environment)
                        }
                    }.frame(minHeight: 24).controlHover().connectionButtonFocus().accessibilityIdentifier("connectionEnvironment")
                    Toggle("Readonly", isOn: Binding(get: { draft.policy.readOnly }, set: { draft.policy.readOnly = $0 }))
                        .padding(.horizontal, 6)
                        .frame(minHeight: 24).controlHover().accessibilityIdentifier("connectionReadOnly")
                    Text(draft.engine == .cassandra ? "Local readonly blocks evaluated writes and unknown CQL in DBeer. It does not enable a server read mode. Use a server role with restricted permissions for strict protection." : "Readonly blocks evaluated writes and unknown SQL, and enables server read mode. Functions and database objects can hide side effects. Use restricted database privileges for strict protection.")
                        .font(.caption).appSecondaryText()
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
                Section("SSH Tunnel") {
                    Toggle("Connect through SSH", isOn: Binding(get: { draft.sshEnabled }, set: { draft.sshEnabled = $0 }))
                        .padding(.horizontal, 6).frame(minHeight: 24).controlHover().connectionButtonFocus()
                        .accessibilityIdentifier("sshEnabled")
                    if draft.sshEnabled {
                        TextField("SSH server", text: binding(\.sshHost)).accessibilityIdentifier("sshHost")
                        TextField("SSH port", text: binding(\.sshPort)).accessibilityIdentifier("sshPort")
                        TextField("SSH user", text: binding(\.sshUser)).accessibilityIdentifier("sshUser")
                        Picker("Authentication", selection: Binding(get: { draft.sshAuthMethod }, set: { draft.sshAuthMethod = $0 })) {
                            ForEach(SSHConfiguration.Authentication.allCases) { Text($0.label).tag($0) }
                        }.controlHover().connectionButtonFocus().accessibilityIdentifier("sshAuthentication")
                        if draft.sshAuthMethod == .privateKey {
                            HStack {
                                TextField("Private key", text: binding(\.sshIdentityFile)).accessibilityIdentifier("sshIdentityFile")
                                Button("Choose…") { chooseSSHKey() }.controlHover().connectionButtonFocus()
                                    .accessibilityIdentifier("chooseSSHKey")
                            }
                            SecureField("Key passphrase (optional)", text: binding(\.sshPassphrase)).accessibilityIdentifier("sshPassphrase")
                        } else if draft.sshAuthMethod == .password {
                            SecureField("SSH password", text: binding(\.sshPassword)).accessibilityIdentifier("sshPassword")
                        }
                        if draft.sshAuthMethod != .agent {
                            Toggle("Remember SSH credential in Keychain", isOn: Binding(get: { draft.rememberSSHSecret }, set: { draft.rememberSSHSecret = $0 }))
                                .padding(.horizontal, 6).frame(minHeight: 24).controlHover().connectionButtonFocus()
                                .accessibilityIdentifier("rememberSSHSecret")
                        }
                        if draft.engine == .cassandra {
                            Text("Cassandra over SSH requires numeric IP contact points; all discovered nodes also use the tunnel.").font(.caption).appSecondaryText()
                        }
                        Text("Database addresses are reached from the SSH server. Database TLS settings still verify the database identity. SSH configuration aliases and jump hosts are not supported.")
                            .font(.caption).appSecondaryText()
                        if draft.sshAuthMethod == .privateKey, !draft.sshIdentityFile.isEmpty,
                           !ProfileTransfer.isLocalReadableCA(draft.sshIdentityFile) {
                            Text("Choose a readable private key on this Mac.").font(.caption).foregroundStyle(.orange)
                        }
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
        .frame(width: 520, height: 780)
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
                    if connection.ssh?.authMethod == .password {
                        let stored = await model.sshSecretForConnection(connection.id, purpose: .sshPassword)
                        draft.sshPassword = stored ?? ""
                        draft.rememberSSHSecret = stored != nil
                    } else if connection.ssh?.authMethod == .privateKey {
                        let stored = await model.sshSecretForConnection(connection.id, purpose: .sshPassphrase)
                        draft.sshPassphrase = stored ?? ""
                        draft.rememberSSHSecret = stored != nil
                    }
                    passwordLoadFailedState.wrappedValue = model.connectionsError != nil
                } else { passwordLoadFailedState.wrappedValue = true }
            }
            loadingPasswordState.wrappedValue = false
        }
        .onDisappear { clearSecrets() }
    }

    private var engineMenu: some View {
        Menu {
            Picker("Database engine", selection: Binding(get: { draft.engine }, set: {
                draft.selectEngine($0)
                validationState.wrappedValue = nil
            })) {
                ForEach(DatabaseEngine.availableCases) { engine in
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
            validationState.wrappedValue = draft.engine == .cassandra ? "Enter a name, contact points, a valid port, and supported consistency. Authentication and keyspace are optional." : "Enter a name, host, database, user, and a port from 1 to 65535."
            return
        }
        let name = draft.name.trimmingCharacters(in: .whitespacesAndNewlines)
        Task {
            let saved = await model.saveConnection(name: name, settings: settings, id: connection?.id, rememberSSHSecret: draft.rememberSSHSecret)
            guard saved else { return }
            let savedId = model.selectedConnectionId
            close()
            if connectAfterSaving, let savedId {
                var snapshot = settings.ssh
                snapshot?.profileId = savedId.uuidString
                if let onConnect { await onConnect(savedId, snapshot) }
                else { await model.connectSavedConnection(savedId, sshSnapshot: snapshot) }
            }
        }
    }

    private func chooseSSHKey() {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = false
        panel.allowsMultipleSelection = false
        panel.message = "Choose an SSH private key. DBeer keeps the key in its existing location."
        guard panel.runModal() == .OK, let url = panel.url else { return }
        draft.sshIdentityFile = url.path
    }

    private func clearSecrets() {
        draft.password = ""
        draft.sshPassword = ""
        draft.sshPassphrase = ""
    }

    private func close() {
        clearSecrets()
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
    var policy: ExecutionPolicy
    var localDatacenter: String
    var consistency: String
    var sshEnabled = false
    var sshHost = ""
    var sshPort = "22"
    var sshUser = ""
    var sshAuthMethod: SSHConfiguration.Authentication = .agent
    var sshIdentityFile = ""
    var sshPassword = ""
    var sshPassphrase = ""
    var rememberSSHSecret = true
    private var sshProfileId: UUID

    init(connection: SavedConnection?) {
        sshProfileId = connection?.id ?? UUID()
        sshEnabled = connection?.ssh != nil
        sshHost = connection?.ssh?.host ?? ""
        sshPort = String(connection?.ssh?.port ?? 22)
        sshUser = connection?.ssh?.user ?? ""
        sshAuthMethod = connection?.ssh?.authMethod ?? .agent
        sshIdentityFile = connection?.ssh?.identityFile ?? ""
        name = connection?.name ?? ""
        engine = connection?.engine ?? .postgresql
        host = connection?.contactPoints?.joined(separator: ", ") ?? connection?.host ?? "localhost"
        port = connection.map { String($0.port) } ?? String(engine.defaultPort)
        database = connection?.database ?? engine.defaultDatabase
        user = connection?.user ?? engine.defaultUser
        sslMode = connection?.sslMode ?? "verify-full"
        sslRootCert = connection?.sslRootCert ?? ""
        policy = connection?.policy ?? ExecutionPolicy()
        localDatacenter = connection?.localDatacenter ?? ""
        consistency = connection?.consistency ?? "LOCAL_QUORUM"
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
              (1...65_535).contains(portNumber), !cleanedHost.isEmpty, (engine == .cassandra || !cleanedDatabase.isEmpty),
              (engine == .cassandra || !cleanedUser.isEmpty), engine.sslModes.contains(sslMode) else { return nil }
        var ssh: SSHSettings?
        if sshEnabled {
            guard let port = Int(sshPort.trimmingCharacters(in: .whitespacesAndNewlines)) else { return nil }
            let configuration = SSHConfiguration(host: sshHost.trimmingCharacters(in: .whitespacesAndNewlines), port: port,
                user: sshUser.trimmingCharacters(in: .whitespacesAndNewlines), authMethod: sshAuthMethod,
                identityFile: sshAuthMethod == .privateKey ? sshIdentityFile : nil)
            guard configuration.isValid else { return nil }
            if sshAuthMethod == .privateKey, !ProfileTransfer.isLocalReadableCA(sshIdentityFile) { return nil }
            ssh = configuration.runtime(profileId: sshProfileId,
                password: sshAuthMethod == .password ? sshPassword : nil,
                passphrase: sshAuthMethod == .privateKey ? sshPassphrase : nil)
        }
        let rootCert = sslRootCert.trimmingCharacters(in: .whitespacesAndNewlines)
        let points = engine == .cassandra ? CassandraSettings.contactPoints(cleanedHost) : []
        let settings = ConnectionSettings(host: points.first ?? cleanedHost, port: portNumber, database: cleanedDatabase,
            user: cleanedUser, password: password, sslMode: sslMode,
            sslRootCert: rootCert.isEmpty ? nil : rootCert, engine: engine, policy: policy,
            contactPoints: engine == .cassandra ? points : nil,
            localDatacenter: engine == .cassandra && !localDatacenter.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? localDatacenter.trimmingCharacters(in: .whitespacesAndNewlines) : nil,
            consistency: engine == .cassandra ? consistency : nil, ssh: ssh)
        return settings.hasValidNativeFields ? settings : nil
    }
}
