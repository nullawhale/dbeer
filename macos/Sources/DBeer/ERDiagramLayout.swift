import Foundation

/// Geometry is independent of AppKit and metadata fetching.
enum ERDiagramLayout {
    static let width: Double = 340
    static let header: Double = 60
    static let row: Double = 26
    static let footer: Double = 32
    static let horizontalGap: Double = 192
    static let verticalGap: Double = 112
    static func columns(_ facts: ERTableMetadata?, collapsed: Bool) -> [ERColumn] {
        guard let facts else { return [] }
        guard collapsed else { return facts.columns }
        let fkNames = Set(facts.foreignKeys.flatMap { $0.columns.map { Data($0.source.utf8) } })
        return facts.columns.enumerated().filter { $0.offset < 10 || $0.element.primaryKeyPosition != nil || fkNames.contains(Data($0.element.name.utf8)) }.map(\.element)
    }
    static func height(_ facts: ERTableMetadata?, collapsed: Bool) -> Double {
        header + Double(max(1, columns(facts, collapsed: collapsed).count)) * row + footer
    }
    static func positions(tables: [ERTableID], relationships: [ERRelationship], metadata: [ERTableID: ERTableMetadata],
                          preserving: [ERPlacement], collapsed: Set<ERTableID>) -> [ERPlacement] {
        let ordered = tables.sorted { $0.id < $1.id }
        let selected = Set(ordered)
        var edges: [ERTableID: [ERTableID]] = [:]
        for edge in relationships where selected.contains(edge.source) && selected.contains(edge.target) {
            edges[edge.source, default: []].append(edge.target)
        }
        // Tarjan SCCs keep cycles in a shared rank instead of an unbounded ranking loop.
        var next = 0, index: [ERTableID: Int] = [:], low: [ERTableID: Int] = [:]
        var stack: [ERTableID] = [], active = Set<ERTableID>(), components: [[ERTableID]] = []
        func visit(_ node: ERTableID) {
            index[node] = next; low[node] = next; next += 1; stack.append(node); active.insert(node)
            for target in (edges[node] ?? []).sorted(by: { $0.id < $1.id }) {
                if index[target] == nil { visit(target); low[node] = min(low[node]!, low[target]!) }
                else if active.contains(target) { low[node] = min(low[node]!, index[target]!) }
            }
            if low[node] == index[node] {
                var group: [ERTableID] = []
                while let item = stack.popLast() {
                    active.remove(item); group.append(item)
                    if item == node { break }
                }
                components.append(group.sorted { $0.id < $1.id })
            }
        }
        for node in ordered where index[node] == nil { visit(node) }
        var owner: [ERTableID: Int] = [:]
        for (i, group) in components.enumerated() { for node in group { owner[node] = i } }
        var links: [Int: Set<Int>] = [:], indegree: [Int: Int] = [:], rank: [Int: Int] = [:]
        for edge in relationships {
            guard let a = owner[edge.source], let b = owner[edge.target], a != b else { continue }
            if links[a, default: []].insert(b).inserted { indegree[b, default: 0] += 1 }
        }
        var queue = components.indices.filter { indegree[$0, default: 0] == 0 }.sorted()
        while !queue.isEmpty {
            let node = queue.removeFirst()
            for target in (links[node] ?? []).sorted() {
                rank[target] = max(rank[target, default: 0], rank[node, default: 0] + 1)
                indegree[target, default: 0] -= 1
                if indegree[target] == 0 { queue.append(target); queue.sort() }
            }
        }
        var result = preserving.filter { selected.contains($0.table) && $0.point.isValid }
        var occupied = result.map { placement in
            CGRect(x: placement.point.x, y: placement.point.y, width: width,
                   height: height(metadata[placement.table], collapsed: collapsed.contains(placement.table)))
                .insetBy(dx: -horizontalGap / 2, dy: -verticalGap / 2)
        }
        var levels: [Int: Double] = [:]
        for node in ordered where !result.contains(where: { $0.table == node }) {
            if Task.isCancelled { break }
            let level = rank[owner[node]!, default: 0]
            let x = Double(level) * (width + horizontalGap) + 40
            var y = levels[level, default: 40]
            let h = height(metadata[node], collapsed: collapsed.contains(node))
            var rect = CGRect(x: x, y: y, width: width, height: h)
            var padded = rect.insetBy(dx: -horizontalGap / 2, dy: -verticalGap / 2)
            while let obstacle = occupied.first(where: {
                $0.minX < padded.maxX && $0.maxX > padded.minX && $0.minY < padded.maxY && $0.maxY > padded.minY
            }) {
                y = obstacle.maxY + verticalGap / 2; rect.origin.y = y
                padded = rect.insetBy(dx: -horizontalGap / 2, dy: -verticalGap / 2)
            }
            levels[level] = y + h + verticalGap
            occupied.append(padded)
            result.append(.init(table: node, point: .init(x: x, y: y)))
        }
        return result.sorted { $0.table.id < $1.table.id }
    }
    static func focus(_ point: ERPoint, viewport: ERViewport, size: CGSize) -> ERViewport {
        guard point.isValid, viewport.isValid, size.width.isFinite, size.height.isFinite else { return viewport }
        let x = size.width / 2 - (point.x + width / 2) * viewport.zoom
        let y = size.height / 2 - (point.y + 60) * viewport.zoom
        return ERViewport(zoom: viewport.zoom, pan: .init(x: min(1_000_000, max(-1_000_000, x)),
                                                        y: min(1_000_000, max(-1_000_000, y))))
    }
    static func fit(_ placements: [ERPlacement], metadata: [ERTableID: ERTableMetadata], collapsed: Set<ERTableID>,
                    size: CGSize, routes: [ERDiagramRoute] = []) -> ERViewport {
        guard size.width.isFinite, size.height.isFinite, size.width > 0, size.height > 0, !placements.isEmpty else { return ERViewport() }
        var rect = placements.reduce(CGRect.null) { rect, item in
            rect.union(CGRect(x: item.point.x, y: item.point.y, width: width,
                              height: height(metadata[item.table], collapsed: collapsed.contains(item.table))))
        }
        for point in routes.flatMap(\.points) { rect = rect.union(CGRect(origin: point, size: .zero)) }
        let zoom = min(1.5, max(0.2, min((size.width - 64) / max(1, rect.width), (size.height - 64) / max(1, rect.height))))
        return ERViewport(zoom: zoom, pan: .init(x: min(1_000_000, max(-1_000_000, size.width / 2 - rect.midX * zoom)),
            y: min(1_000_000, max(-1_000_000, size.height / 2 - rect.midY * zoom))))
    }
}
