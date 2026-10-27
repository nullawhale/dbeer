import Combine
import Foundation

@MainActor
final class ResultCopySettings: ObservableObject {
    static let shared = ResultCopySettings()
    static let preferenceKey = "resultCopyOptions"

    @Published var options: ResultCopyOptions {
        didSet {
            guard options != oldValue, let data = try? JSONEncoder().encode(options) else { return }
            defaults.set(data, forKey: Self.preferenceKey)
        }
    }

    private let defaults: UserDefaults

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        options = defaults.data(forKey: Self.preferenceKey)
            .flatMap { try? JSONDecoder().decode(ResultCopyOptions.self, from: $0) } ?? .default
    }

    func reset() { options = .default }
}
