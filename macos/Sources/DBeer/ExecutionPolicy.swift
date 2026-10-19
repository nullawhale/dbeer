import AppKit
import Foundation
import SwiftUI

enum ConnectionEnvironment: String, CaseIterable, Codable, Identifiable, Sendable {
    case unspecified, development, staging, production
    var id: String { rawValue }
    var label: String {
        switch self {
        case .unspecified: "Not specified"
        case .development: "dev"
        case .staging: "stag"
        case .production: "prod"
        }
    }
    var color: Color {
        switch self {
        case .unspecified: .secondary
        case .development: .green
        case .staging: .orange
        case .production: .red
        }
    }
    var nativeColor: NSColor {
        switch self {
        case .unspecified: .secondaryLabelColor
        case .development: .systemGreen
        case .staging: .systemOrange
        case .production: .systemRed
        }
    }
}

struct ExecutionPolicy: Codable, Equatable, Sendable {
    var environment: ConnectionEnvironment = .unspecified
    var readOnly = false
    var label: String { environment.label + (readOnly ? " · Readonly" : "") }
}

struct OperationRequest: Codable, Equatable, Sendable {
    var type: String
    var sql: String?
    var export: ExportRequest?
    var changes: ChangesRequest?
}

struct StatementAssessment: Codable, Equatable, Sendable {
    var start: Int
    var end: Int
    var kind: String
    var reason: String
}

struct AssessedOperation: Codable, Equatable, Sendable {
    var kind: String
    var statements: [StatementAssessment]
}

struct OperationAssessment: Codable, Equatable, Sendable {
    var decision: String
    var policy: ExecutionPolicy
    var operations: [AssessedOperation]
    var authorization: String?
    var valid: Bool {
        ["allow", "confirm", "deny"].contains(decision) && !operations.isEmpty && operations.count <= 1024 &&
            operations.allSatisfy { operation in
                ["read", "write", "destructive", "unknown"].contains(operation.kind) &&
                operation.statements.allSatisfy { $0.start >= 0 && $0.end >= $0.start &&
                    ["read", "write", "destructive", "unknown"].contains($0.kind) }
            } && (decision == "deny" ? authorization == nil : authorization.map(BackendMessage.validID) == true)
    }
}

struct OperationConfirmation: Sendable {
    let profile: SavedConnection
    let operations: [OperationRequest]
    let assessment: OperationAssessment
    let isScript: Bool
    var sourceSQL: String? = nil
    var generatedPreview: String? = nil
}

/// The displayed SQL is the exact batch evaluated by the helper. No execution
/// command is submitted until the modal has returned Execute.
enum ExecutionConfirmation {
    @MainActor static func present(_ confirmation: OperationConfirmation) async -> Bool {
        runModal(makeAlert(confirmation)) == .alertFirstButtonReturn
    }

    /// AppKit gives a button one key equivalent. Cancel owns Return as the
    /// safe default; preserve the native Escape action for this modal only.
    @MainActor static func runModal(_ alert: NSAlert) -> NSApplication.ModalResponse {
        let monitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { event in
            let consumed = MainActor.assumeIsolated {
                guard NSApp.modalWindow === alert.window, event.keyCode == 53,
                      event.modifierFlags.intersection([.command, .control, .option, .shift]).isEmpty else { return false }
                alert.buttons[1].performClick(nil)
                return true
            }
            return consumed ? nil : event
        }
        defer { if let monitor { NSEvent.removeMonitor(monitor) } }
        return alert.runModal()
    }

