import Combine
import Darwin
import Foundation

struct SynchronizationSQLStep: Codable, Equatable, Sendable, Identifiable {
    var id: String
    var title: String
    var sql: String
    var destructive: Bool
    var manual: Bool
    var reason: String
    var dependsOn: [String]
    var selected: Bool
}

struct SynchronizationSQLPlan: Codable, Equatable, Sendable {
    static let maximumBytes = 4 * 1_024 * 1_024
    var formatVersion: Int
    var kind: String
    var engine: String
    var modelDigest: String
    var warnings: [String]
    var steps: [SynchronizationSQLStep]

    var valid: Bool {
        guard formatVersion == 1, ["schema", "data"].contains(kind), ["postgresql", "mysql"].contains(engine),
              DataComparisonRequest.digestValid(modelDigest), steps.count <= 2_000, warnings.count <= 64,
              warnings.allSatisfy({ Self.textValid($0, limit: 4_096) }),
              let data = try? JSONEncoder().encode(self), data.count <= Self.maximumBytes else { return false }
        var seen: [String: SynchronizationSQLStep] = [:]
        for step in steps {
            guard !step.id.isEmpty, Self.textValid(step.id, limit: 128), seen[step.id] == nil,
                  Self.textValid(step.title, limit: 4_096), Self.textValid(step.sql, limit: Self.maximumBytes),
                  Self.textValid(step.reason, limit: 4_096), Set(step.dependsOn).count == step.dependsOn.count,
                  step.dependsOn.allSatisfy({ seen[$0] != nil && (step.manual || seen[$0]?.manual == false) && (!step.selected || seen[$0]?.selected == true) }),
                  !step.destructive || !step.selected,
                  step.manual ? step.sql.isEmpty && !step.selected && !step.reason.isEmpty : !step.sql.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return false }
            seen[step.id] = step
        }
        return true
    }

    private static func textValid(_ value: String, limit: Int) -> Bool { value.utf8.count <= limit && !value.contains("\0") }

    func selectionError(_ selected: Set<String>) -> String? {
        guard valid else { return "The SQL plan is invalid. Create a new comparison." }
        guard selected.isSubset(of: Set(steps.filter { !$0.manual }.map(\.id))) else { return "Manual operations cannot be included in generated SQL." }
        guard !selected.isEmpty else { return "Select at least one SQL operation." }
        for step in steps where selected.contains(step.id) {
            if let missing = step.dependsOn.first(where: { !selected.contains($0) }) {
                let title = steps.first { $0.id == missing }?.title ?? missing
                return "Select the required operation: \(title)."
            }
        }
        return nil
    }

    func sql(selected: Set<String>, source: String, target: String) -> String? {
        guard selectionError(selected) == nil else { return nil }
        var lines = [Self.comment("Synchronization plan: \(source) → \(target)"), Self.comment("Engine: \(engine). Capture digest: \(modelDigest)")]
        lines.append(contentsOf: warnings.map(Self.comment))
        if steps.contains(where: \.manual) { lines.append(Self.comment("Manual operations are omitted. Review their reasons before executing dependent work.")) }
        for step in steps where selected.contains(step.id) {
            lines.append("")
            lines.append(Self.comment("\(step.id): \(step.title)"))
            if step.destructive { lines.append(Self.comment("Destructive operation explicitly selected.")) }
            if !step.reason.isEmpty { lines.append(Self.comment(step.reason)) }
            lines.append(step.sql)
        }
        return lines.joined(separator: "\n") + "\n"
    }

    private static func comment(_ text: String) -> String {
        // Every physical line remains a comment even for quoted names containing line breaks.
        text.components(separatedBy: .newlines).map { "-- " + $0 }.joined(separator: "\n")
    }
}

@MainActor
final class SynchronizationPlanDraft: ObservableObject, Identifiable {
    let id = UUID()
    let plan: SynchronizationSQLPlan
    let source: SavedConnection
    let target: SavedConnection
    @Published var selected: Set<String> { didSet { saved = false; error = nil } }
    @Published private(set) var isValid = true
    @Published private(set) var error: String?
    @Published private(set) var saved = false
    private let open: @MainActor (String, SavedConnection) -> Bool
    private let validateTarget: @MainActor (SavedConnection) -> Bool

    init(plan: SynchronizationSQLPlan, source: SavedConnection, target: SavedConnection,
         validateTarget: @escaping @MainActor (SavedConnection) -> Bool = { _ in true },
         open: @escaping @MainActor (String, SavedConnection) -> Bool) {
        self.plan = plan; self.source = source; self.target = target; self.open = open; self.validateTarget = validateTarget
        selected = Set(plan.steps.filter(\.selected).map(\.id))
    }

    var selectionError: String? {
        guard isValid else { return "This comparison has closed. Generate a new plan." }
        guard plan.steps.contains(where: { !$0.manual }) else { return nil }
        return plan.selectionError(selected)
    }
    var sql: String? { isValid ? plan.sql(selected: selected, source: source.name, target: target.name) : nil }
    func invalidate() { isValid = false }

    @discardableResult func openInEditor() -> Bool {
        guard let sql, targetIsCurrent() else { return false }
        guard open(sql, target) else {
            error = "The target connection changed or the comparison closed. Create a new comparison before opening this plan."
            return false
        }
        invalidate()
        return true
    }

    private func targetIsCurrent() -> Bool {
        guard validateTarget(target) else {
            error = "The target connection changed or the comparison closed. Create a new comparison before using this plan."
            return false
        }
        return true
    }

    func save(to destination: URL, expectedSQL: String? = nil) {
        guard let sql, targetIsCurrent() else { return }
        guard expectedSQL == nil || expectedSQL == sql else {
            error = "The selected operations changed while the save dialog was open. Review the SQL and save again."
            return
        }
        let temporary = destination.deletingLastPathComponent().appendingPathComponent(".dbeer-plan-\(UUID().uuidString).tmp")
        defer { try? FileManager.default.removeItem(at: temporary) }
        do {
            guard FileManager.default.createFile(atPath: temporary.path, contents: Data(sql.utf8), attributes: [.posixPermissions: 0o600]),
                  rename(temporary.path, destination.path) == 0 else { throw CocoaError(.fileWriteUnknown) }
            saved = true; error = nil
        } catch { self.error = "The SQL plan could not be saved. The destination was left unchanged." }
    }
}
