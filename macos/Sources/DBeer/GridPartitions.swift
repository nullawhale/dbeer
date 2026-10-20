import Foundation

/// View-local labels derived from the complete, lossless loaded partition key.
/// Keys are immutable in the Cassandra grid; edits never change these labels.
/// The adapter still validates native keys and atomicity before writing.
struct GridPartitionMarker: Equatable {
    let number: Int
    let keyDescription: String
    var label: String { "P\(number)" }
    var help: String { "Partition \(label)\n\(keyDescription)\nClick to select all loaded rows in this partition." }
}

enum GridPartitionStatus: Equatable {
    case single(GridPartitionMarker)
    case multiple(Int)
    case unavailable

    var allowsApply: Bool {
        if case .single = self { return true }
        return false
    }

    var label: String {
        switch self {
        case .single(let marker): "1 partition · \(marker.label)"
        case .multiple(let count): "\(count) partitions"
        case .unavailable: "Partition unavailable"
        }
    }

    var help: String {
        switch self {
        case .single(let marker): "All pending row changes belong to \(marker.label).\n\(marker.keyDescription)"
        case .multiple: "Atomic Apply requires all pending row changes to belong to one partition. Revert edits in the other partitions before applying."
        case .unavailable: "A pending row is missing a complete partition key. Reload its structure and data before applying changes."
        }
    }
}

enum GridPartitions {
    private struct Component: Hashable {
        let kind: String
        // Swift String equality folds canonical Unicode equivalents. Cassandra
        // text partition keys use their exact UTF-8 bytes instead.
        let value: Data
    }

    static func markers(columns: [ResultColumn], metadata: [[String: String]], rows: [GridRow]) -> [GridPartitionMarker?]? {
        guard !columns.isEmpty, columns.allSatisfy({ $0.engine == .cassandra }) else { return nil }
        let keys = metadata.indices.filter { (Int(metadata[$0]["partitionKeyPosition"] ?? "0") ?? 0) > 0 }.sorted {
            (Int(metadata[$0]["partitionKeyPosition"] ?? "0") ?? 0) < (Int(metadata[$1]["partitionKeyPosition"] ?? "0") ?? 0)
        }
        guard !keys.isEmpty, keys.enumerated().allSatisfy({ Int(metadata[$0.element]["partitionKeyPosition"] ?? "0") == $0.offset + 1 }) else {
            return Array(repeating: nil, count: rows.count)
        }
        var groups: [[Component]: GridPartitionMarker] = [:]
        return rows.map { row in
            guard let original = row.original else { return nil }
            var components: [Component] = []
            for index in keys {
                guard original.indices.contains(index), columns.indices.contains(index),
                      ["text", "binary"].contains(original[index].kind), let value = original[index].value else { return nil }
                components.append(Component(kind: original[index].kind, value: Data(value.utf8)))
            }
            if let marker = groups[components] { return marker }
            var descriptions = keys.prefix(8).map { index in
                let value = original[index].value ?? ""
                let short = String(value.prefix(128)) + (value.count > 128 ? "…" : "")
                return "\(columns[index].name) = \(short.isEmpty ? "\"\"" : short)"
            }
            if keys.count > 8 { descriptions.append("… \(keys.count - 8) more key columns") }
            let marker = GridPartitionMarker(number: groups.count + 1, keyDescription: descriptions.joined(separator: "\n"))
            groups[components] = marker
            return marker
        }
    }
}
