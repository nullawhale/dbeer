import Foundation

struct ERDiagramPath: Equatable {
    let start: CGPoint
    let segments: [ERDiagramPathSegment]
}

enum ERDiagramPathSegment: Equatable {
    case line(to: CGPoint)
    case curve(to: CGPoint, control1: CGPoint, control2: CGPoint)
}

extension ERDiagramRoute {
    /// Round the routed polyline locally, retaining its endpoints and terminal
    /// directions. A curve's entire control box must remain clear of cards.
    func roundedPath(zoom: Double, obstacles: [CGRect]) -> ERDiagramPath? {
        guard zoom.isFinite, zoom > 0, let start = points.first else { return nil }
        var segments: [ERDiagramPathSegment] = []
        var cursor = start
        func appendLine(_ point: CGPoint) {
            if cursor != point { segments.append(.line(to: point)); cursor = point }
        }
        let protectedCards = obstacles.map { $0.insetBy(dx: -1.5 / zoom, dy: -1.5 / zoom) }
        let kappa = 0.5522847498307936
        for index in points.indices.dropFirst().dropLast() {
            let previous = points[index - 1], corner = points[index], next = points[index + 1]
            let incomingLength = hypot(corner.x - previous.x, corner.y - previous.y)
            let outgoingLength = hypot(next.x - corner.x, next.y - corner.y)
            guard incomingLength > 0, outgoingLength > 0,
                  (previous.x == corner.x || previous.y == corner.y),
                  (next.x == corner.x || next.y == corner.y) else { appendLine(corner); continue }
            let incoming = CGPoint(x: (corner.x - previous.x) / incomingLength, y: (corner.y - previous.y) / incomingLength)
            let outgoing = CGPoint(x: (next.x - corner.x) / outgoingLength, y: (next.y - corner.y) / outgoingLength)
            guard incoming.x * outgoing.x + incoming.y * outgoing.y == 0 else { appendLine(corner); continue }
            var radius = min(16, incomingLength / 2, outgoingLength / 2)
            if index == 1 { radius = min(radius, max(0, incomingLength - 6 / zoom)) }
            if index == points.count - 2 { radius = min(radius, max(0, outgoingLength - 14 / zoom)) }
            func ends(_ radius: Double) -> (CGPoint, CGPoint) {
                (CGPoint(x: corner.x - incoming.x * radius, y: corner.y - incoming.y * radius),
                 CGPoint(x: corner.x + outgoing.x * radius, y: corner.y + outgoing.y * radius))
            }
            while radius >= 0.25 {
                let (entry, exit) = ends(radius)
                let box = CGRect(x: min(entry.x, exit.x), y: min(entry.y, exit.y),
                    width: abs(exit.x - entry.x), height: abs(exit.y - entry.y))
                if !protectedCards.contains(where: { $0.intersects(box) }) { break }
                radius /= 2
            }
            guard radius >= 0.25 else { appendLine(corner); continue }
            let (entry, exit) = ends(radius)
            appendLine(entry)
            segments.append(.curve(to: exit,
                control1: CGPoint(x: entry.x + incoming.x * radius * kappa, y: entry.y + incoming.y * radius * kappa),
                control2: CGPoint(x: exit.x - outgoing.x * radius * kappa, y: exit.y - outgoing.y * radius * kappa)))
            cursor = exit
        }
        if let end = points.last { appendLine(end) }
        return ERDiagramPath(start: start, segments: segments)
    }
}
