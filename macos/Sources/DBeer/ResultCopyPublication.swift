import AppKit
import Foundation

extension AppCommandID {
    var resultCopyFormat: ResultCopyFormat? {
        switch self {
        case .copyAsJSON: .json
        case .copyAsMarkdown: .markdown
        case .copyAsSQLInsert: .sqlInsert
        default: nil
        }
    }
}

/// Both clipboard representations are prepared before replacing its contents.
struct PreparedResultCopy: Sendable {
    let text: String
    let typedData: Data

    init(payload: ResultClipboardPayload, format: ResultCopyFormat, includesHeaders: Bool,
         insertSQL: String? = nil) throws {
        try ResultCopy.validate(payload)
        if format == .sqlInsert {
            guard let insertSQL, !insertSQL.isEmpty else { throw ResultCopyError.sqlInsertTargetRequired }
            text = insertSQL
        } else {
            text = try ResultCopy.text(payload, format: format, includesHeaders: includesHeaders)
        }
        typedData = try JSONEncoder().encode(payload)
    }
}

/// A newer copy action or an external clipboard change revokes delayed work.
@MainActor
final class ResultCopyPublication {
    static let shared = ResultCopyPublication()
    private var generation = UUID()

    struct Ticket: Equatable {
        let generation: UUID
        let changeCount: Int
    }

    func capture(changeCount: Int) -> Ticket {
        generation = UUID()
        return Ticket(generation: generation, changeCount: changeCount)
    }

    func isCurrent(_ ticket: Ticket) -> Bool { ticket.generation == generation }

    func canPublish(_ ticket: Ticket, changeCount: Int) -> Bool {
        isCurrent(ticket) && ticket.changeCount == changeCount
    }

    func publish(_ prepared: PreparedResultCopy, to pasteboard: NSPasteboard, ticket: Ticket) -> Bool {
        guard canPublish(ticket, changeCount: pasteboard.changeCount) else { return false }
        let item = NSPasteboardItem()
        guard item.setData(prepared.typedData, forType: ResultTableView.clipboardType),
              item.setString(prepared.text, forType: .string) else { return false }
        pasteboard.clearContents()
        return pasteboard.writeObjects([item])
    }
}
