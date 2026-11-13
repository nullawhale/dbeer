import Foundation

extension ApplicationWorkspace {
    func showSchemaBundle(_ profile: SavedConnection) {
        guard canManageWorkspace, schemaBundle == nil, [.postgresql, .mysql, .sqlite].contains(profile.engine),
              let binding = SessionMonitorProfileBinding(profile), binding.matches(in: library.savedConnections) else { return }
        schemaBundle = SchemaBundleModel(profile: profile, resolve: { [weak self] profile, attempt in
            guard let self, self.canManageWorkspace, binding.matches(in: self.library.savedConnections) else { throw CancellationError() }
            return try await self.readonlyOperationSettings(profile, attempt: attempt)
        }, current: { [weak self] in
            guard let self else { return false }
            return self.schemaBundleBindingIsCurrent(binding)
        }, startAllowed: { [weak self] in self?.canManageWorkspace == true })
    }
    func dismissSchemaBundle() {
        let model = schemaBundle; schemaBundle = nil
        Task { await model?.close() }
    }
}
