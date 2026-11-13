import Foundation

struct ERDiagramRoute: Equatable {
    let relationshipID: String
    let points: [CGPoint]

    /// Keep the target marker legible at every zoom without extending it past
    /// the last bend or into a neighboring card.
    func arrowhead(zoom: Double, obstacles: [CGRect]) -> [CGPoint] {
        guard zoom.isFinite, zoom > 0, points.count >= 2,
              let tip = points.last else { return [] }
        let previous = points[points.count - 2]
        guard tip.y == previous.y, tip.x != previous.x else { return [] }
        let outward = tip.x > previous.x ? -1.0 : 1.0
        let halfHeight = 5 / zoom
        let terminalLength = abs(tip.x - previous.x)
        var length = min(12 / zoom, terminalLength - min(2 / zoom, terminalLength / 4))
        for rect in obstacles where rect.minY < tip.y + halfHeight && rect.maxY > tip.y - halfHeight {
            let gap: Double
            if outward > 0, rect.minX >= tip.x { gap = rect.minX - tip.x }
            else if outward < 0, rect.maxX <= tip.x { gap = tip.x - rect.maxX }
            else { continue }
            length = min(length, max(0, gap - min(0.5 / zoom, gap / 10)))
        }
        guard length > 0 else { return [] }
        return [tip, CGPoint(x: tip.x + outward * length, y: tip.y - halfHeight),
                CGPoint(x: tip.x + outward * length, y: tip.y + halfHeight)]
    }
}

/// Routes in diagram coordinates, independently of pan, zoom and AppKit.
enum ERDiagramRouting {
    // At the minimum zoom (20%), this still fits a 12pt arrow and a 2pt gap
    // between its base and the preceding bend.
    static let terminalLead: Double = 72
    struct Geometry: Equatable {
        let tables: [ERTableID]
        let placements: [ERPlacement]
        let metadata: [ERTableID: ERTableMetadata]
        let collapsed: Set<ERTableID>
    }

