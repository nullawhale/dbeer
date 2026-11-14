import Foundation

@MainActor
extension SQLDocument {
    /// Removing a restored typed predicate changes saved settings only. The
    /// user must separately Load Data; no legacy or unfiltered read is hidden
    /// inside this recovery action.
    @discardableResult
    func removeUnloadedNativeKeyConditions() -> Bool {
        guard table != nil, grid == nil, tableFilterExpression?.hasNativeOperands == true,
              !isRunning, !isNavigatingTable, !isApplyingBrowse else { return false }
        tableFilterExpression = tableFilterExpression?.removingNativeOperands()
        if var draft = tableBrowseDraft {
            draft.filterExpression = draft.filterExpression?.removingNativeOperands()
            tableBrowseDraft = draft == browseConfiguration ? nil : draft
        }
        tableLoadedConfiguration = nil
        tableNeedsExplicitLoad = true
        tableNavigationError = nil
        resetTablePaging()
        return true
    }
}
