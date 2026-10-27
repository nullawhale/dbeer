import SwiftUI
import AppKit

struct ConnectionEditorView: View {
    @ObservedObject var model: WorkspaceModel
    private let request: ConnectionEditorRequest
    let onClose: () -> Void
    private let onConnect: (@MainActor (UUID, SSHSettings?) async -> Void)?

    private enum Tab { case general, ssh, tls, options }

    @StateObject private var tester = ConnectionTester()
    private var selectedTab = SwiftUI.State(initialValue: Tab.general)
    private var urlInputState: SwiftUI.State<String>
    private var urlNeedsApplyState = SwiftUI.State(initialValue: false)
    private var urlErrorState = SwiftUI.State<String?>(initialValue: nil)
    private var draftState: SwiftUI.State<ConnectionDraft>
    private var loadingPasswordState: SwiftUI.State<Bool>
    private var passwordLoadFailedState = SwiftUI.State(initialValue: false)
    private var passwordLoadAttemptState = SwiftUI.State(initialValue: UUID())
    private var validationState = SwiftUI.State<String?>(initialValue: nil)

    init(model: WorkspaceModel, connection: SavedConnection?,
         onConnect: (@MainActor (UUID, SSHSettings?) async -> Void)? = nil, onClose: @escaping () -> Void) {
        self.init(model: model, request: connection.map(ConnectionEditorRequest.edit) ?? .new,
            onConnect: onConnect, onClose: onClose)
    }

    init(model: WorkspaceModel, request: ConnectionEditorRequest,
         onConnect: (@MainActor (UUID, SSHSettings?) async -> Void)? = nil, onClose: @escaping () -> Void) {
        self.model = model
        self.request = request
        self.onClose = onClose
        self.onConnect = onConnect
        let draft = request.makeDraft()
        draftState = SwiftUI.State(initialValue: draft)
        urlInputState = SwiftUI.State(initialValue: draft.connectionURL ?? "")
        loadingPasswordState = SwiftUI.State(initialValue: request.credentialSource != nil)
    }

    private var connection: SavedConnection? { request.existingConnection }

    private var draft: ConnectionDraft {
        get { draftState.wrappedValue }
        nonmutating set { draftState.wrappedValue = newValue }
    }