    static func routes(_ geometry: Geometry, relationships: [ERRelationship]) -> [ERDiagramRoute] {
        let selected = Set(geometry.tables)
        let cards = Dictionary(uniqueKeysWithValues: geometry.placements.filter { selected.contains($0.table) }.map {
            ($0.table, CGRect(x: $0.point.x, y: $0.point.y, width: ERDiagramLayout.width,
                height: ERDiagramLayout.height(geometry.metadata[$0.table], collapsed: geometry.collapsed.contains($0.table))))
        })
        // Narrow gaps still admit facing ports; reserve a third of the gap on
        // either side instead of inflating neighboring cards into one obstacle.
        let rectangles = geometry.tables.compactMap { cards[$0] }
        var clearance = 12.0
        for (index, a) in rectangles.enumerated() {
            for b in rectangles.dropFirst(index + 1) {
                if a.minY < b.maxY && b.minY < a.maxY {
                    let gap = max(a.minX - b.maxX, b.minX - a.maxX)
                    if gap > 0 { clearance = min(clearance, gap / 3) }
                }
                if a.minX < b.maxX && b.minX < a.maxX {
                    let gap = max(a.minY - b.maxY, b.minY - a.maxY)
                    if gap > 0 { clearance = min(clearance, gap / 3) }
                }
            }
        }
        var result: [ERDiagramRoute] = []
        let extent = rectangles.reduce(CGRect.null) { $0.union($1) }
        for (index, edge) in relationships.sorted(by: { $0.id < $1.id }).enumerated() {
            var cards = cards
            // Confirmed external links remain explicit stubs. They never
            // pretend that metadata for another profile was loaded here.
            if edge.kind == .logical, !extent.isNull {
                if cards[edge.source] == nil, let target = cards[edge.target] {
                    let y = anchorY(edge.target, column: edge.key.columns.first?.target, rect: target, geometry: geometry)
                    cards[edge.source] = CGRect(x: extent.minX - 160, y: y - 24 + Double(index % 5) * 14, width: 0, height: 0)
                }
                if cards[edge.target] == nil, let source = cards[edge.source] {
                    let y = anchorY(edge.source, column: edge.key.columns.first?.source, rect: source, geometry: geometry)
                    cards[edge.target] = CGRect(x: extent.maxX + 160, y: y - 24 + Double(index % 5) * 14, width: 0, height: 0)
                }
            }
            guard let source = cards[edge.source], let target = cards[edge.target] else { continue }
            let sourceY = anchorY(edge.source, column: edge.key.columns.first?.source, rect: source, geometry: geometry)
            var targetY = anchorY(edge.target, column: edge.key.columns.first?.target, rect: target, geometry: geometry)
            if edge.source == edge.target, sourceY == targetY { targetY = source.minY + 24 }
            if edge.source == edge.target, sourceY == targetY { targetY += 12 }
            let preferredRight = source.midX < target.midX
            let sides: [(Bool, Bool)] = edge.source == edge.target
                ? [(true, true), (false, false)]
                : [(preferredRight, !preferredRight), (true, true), (false, false), (!preferredRight, preferredRight)]
            var best: [CGPoint]?
            var bestLength = Double.infinity
            for (sourceRight, targetRight) in sides {
                let start = CGPoint(x: sourceRight ? source.maxX : source.minX, y: sourceY)
                let end = CGPoint(x: targetRight ? target.maxX : target.minX, y: targetY)
                let distance = terminalLead + Double(index % 3) * 8
                let exit = CGPoint(x: start.x + (sourceRight ? distance : -distance), y: start.y)
                let entry = CGPoint(x: end.x + (targetRight ? distance : -distance), y: end.y)
                guard length([start, exit, entry, end]) < bestLength else { continue }
                // Only the terminal's own clearance rectangle may contain its stub.
                let terminalObstacles = geometry.tables.compactMap { table -> CGRect? in
                    guard let rect = cards[table] else { return nil }
                    var left = clearance, right = clearance
                    if table == edge.source { if sourceRight { right = distance } else { left = distance } }
                    if table == edge.target { if targetRight { right = distance } else { left = distance } }
                    return CGRect(x: rect.minX - left, y: rect.minY - clearance,
                        width: rect.width + left + right, height: rect.height + clearance * 2)
                }
                guard clear(start, exit, obstacles: cards.filter { $0.key != edge.source }.map { $0.value.insetBy(dx: -clearance, dy: -clearance) }),
                      clear(entry, end, obstacles: cards.filter { $0.key != edge.target }.map { $0.value.insetBy(dx: -clearance, dy: -clearance) }),
                      let middle = route(exit, entry, obstacles: terminalObstacles) else { continue }
                let candidate = simplified([start] + middle + [end])
                guard candidate.count >= 2 else { continue }
                let second = candidate[1], beforeEnd = candidate[candidate.count - 2]
                guard second.y == start.y, beforeEnd.y == end.y,
                      (second.x - start.x) * (sourceRight ? 1 : -1) >= distance - 0.00001,
                      (beforeEnd.x - end.x) * (targetRight ? 1 : -1) >= distance - 0.00001 else { continue }
                let candidateLength = length(candidate)
                if candidateLength < bestLength { best = candidate; bestLength = candidateLength }
            }
            if let best { result.append(.init(relationshipID: edge.id, points: best)) }
        }
        return result
    }

    private static func anchorY(_ table: ERTableID, column: String?, rect: CGRect, geometry: Geometry) -> Double {
        let facts = geometry.metadata[table]
        let columns = ERDiagramLayout.columns(facts, collapsed: geometry.collapsed.contains(table))
        let index = facts?.columnState.isAvailable == true ? columns.firstIndex {
            Data($0.name.utf8) == Data((column ?? "").utf8)
        } : nil
        return rect.minY + (index.map { ERDiagramLayout.header + Double($0) * ERDiagramLayout.row + ERDiagramLayout.row / 2 } ?? 24)
    }

    private static func clear(_ a: CGPoint, _ b: CGPoint, obstacles: [CGRect]) -> Bool {
        if a.y == b.y {
            return !obstacles.contains { a.y > $0.minY && a.y < $0.maxY && min(a.x, b.x) < $0.maxX && max(a.x, b.x) > $0.minX }
        }
        guard a.x == b.x else { return false }
        return !obstacles.contains { a.x > $0.minX && a.x < $0.maxX && min(a.y, b.y) < $0.maxY && max(a.y, b.y) > $0.minY }
    }

    private static func length(_ points: [CGPoint]) -> Double {
        zip(points, points.dropFirst()).reduce(0) { $0 + abs($1.0.x - $1.1.x) + abs($1.0.y - $1.1.y) }
    }