    @MainActor static func makeAlert(_ confirmation: OperationConfirmation) -> NSAlert {
        let alert = NSAlert()
        alert.alertStyle = confirmation.assessment.decision == "confirm" ? .warning : .informational
        alert.messageText = confirmation.isScript ? "Review Entire SQL Script" : "Confirm Database Operation"
        let profile = confirmation.profile
        alert.informativeText = "\(profile.name) · \(profile.engine.displayName) · \(profile.host):\(profile.port)/\(profile.database)\n\(profile.policy.label)\nDestructive and unknown commands require confirmation. Production confirms every evaluated write. Functions and database objects can hide side effects; use restricted database privileges for strict protection."
        alert.addButton(withTitle: "Execute")
        alert.addButton(withTitle: "Cancel")
        // Cancel is the default key action; Return must not accidentally approve.
        alert.buttons[0].keyEquivalent = ""
        alert.buttons[1].keyEquivalent = "\r"
        let scroll = NSScrollView(frame: NSRect(x: 0, y: 0, width: 680, height: 340))
        scroll.hasVerticalScroller = true
        scroll.hasHorizontalScroller = true
        let text = NSTextView(frame: NSRect(x: 0, y: 0, width: 660, height: 340))
        text.isEditable = false
        text.isSelectable = true
        text.isRichText = true
        text.isVerticallyResizable = true
        text.isHorizontallyResizable = false
        text.minSize = NSSize(width: 660, height: 340)
        text.maxSize = NSSize(width: 660, height: CGFloat.greatestFiniteMagnitude)
        text.textContainer?.widthTracksTextView = true
        text.textContainer?.containerSize = NSSize(width: 660, height: CGFloat.greatestFiniteMagnitude)
        text.textContainerInset = NSSize(width: 8, height: 8)
        text.autoresizingMask = [.width]
        let content = NSMutableAttributedString(string: "")
        content.append(NSAttributedString(string: profile.policy.label + "\n\n",
            attributes: [.font: NSFont.boldSystemFont(ofSize: 14), .foregroundColor: profile.policy.environment.nativeColor]))
        if let source = confirmation.sourceSQL {
            content.append(NSAttributedString(string: "Entire script source\n" + source + "\n\nCommands sent to the server follow below.\n",
                attributes: [.font: NSFont.monospacedSystemFont(ofSize: 12, weight: .regular), .foregroundColor: NSColor.labelColor]))
        }
        if let preview = confirmation.generatedPreview {
            content.append(NSAttributedString(string: "Generated SQL and bound parameters\n" + preview + "\n",
                attributes: [.font: NSFont.monospacedSystemFont(ofSize: 12, weight: .regular), .foregroundColor: NSColor.labelColor]))
        }
        for (index, operation) in confirmation.operations.enumerated() {
            let assessed = confirmation.assessment.operations[index]
            content.append(NSAttributedString(string: "\nCommand \(index + 1) · \(assessed.kind.uppercased())\n",
                attributes: [.font: NSFont.boldSystemFont(ofSize: 12), .foregroundColor: assessed.kind == "read" ? NSColor.secondaryLabelColor : NSColor.systemRed]))
            let encoder = JSONEncoder()
            encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
            let sql = operation.sql ?? (operation.changes.flatMap { try? encoder.encode($0) }.flatMap { String(data: $0, encoding: .utf8) } ?? "")
            let displayed = NSMutableAttributedString(string: sql, attributes: [.font: NSFont.monospacedSystemFont(ofSize: 12, weight: .regular), .foregroundColor: NSColor.labelColor])
            if operation.sql != nil {
                let bytes = Array(sql.utf8)
                for statement in assessed.statements where statement.kind != "read" && statement.end <= bytes.count {
                    if let prefix = String(bytes: bytes[..<statement.start], encoding: .utf8),
                       let fragment = String(bytes: bytes[statement.start..<statement.end], encoding: .utf8) {
                        displayed.addAttribute(.backgroundColor, value: NSColor.systemRed.withAlphaComponent(0.14),
                            range: NSRange(location: prefix.utf16.count, length: fragment.utf16.count))
                    }
                }
            }
            content.append(displayed)
            content.append(NSAttributedString(string: "\n"))
        }
        text.textStorage?.setAttributedString(content)
        text.setAccessibilityLabel("Entire operation preview")
        text.setAccessibilityIdentifier("executionSQLPreview")
        scroll.documentView = text
        alert.accessoryView = scroll
        return alert
    }
}
