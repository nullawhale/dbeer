import Combine
import Foundation

/// A failed save retains one prepared Markdown block. Retrying saves that same
/// draft instead of inserting a duplicate block or creating another document.
@MainActor
final class GridProfileAttachment: ObservableObject {
    let report: GridProfileReport
    let library: InvestigationLibraryModel
    @Published private(set) var isSaving = false
    @Published private(set) var pendingDocumentID: UUID?
    @Published private(set) var error: String?
    private var preparedTarget: UUID?
    private let mayAttach: @MainActor () -> Bool

    init(report: GridProfileReport, library: InvestigationLibraryModel,
         mayAttach: @escaping @MainActor () -> Bool = { true }) {
        self.report = report; self.library = library; self.mayAttach = mayAttach
    }

    func save(to target: UUID?) async -> Bool {
        guard !isSaving, mayAttach() else { return false }
        isSaving = true; error = nil
        defer { isSaving = false }
        do {
            await library.restore()
            guard mayAttach(), library.isLoaded else { throw GridProfileFailure("The Investigation library is unavailable.") }
            if pendingDocumentID == nil {
                let report = self.report
                let markdown = await Task.detached(priority: .userInitiated) { report.markdown }.value
                guard mayAttach(), !Task.isCancelled,
                      markdown.utf8.count <= InvestigationLimits.maximumBlockBytes else {
                    throw GridProfileFailure("The captured report is too large or its owner closed. Select fewer columns and attach again.")
                }
                let document: InvestigationDocumentModel
                if let target { document = try library.openDocument(id: target) }
                else {
                    guard let created = library.create(title: "Data profile") else {
                        throw GridProfileFailure(library.error ?? "An Investigation could not be created.")
                    }
                    document = created
                }
                guard document.addMarkdown(text: markdown) != nil else {
                    throw GridProfileFailure(document.error ?? "The Investigation cannot accept another profile block.")
                }
                preparedTarget = target; pendingDocumentID = document.id
            } else if preparedTarget != target {
                throw GridProfileFailure("Retry the prepared Investigation save before choosing another destination.")
            }
            guard mayAttach(), let pendingDocumentID else { throw CancellationError() }
            let saved = await library.saveInvestigation(pendingDocumentID)
            if !saved { error = library.error ?? "The prepared profile block remains in its Investigation draft. Retry saving it." }
            return saved
        } catch { self.error = error.localizedDescription; return false }
    }
}
