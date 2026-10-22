import Foundation

/// A launch-local undo record contains only restorable document context.
/// Snapshot tabs retain only their opaque local artifact reference. The record
/// cannot encode sessions, execution results or grid drafts.
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
