import CoreTransferable
import Foundation
import UniformTypeIdentifiers

extension UTType {
    static let dbeerWorkspaceTab = UTType(exportedAs: "dev.dbeer.workspace-tab", conformingTo: .data)
}

/// This representation deliberately offers no plain-text fallback: dropping a
/// tab over a native SQL editor must not insert its document identifier.
struct WorkspaceTabTransfer: Codable, Transferable, Sendable {
    let workspaceSessionID: UUID
    let documentID: UUID

    static var transferRepresentation: some TransferRepresentation {
        CodableRepresentation(contentType: .dbeerWorkspaceTab)
    }

    @MainActor
    func validatedDocumentID(in workspace: ApplicationWorkspace, sessionID: UUID) -> UUID? {
        guard workspaceSessionID == sessionID, workspace.pane(containing: documentID) != nil,
              workspace.documents.contains(where: { $0.id == documentID }) else { return nil }
        return documentID
    }
}
