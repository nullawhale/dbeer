import CryptoKit
import Foundation

enum LogicalRelationshipLimits {
    static let relationships = 512
    static let columns = 32
    static let libraryBytes = 4 * 1_024 * 1_024
    static let metadataBytes = 8 * 1_024 * 1_024
}

enum LogicalRelationshipError: LocalizedError, Equatable {
    case invalid, read, write, changed, busy, notFound
    case metadata(String)
    var errorDescription: String? {
        switch self {
        case .invalid: "The local relationship has invalid identifiers or incomplete, duplicate column mappings."
        case .read: "Local relationships could not be read. The existing library has been left unchanged."
        case .write: "Local relationships could not be saved. The local draft has been kept."
        case .changed: "Local relationships changed in another window or process. Reload the library before saving."
        case .busy: "The local relationship library is still loading or saving."
        case .notFound: "This local relationship is no longer available."
        case .metadata(let reason): reason
        }
    }
}