    private var isBusy: Bool { model.isSavingConnection || loadingPasswordState.wrappedValue || tester.isTesting }
    private var canSave: Bool { !isBusy && !passwordLoadFailedState.wrappedValue && !urlNeedsApplyState.wrappedValue && draft.isValid }

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 12) {
                if draft.allowsEngineSelection {
                    engineMenu
                } else {
                    DatabaseEngineIcon(engine: draft.engine, size: 28, contentInset: 4)
                        .frame(width: 40, height: 40)
                        .help(draft.engine.displayName)
                }
                VStack(alignment: .leading, spacing: 2) {
                    Text(connection == nil ? "New Connection" : "Edit Connection")
                        .font(.title2.weight(.semibold))
                    Text(draft.engine.displayName).font(.caption).appSecondaryText()
                }
                Spacer()
            }
            .padding(24)
            Divider()
            HStack(spacing: 16) {
                Text("Name").frame(width: 70, alignment: .trailing)
                TextField("Connection name", text: binding(\.name), prompt: Text("Local \(draft.engine.displayName)"))
                    .textFieldStyle(.roundedBorder)
                    .accessibilityIdentifier("connectionName")
            }
            .padding(.horizontal, 24).padding(.vertical, 16)
            .disabled(isBusy)
            if draft.name.count > 128 {
                Text("Use a name with up to 128 characters.")
                    .font(.caption).foregroundStyle(.orange)
            }
            TabView(selection: selectedTab.projectedValue) {
                generalTab.tabItem { Text("General") }.tag(Tab.general)
                sshTab.tabItem { Text("SSH") }.tag(Tab.ssh)
                tlsTab.tabItem { Text("TLS") }.tag(Tab.tls)
                optionsTab.tabItem { Text("Options") }.tag(Tab.options)
            }
            .padding(.horizontal, 20).padding(.bottom, 12)
            .accessibilityIdentifier("connectionTabs")

            testFeedback
            if connection?.id == model.activeConnectionId, connection != nil {
                Text("Changes apply the next time you connect.")
                    .font(.caption).appSecondaryText()
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.horizontal, 24).padding(.bottom, 12)
            }

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
                Button("Test Connection") { testConnection() }.controlHover()
                    .connectionButtonFocus()
                    .disabled(isBusy || passwordLoadFailedState.wrappedValue || urlNeedsApplyState.wrappedValue || draft.settings == nil)
                    .accessibilityIdentifier("testConnection")
                if tester.isTesting {
                    Button("Stop Test") { tester.cancel() }.controlHover()
                        .connectionButtonFocus()
                        .disabled(tester.state == .cancelling)
                        .accessibilityIdentifier("stopConnectionTest")
                }
                Spacer()
                Button("Cancel", action: close).controlHover()
                    .connectionButtonFocus()
                    .keyboardShortcut(.cancelAction)
                    .disabled(model.isSavingConnection)
                    .accessibilityIdentifier("cancelConnectionEditor")
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
        .frame(width: 820, height: 620)
        .tint(AppPalette.accent)
        .focusEffectDisabled()
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("connectionEditor")
        .interactiveDismissDisabled(model.isSavingConnection)
        .task(id: passwordLoadAttemptState.wrappedValue) {
            model.dismissConnectionsError()
            if let connection = request.credentialSource {
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
        .onChange(of: draft.settings) { _, _ in tester.reset() }
        .onChange(of: draft.connectionURL) { _, value in
            if !urlNeedsApplyState.wrappedValue { urlInputState.wrappedValue = value ?? "" }
        }
        .onChange(of: draft.engine) { _, _ in resetURL() }
        .onDisappear { tester.cancel(); clearSecrets() }
    }

    private var generalTab: some View {
        Form {
            Section("Connection") {
                LabeledContent([.cassandra, .mongodb].contains(draft.engine) ? "Contact points" : "Host") {
                    HStack(spacing: 12) {
                        TextField("Host", text: binding(\.host)).labelsHidden()
                            .accessibilityLabel([.cassandra, .mongodb].contains(draft.engine) ? "Contact points" : "Host")
                            .accessibilityIdentifier("Host")
                        Text("Port")
                        TextField("Port", text: binding(\.port)).labelsHidden()
                            .frame(width: 80).accessibilityIdentifier("Port")
                    }
                }
                if !draft.port.isEmpty, !draft.hasValidPort {
                    Text("Enter a port from 1 to 65535.").font(.caption).foregroundStyle(.orange)
                }
                TextField(draft.engine == .cassandra ? "Keyspace (optional)" : draft.engine == .mongodb ? "Database (optional)" : "Database", text: binding(\.database))
                    .accessibilityIdentifier("Database")
                if [.postgresql, .mysql].contains(draft.engine) {
                    LabeledContent("URL") {
                        HStack(spacing: 8) {
                            TextField("Connection URL", text: Binding(get: { urlInputState.wrappedValue }, set: { value in
                                urlInputState.wrappedValue = value
                                urlNeedsApplyState.wrappedValue = !value.isEmpty && value != draft.connectionURL
                                urlErrorState.wrappedValue = nil
                            }))
                            .multilineTextAlignment(.leading).labelsHidden().autocorrectionDisabled()
                            .onSubmit { if urlNeedsApplyState.wrappedValue { applyURL() } }
                            .accessibilityIdentifier("connectionURL")
                            Button("Use URL", action: applyURL).controlHover().connectionButtonFocus()
                                .disabled(urlInputState.wrappedValue.isEmpty)
                                .accessibilityIdentifier("applyConnectionURL")
                            if urlNeedsApplyState.wrappedValue {
                                Button("Reset", action: resetURL).controlHover().connectionButtonFocus()
                                    .accessibilityIdentifier("resetConnectionURL")
                            }
                        }
                    }
                    if let error = urlErrorState.wrappedValue {
                        Text(error).font(.caption).foregroundStyle(.orange)
                            .accessibilityIdentifier("connectionURLError")
                    } else {
                        Text(urlNeedsApplyState.wrappedValue
                            ? "Apply or reset the URL before saving or testing."
                            : "Use URL fills the fields. Omitted credentials and TLS options keep their current values. Passwords are excluded from the URL preview.")
                            .font(.caption).appSecondaryText()
                    }
                }
                if draft.engine == .cassandra {
                    Text("Separate contact points with commas. Authentication and keyspace are optional.")
                        .font(.caption).appSecondaryText()
                }
                if draft.engine == .mongodb {
                    Text("Separate seed hosts with commas; they use the same port. Database and authentication are optional. Use JSON find requests or aggregation pipelines in the script editor.")
                        .font(.caption).appSecondaryText()
                }
            }
            Section("Authentication") {
                TextField([.cassandra, .mongodb].contains(draft.engine) ? "User (optional)" : "User", text: binding(\.user))
                    .accessibilityIdentifier("User")
                Picker("Password source", selection: valueBinding(\.usesPasswordCommand)) {
                    Text("macOS Keychain").tag(false)
                    Text("CLI command").tag(true)
                }.accessibilityIdentifier("passwordSource")
                if draft.usesPasswordCommand {
                    TextField("Executable (absolute path)", text: binding(\.passwordExecutable))
                        .autocorrectionDisabled().accessibilityIdentifier("passwordExecutable")
                    TextField("Arguments (JSON array)", text: binding(\.passwordArguments), axis: .vertical)
                        .lineLimit(2...4).autocorrectionDisabled()
                        .accessibilityIdentifier("passwordArguments")
                    Text("Runs for each new database connection, including service connections and Apply. Arguments are passed literally, without a shell. Timeout: 15 seconds; stdout limit: 64 KiB. Return one nonempty password, optionally followed by a newline.")
                        .font(.caption).appSecondaryText()
                    if draft.passwordCommand == nil {
                        Text("Enter an absolute executable path and a JSON array of up to 128 string arguments, for example [\"token\", \"--database\", \"app\"].")
                            .font(.caption).foregroundStyle(.orange)
                    }
                } else {
                    SecureField("Password", text: binding(\.password))
                        .textContentType(.password).accessibilityIdentifier("password")
                }
                if loadingPasswordState.wrappedValue {
                    HStack(spacing: 8) {
                        ProgressView().controlSize(.small)
                        Text("Reading saved password…")
                    }.font(.caption).appSecondaryText()
                } else if passwordLoadFailedState.wrappedValue {
                    Button("Retry Reading Saved Password") { passwordLoadAttemptState.wrappedValue = UUID() }
                        .controlHover().connectionButtonFocus().accessibilityIdentifier("retryConnectionPassword")
                } else if !draft.usesPasswordCommand {
                    Label("Passwords are saved in macOS Keychain", systemImage: "key")
                        .font(.caption).appSecondaryText()
                } else {
                    Text("Only the command configuration is saved locally. Generated passwords are never saved. Configure the command again after importing profiles.")
                        .font(.caption).appSecondaryText()
                }
            }
        }
        .formStyle(.grouped).appFormSurface().disabled(isBusy)
    }

    private var sshTab: some View {
        Form {
            Section {
                Toggle("Connect through SSH", isOn: valueBinding(\.sshEnabled))
                    .padding(.horizontal, 6).frame(minHeight: 24).controlHover().connectionButtonFocus()
                    .accessibilityIdentifier("sshEnabled")
            }
            if draft.sshEnabled {
                Section("SSH Tunnel") {
                    LabeledContent("SSH server") {
                        HStack(spacing: 12) {
                            TextField("SSH server", text: binding(\.sshHost)).labelsHidden().accessibilityIdentifier("sshHost")
                            if draft.sshAuthMethod != .openSSH {
                                Text("Port")
                                TextField("SSH port", text: binding(\.sshPort)).labelsHidden()
                                    .frame(width: 80).accessibilityIdentifier("sshPort")
                            }
                        }
                    }
                    if draft.sshAuthMethod != .openSSH {
                        TextField("SSH user", text: binding(\.sshUser)).accessibilityIdentifier("sshUser")
                    }
                    Picker("Authentication", selection: valueBinding(\.sshAuthMethod)) {
                        ForEach(SSHConfiguration.Authentication.allCases) { Text($0.label).tag($0) }
                    }.frame(minHeight: 24).controlHover().connectionButtonFocus().accessibilityIdentifier("sshAuthentication")
                    if draft.sshAuthMethod == .openSSH {
                        LabeledContent("Configuration file") {
                            HStack {
                                TextField("Default OpenSSH configuration", text: binding(\.sshConfigFile))
                                    .labelsHidden().accessibilityIdentifier("sshConfigFile")
                                Button("Choose…") { chooseSSHConfiguration() }.controlHover().connectionButtonFocus()
                            }
                        }
                        Text("Enter a Host alias above. OpenSSH supplies the server, port, user, keys and jump route. Leave the file empty to use this Mac's default configuration. Keys must be usable without a password prompt, for example through ssh-agent. ProxyCommand and Match exec can run local programs when you connect or test the connection.")
                            .font(.caption).appSecondaryText()
                    } else if draft.sshAuthMethod == .privateKey {
                        LabeledContent("Private key") {
                            HStack {
                                TextField("Private key", text: binding(\.sshIdentityFile)).labelsHidden().accessibilityIdentifier("sshIdentityFile")
                                Button("Choose…") { chooseSSHKey() }.controlHover().connectionButtonFocus()
                                    .accessibilityIdentifier("chooseSSHKey")
                            }
                        }
                        SecureField("Key passphrase (optional)", text: binding(\.sshPassphrase)).accessibilityIdentifier("sshPassphrase")
                        if !draft.sshIdentityFile.isEmpty, !ProfileTransfer.isLocalReadableCA(draft.sshIdentityFile) {
                            Text("Choose a readable private key on this Mac.").font(.caption).foregroundStyle(.orange)
                        }
                    } else if draft.sshAuthMethod == .password {
                        SecureField("SSH password", text: binding(\.sshPassword)).accessibilityIdentifier("sshPassword")
                    }
                    if draft.sshAuthMethod == .privateKey || draft.sshAuthMethod == .password {
                        Toggle("Remember SSH credential in Keychain", isOn: valueBinding(\.rememberSSHSecret))
                            .padding(.horizontal, 6).frame(minHeight: 24).controlHover().connectionButtonFocus()
                            .accessibilityIdentifier("rememberSSHSecret")
                    }
                }
            }
            Section {
                Text("Database addresses are reached from the final SSH server. Database TLS settings still verify the database identity. OpenSSH Configuration supports aliases, Include, ProxyJump and ProxyCommand.")
                    .font(.caption).appSecondaryText()
                if draft.engine == .cassandra {
                    Text("Cassandra over SSH requires numeric IP contact points; all discovered nodes also use the tunnel.")
                        .font(.caption).appSecondaryText()
                }
            }
        }
        .formStyle(.grouped).appFormSurface().disabled(isBusy)
    }

    private var tlsTab: some View {
        Form {
            Section("Database TLS") {
                Picker("TLS mode", selection: binding(\.sslMode)) {
                    ForEach(draft.engine.sslModes, id: \.self) { Text($0).tag($0) }
                }.frame(minHeight: 24).controlHover().connectionButtonFocus().accessibilityIdentifier("sslMode")
                LabeledContent("Trusted CA file") {
                    HStack {
                        TextField("Trusted CA file", text: binding(\.sslRootCert), prompt: Text("Optional path to a PEM file"))
                            .labelsHidden().accessibilityIdentifier("trustedCAFile")
                        Button("Choose…") { chooseCAFile() }.controlHover().connectionButtonFocus()
                            .accessibilityIdentifier("chooseTrustedCAFile")
                    }
                }
                if draft.sslMode == "disable" {
                    Text("TLS is disabled. Use this mode for a local test database.")
                        .font(.caption).appSecondaryText()
                } else {
                    Text("Database TLS is independent of SSH. Use verify-full to verify the certificate and database hostname.")
                        .font(.caption).appSecondaryText()
                }
            }
        }
        .formStyle(.grouped).appFormSurface().disabled(isBusy)
    }

    private var optionsTab: some View {
        Form {
            Section("Execution Safety") {
                Picker("Environment", selection: valueBinding(\.policy.environment)) {
                    ForEach(ConnectionEnvironment.allCases) { Text($0.label).tag($0) }
                }.frame(minHeight: 24).controlHover().connectionButtonFocus().accessibilityIdentifier("connectionEnvironment")
                Toggle("Readonly", isOn: valueBinding(\.policy.readOnly))
                    .padding(.horizontal, 6).frame(minHeight: 24).controlHover().accessibilityIdentifier("connectionReadOnly")
                Text(draft.engine == .mongodb ? "Local readonly blocks output pipelines and unknown operations in DBeer. Use a MongoDB role with restricted permissions for server protection." : draft.engine == .cassandra ? "Local readonly blocks evaluated writes and unknown CQL in DBeer. It does not enable a server read mode. Use a server role with restricted permissions for strict protection." : "Readonly blocks evaluated writes and unknown SQL, and enables server read mode. Functions and database objects can hide side effects. Use restricted database privileges for strict protection.")
                    .font(.caption).appSecondaryText()
            }
            if draft.engine == .cassandra {
                Section("Cassandra") {
                    TextField("Local datacenter (optional)", text: binding(\.localDatacenter)).accessibilityIdentifier("localDatacenter")
                    Picker("Consistency", selection: binding(\.consistency)) {
                        ForEach(CassandraSettings.consistencyLevels, id: \.self) { Text($0).tag($0) }
                    }.frame(minHeight: 24).controlHover().connectionButtonFocus().accessibilityIdentifier("cassandraConsistency")
                }
            }
            if draft.engine == .mongodb {
                Section("MongoDB") {
                    TextField("Authentication database", text: binding(\.mongoAuthSource))
                    Picker("Authentication mechanism", selection: binding(\.mongoAuthMechanism)) {
                        Text("Automatic SCRAM").tag("")
                        Text("SCRAM-SHA-256").tag("SCRAM-SHA-256")
                        Text("SCRAM-SHA-1").tag("SCRAM-SHA-1")
                    }.controlHover()
                    TextField("Replica set (optional)", text: binding(\.mongoReplicaSet))
                    Toggle("Direct connection", isOn: valueBinding(\.mongoDirectConnection)).controlHover()
                    Text("SSH requires a direct connection to one host. TLS verifies the database host name.")
                        .font(.caption).appSecondaryText()
                }
            }
        }
        .formStyle(.grouped).appFormSurface().disabled(isBusy)
    }

    @ViewBuilder private var testFeedback: some View {
        if tester.state != .idle {
            HStack(alignment: .top, spacing: 8) {
                if tester.isTesting { ProgressView().controlSize(.small) }
                switch tester.state {
                case .idle: EmptyView()
                case .testing: Text("Testing connection…")
                case .cancelling: Text("Stopping connection test…")
                case .succeeded: Label("Connection successful. Test session closed.", systemImage: "checkmark.circle.fill").foregroundStyle(.green)
                case .cancelled: Text("Connection test cancelled.").appSecondaryText()
                case .failed(let message): Label(message, systemImage: "exclamationmark.triangle").foregroundStyle(.orange).textSelection(.enabled)
                }
            }
            .font(.callout).frame(maxWidth: .infinity, alignment: .leading)
            .padding(.horizontal, 24).padding(.bottom, 12)
            .accessibilityIdentifier("connectionTestResult")
        }
    }

    private func applyURL() {
        guard !isBusy else { return }
        do {
            try draft.applyConnectionURL(urlInputState.wrappedValue)
            resetURL()
            tester.reset()
            validationState.wrappedValue = nil
        } catch {
            urlNeedsApplyState.wrappedValue = true
            urlErrorState.wrappedValue = error.localizedDescription
        }
    }

    private func resetURL() {
        urlInputState.wrappedValue = draft.connectionURL ?? ""
        urlNeedsApplyState.wrappedValue = false
        urlErrorState.wrappedValue = nil
    }

    private func testConnection() {
        guard !isBusy, !passwordLoadFailedState.wrappedValue, !urlNeedsApplyState.wrappedValue, let settings = draft.settings else { return }
        validationState.wrappedValue = nil
        Task { await tester.test(settings) }
    }

    private func valueBinding<Value>(_ keyPath: WritableKeyPath<ConnectionDraft, Value>) -> Binding<Value> {
        Binding(get: { draft[keyPath: keyPath] }, set: {
            draft[keyPath: keyPath] = $0
            validationState.wrappedValue = nil
        })
    }

    private func chooseCAFile() {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = false
        panel.allowsMultipleSelection = false
        panel.message = "Choose a trusted CA certificate in PEM format."
        guard panel.runModal() == .OK, let url = panel.url else { return }
        draft.sslRootCert = url.path
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

    private func chooseSSHConfiguration() {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = false
        panel.allowsMultipleSelection = false
        panel.message = "Choose a local OpenSSH configuration file."
        if panel.runModal() == .OK, let url = panel.url { draft.sshConfigFile = url.path }
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
        urlInputState.wrappedValue = ""
        draft.password = ""
        draft.sshPassword = ""
        draft.sshPassphrase = ""
    }

    private func close() {
        tester.cancel()
        clearSecrets()
        onClose()
    }
}

enum ConnectionEditorRequest {
    case new
    case edit(SavedConnection)
    case duplicate(SavedConnection)

    var existingConnection: SavedConnection? {
        if case .edit(let connection) = self { return connection }
        return nil
    }

    var credentialSource: SavedConnection? {
        switch self {
        case .new: nil
        case .edit(let connection), .duplicate(let connection): connection
        }
    }

    func makeDraft() -> ConnectionDraft {
        switch self {
        case .new: ConnectionDraft(connection: nil)
        case .edit(let connection): ConnectionDraft(connection: connection)
        case .duplicate(let connection): ConnectionDraft(duplicating: connection)
        }
    }
}

struct ConnectionDraft {
    var name: String
    private(set) var engine: DatabaseEngine
    private(set) var allowsEngineSelection: Bool
    var host: String
    var port: String
    var database: String
    var user: String
    var password = ""
    var usesPasswordCommand = false
    var passwordExecutable = ""
    var passwordArguments = "[]"
    var sslMode: String
    var sslRootCert: String
    var policy: ExecutionPolicy
    var localDatacenter: String
    var consistency: String
    var mongoAuthSource = "admin"
    var mongoAuthMechanism = ""
    var mongoReplicaSet = ""
    var mongoDirectConnection = false
    var sshEnabled = false
    var sshHost = ""
    var sshPort = "22"
    var sshUser = ""
    var sshAuthMethod: SSHConfiguration.Authentication = .agent
    var sshIdentityFile = ""
    var sshConfigFile = ""
    var sshPassword = ""
    var sshPassphrase = ""
    var rememberSSHSecret = true
    private var sshProfileId: UUID

    init(connection: SavedConnection?) {
        allowsEngineSelection = connection == nil
        sshProfileId = connection?.id ?? UUID()
        sshEnabled = connection?.ssh != nil
        sshHost = connection?.ssh?.host ?? ""
        sshPort = String(connection?.ssh?.port ?? 22)
        sshUser = connection?.ssh?.user ?? ""
        sshAuthMethod = connection?.ssh?.authMethod ?? .agent
        sshIdentityFile = connection?.ssh?.identityFile ?? ""
        sshConfigFile = connection?.ssh?.configFile ?? ""
        usesPasswordCommand = connection?.passwordCommand != nil
        passwordExecutable = connection?.passwordCommand?.executable ?? ""
        if let arguments = connection?.passwordCommand?.arguments,
           let data = try? JSONEncoder().encode(arguments) {
            passwordArguments = String(decoding: data, as: UTF8.self)
        }
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
        mongoAuthSource = connection?.mongodb?.authSource ?? "admin"
        mongoAuthMechanism = connection?.mongodb?.authMechanism ?? ""
        mongoReplicaSet = connection?.mongodb?.replicaSet ?? ""
        mongoDirectConnection = connection?.mongodb?.directConnection ?? false
    }

    init(duplicating connection: SavedConnection) {
        self.init(connection: connection)
        name = String(connection.name.prefix(123)).trimmingCharacters(in: .whitespacesAndNewlines) + " Copy"
        allowsEngineSelection = true
        sshProfileId = UUID()
    }

    mutating func selectEngine(_ next: DatabaseEngine) {
        guard allowsEngineSelection, next != engine else { return }
        if port == String(engine.defaultPort) { port = String(next.defaultPort) }
        if database == engine.defaultDatabase { database = next.defaultDatabase }
        if user == engine.defaultUser { user = next.defaultUser }
        if !next.sslModes.contains(sslMode) { sslMode = "verify-full" }
        engine = next
    }

    var connectionURL: String? {
        ConnectionURL.format(engine: engine, host: host.trimmingCharacters(in: .whitespacesAndNewlines),
            port: port.trimmingCharacters(in: .whitespacesAndNewlines),
            database: database.trimmingCharacters(in: .whitespacesAndNewlines),
            user: user.trimmingCharacters(in: .whitespacesAndNewlines), sslMode: sslMode,
            sslRootCert: sslRootCert.trimmingCharacters(in: .whitespacesAndNewlines))
    }

    mutating func applyConnectionURL(_ input: String) throws {
        let url = try ConnectionURL.parse(input)
        guard allowsEngineSelection || url.engine == engine else { throw ConnectionURL.Failure.engineMismatch }
        // Validate the entire URL before changing any draft field.
        selectEngine(url.engine)
        host = url.host
        port = String(url.port)
        database = url.database
        if let user = url.user { self.user = user }
        if let password = url.password { self.password = password; usesPasswordCommand = false }
        if let sslMode = url.sslMode { self.sslMode = sslMode }
        if let sslRootCert = url.sslRootCert { self.sslRootCert = sslRootCert }
    }

    var isValid: Bool {
        let cleanName = name.trimmingCharacters(in: .whitespacesAndNewlines)
        return settings != nil && !cleanName.isEmpty && cleanName.count <= 128
    }

    var hasValidPort: Bool {
        guard let value = Int(port.trimmingCharacters(in: .whitespacesAndNewlines)) else { return false }
        return (1...65_535).contains(value)
    }

    var passwordCommand: PasswordCommand? {
        guard let data = passwordArguments.data(using: .utf8),
              let arguments = try? JSONDecoder().decode([String].self, from: data) else { return nil }
        let command = PasswordCommand(executable: passwordExecutable, arguments: arguments)
        return command.isValid ? command : nil
    }

    var settings: ConnectionSettings? {
        if usesPasswordCommand && passwordCommand == nil { return nil }
        let cleanedHost = host.trimmingCharacters(in: .whitespacesAndNewlines)
        let cleanedDatabase = database.trimmingCharacters(in: .whitespacesAndNewlines)
        let cleanedUser = user.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let portNumber = Int(port.trimmingCharacters(in: .whitespacesAndNewlines)),
              (1...65_535).contains(portNumber), !cleanedHost.isEmpty, ([.cassandra, .mongodb].contains(engine) || !cleanedDatabase.isEmpty),
              ([.cassandra, .mongodb].contains(engine) || !cleanedUser.isEmpty), engine.sslModes.contains(sslMode) else { return nil }
        var ssh: SSHSettings?
        if sshEnabled {
            let configured = sshAuthMethod == .openSSH
            guard let port = configured ? 0 : Int(sshPort.trimmingCharacters(in: .whitespacesAndNewlines)) else { return nil }
            let configFile = sshConfigFile.trimmingCharacters(in: .whitespacesAndNewlines)
            let configuration = SSHConfiguration(host: sshHost.trimmingCharacters(in: .whitespacesAndNewlines), port: port,
                user: configured ? "" : sshUser.trimmingCharacters(in: .whitespacesAndNewlines), authMethod: sshAuthMethod,
                identityFile: sshAuthMethod == .privateKey ? sshIdentityFile : nil,
                configFile: configured && !configFile.isEmpty ? configFile : nil)
            guard configuration.isValid else { return nil }
            if sshAuthMethod == .privateKey, !ProfileTransfer.isLocalReadableCA(sshIdentityFile) { return nil }
            ssh = configuration.runtime(profileId: sshProfileId,
                password: sshAuthMethod == .password ? sshPassword : nil,
                passphrase: sshAuthMethod == .privateKey ? sshPassphrase : nil)
        }
        let rootCert = sslRootCert.trimmingCharacters(in: .whitespacesAndNewlines)
        let points = [.cassandra, .mongodb].contains(engine) ? CassandraSettings.contactPoints(cleanedHost) : []
        let settings = ConnectionSettings(host: points.first ?? cleanedHost, port: portNumber, database: cleanedDatabase,
            user: cleanedUser, password: password, sslMode: sslMode,
            sslRootCert: rootCert.isEmpty ? nil : rootCert, engine: engine, policy: policy,
            contactPoints: engine == .cassandra || engine == .mongodb && points.count > 1 ? points : nil,
            localDatacenter: engine == .cassandra && !localDatacenter.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? localDatacenter.trimmingCharacters(in: .whitespacesAndNewlines) : nil,
            consistency: engine == .cassandra ? consistency : nil, ssh: ssh,
            passwordCommand: usesPasswordCommand ? passwordCommand : nil,
            mongodb: engine == .mongodb ? MongoDBSettings(authSource: mongoAuthSource, authMechanism: mongoAuthMechanism,
                replicaSet: mongoReplicaSet, directConnection: mongoDirectConnection) : nil)
        return settings.hasValidNativeFields ? settings : nil
    }
}