    private static func simplified(_ points: [CGPoint]) -> [CGPoint] {
        var result: [CGPoint] = []
        for point in points where point != result.last {
            if result.count >= 2 {
                let a = result[result.count - 2], b = result[result.count - 1]
                if (a.x == b.x && b.x == point.x) || (a.y == b.y && b.y == point.y) { result.removeLast() }
            }
            result.append(point)
        }
        return result
    }

    private static func route(_ start: CGPoint, _ end: CGPoint, obstacles: [CGRect]) -> [CGPoint]? {
        let extent = obstacles.reduce(CGRect.null) { $0.union($1) }
        var candidates = [[start, CGPoint(x: end.x, y: start.y), end],
                          [start, CGPoint(x: start.x, y: end.y), end]]
        for x in [(start.x + end.x) / 2, extent.minX - 16, extent.maxX + 16] {
            candidates.append([start, CGPoint(x: x, y: start.y), CGPoint(x: x, y: end.y), end])
        }
        for y in [(start.y + end.y) / 2, extent.minY - 16, extent.maxY + 16] {
            candidates.append([start, CGPoint(x: start.x, y: y), CGPoint(x: end.x, y: y), end])
        }
        if let path = candidates.filter({ path in zip(path, path.dropFirst()).allSatisfy { clear($0, $1, obstacles: obstacles) } })
            .min(by: { length($0) < length($1) }) { return simplified(path) }

        // A rectilinear visibility grid handles corridors requiring several turns.
        // Grid lines follow obstacle boundaries; no fallback crosses a card.
        let xs = Array(Set(obstacles.flatMap { [$0.minX, $0.maxX] } + [start.x, end.x, extent.minX - 16, extent.maxX + 16])).sorted()
        let ys = Array(Set(obstacles.flatMap { [$0.minY, $0.maxY] } + [start.y, end.y, extent.minY - 16, extent.maxY + 16])).sorted()
        let width = xs.count
        func point(_ index: Int) -> CGPoint { CGPoint(x: xs[index % width], y: ys[index / width]) }
        let first = ys.firstIndex(of: start.y)! * width + xs.firstIndex(of: start.x)!
        let goal = ys.firstIndex(of: end.y)! * width + xs.firstIndex(of: end.x)!
        var costs = [first: 0.0], parents: [Int: Int] = [:], pending = Queue()
        pending.push(.init(index: first, cost: 0, estimate: length([start, end])))
        while let next = pending.pop() {
            guard next.cost == costs[next.index] else { continue }
            if next.index == goal {
                var path = [end], current = goal
                while let parent = parents[current] { path.append(point(parent)); current = parent }
                return simplified(path.reversed())
            }
            let x = next.index % width, y = next.index / width, origin = point(next.index)
            let neighbors = [x > 0 ? next.index - 1 : nil, x + 1 < width ? next.index + 1 : nil,
                y > 0 ? next.index - width : nil, y + 1 < ys.count ? next.index + width : nil].compactMap { $0 }
            for neighbor in neighbors {
                let destination = point(neighbor)
                let cost = next.cost + length([origin, destination])
                guard cost < costs[neighbor, default: .infinity], clear(origin, destination, obstacles: obstacles) else { continue }
                parents[neighbor] = next.index; costs[neighbor] = cost
                pending.push(.init(index: neighbor, cost: cost, estimate: cost + length([destination, end])))
            }
        }
        // Overlapping manually placed cards can conceal a terminal completely.
        return nil
    }

    private struct Queue {
        struct Entry {
            let index: Int
            let cost: Double
            let estimate: Double
            func precedes(_ other: Entry) -> Bool {
                estimate == other.estimate ? index < other.index : estimate < other.estimate
            }
        }
        var entries: [Entry] = []
        mutating func push(_ entry: Entry) {
            entries.append(entry)
            var child = entries.count - 1
            while child > 0 {
                let parent = (child - 1) / 2
                guard entries[child].precedes(entries[parent]) else { break }
                entries.swapAt(child, parent); child = parent
            }
        }
        mutating func pop() -> Entry? {
            guard !entries.isEmpty else { return nil }
            entries.swapAt(0, entries.count - 1)
            let result = entries.removeLast()
            var parent = 0
            while parent * 2 + 1 < entries.count {
                let left = parent * 2 + 1, right = left + 1
                let child = right < entries.count && entries[right].precedes(entries[left]) ? right : left
                guard entries[child].precedes(entries[parent]) else { break }
                entries.swapAt(child, parent); parent = child
            }
            return result
        }
    }
}
