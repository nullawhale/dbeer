import Foundation

/// A launch-local undo record contains only restorable document context.
/// Snapshot and investigation tabs retain only their opaque local reference.
/// Closing an investigation never removes its durable library record. The undo
/// record cannot encode block SQL, sessions, execution results or grid drafts.
struct ClosedWorkspaceTab: Identifiable, Equatable, Sendable {
    let id = UUID()
    let state: StoredSQLDocument
    let originalIndex: Int
    let paneID: WorkspacePaneID
    let originalPaneIndex: Int

    init(state: StoredSQLDocument, originalIndex: Int, paneID: WorkspacePaneID = .left,
         originalPaneIndex: Int? = nil) {
        self.state = state
        self.originalIndex = originalIndex
        self.paneID = paneID
        self.originalPaneIndex = originalPaneIndex ?? originalIndex
    }
}
