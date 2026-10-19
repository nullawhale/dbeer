import AppKit
import Foundation

enum WorkspaceCloseScope {
    case document(UUID), profile(UUID), application
}

enum WorkspaceCloseIssue: Equatable {
    case runningQuery(String)
    case transaction(String, failed: Bool)
    case changes(String, count: Int)
    case unknownApply(String)
}

enum WorkspaceCloseDecision: Equatable { case stop, commit, rollback, apply, discard, cancel }

enum WorkspaceCloseConfirmation {
    @MainActor static func present(_ issue: WorkspaceCloseIssue) async -> WorkspaceCloseDecision {
        let alert = NSAlert()
        let decisions: [WorkspaceCloseDecision]
        switch issue {
        case .runningQuery(let title):
            alert.messageText = "Stop Query in “\(title)”?"
            alert.informativeText = "Stop the running query before closing its session. Completed changes remain applied."
            alert.addButton(withTitle: "Stop and Continue")
            alert.addButton(withTitle: "Cancel")
            decisions = [.stop, .cancel]
        case .transaction(let title, let failed):
            alert.messageText = "Open Transaction in “\(title)”"
            alert.informativeText = failed
                ? "This transaction failed. Roll it back before closing the session."
                : "Choose how to finish the transaction before closing the session."
            if !failed { alert.addButton(withTitle: "Commit"); decisions = [.commit, .rollback, .cancel] }
            else { decisions = [.rollback, .cancel] }
            alert.addButton(withTitle: "Roll Back")
            alert.addButton(withTitle: "Cancel")
        case .changes(let title, let count):
            alert.messageText = "\(count) Pending Changes in “\(title)”"
            alert.informativeText = "Apply the table changes or discard them before closing."
            alert.addButton(withTitle: "Apply")
            alert.addButton(withTitle: "Discard")
            alert.addButton(withTitle: "Cancel")
            decisions = [.apply, .discard, .cancel]
        case .unknownApply(let title):
            alert.messageText = "Unconfirmed Changes in “\(title)”"
            alert.informativeText = "The commit outcome is unknown. Check the database before applying these changes again. Discard the local changes to close this tab."
            alert.addButton(withTitle: "Discard Local Changes")
            alert.addButton(withTitle: "Cancel")
            decisions = [.discard, .cancel]
        }
        let response = alert.runModal().rawValue - NSApplication.ModalResponse.alertFirstButtonReturn.rawValue
        return decisions.indices.contains(response) ? decisions[response] : .cancel
    }
}
