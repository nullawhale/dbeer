import Foundation

/// A launch-local undo record contains only restorable document context.
/// Snapshot tabs retain only their opaque local artifact reference. The record
/// cannot encode sessions, execution results or grid drafts.
struct ClosedWorkspaceTab: Identifiable, Equatable, Sendable {
    let id = UUID()
    let state: StoredSQLDocument
    let originalIndex: Int
}
