import Foundation
import Testing
@testable import DBeer

/// Presentation geometry only: no windows, databases or desktop interaction.
struct ERDiagramCurveTests {
    private func endpoint(_ segment: ERDiagramPathSegment) -> CGPoint {
        switch segment {
        case .line(let point), .curve(let point, _, _): point
        }
    }

    private func samples(_ path: ERDiagramPath) -> [CGPoint] {
        var points = [path.start], cursor = path.start
        for segment in path.segments {
            let end = endpoint(segment)
            for index in 1...40 {
                let t = Double(index) / 40, u = 1 - t
                switch segment {
                case .line:
                    points.append(CGPoint(x: cursor.x + (end.x - cursor.x) * t, y: cursor.y + (end.y - cursor.y) * t))
                case .curve(_, let a, let b):
                    points.append(CGPoint(x: u*u*u*cursor.x + 3*u*u*t*a.x + 3*u*t*t*b.x + t*t*t*end.x,
                        y: u*u*u*cursor.y + 3*u*u*t*a.y + 3*u*t*t*b.y + t*t*t*end.y))
                }
            }
            cursor = end
        }
        return points
    }

    private func inside(_ point: CGPoint, _ rect: CGRect) -> Bool {
        point.x > rect.minX + 0.00001 && point.x < rect.maxX - 0.00001 &&
            point.y > rect.minY + 0.00001 && point.y < rect.maxY - 0.00001
    }

    private func checkTangency(_ path: ERDiagramPath) {
        var cursor = path.start, previousDirection: CGPoint?, previousWasCurve = false
        func sameDirection(_ a: CGPoint, _ b: CGPoint) -> Bool {
            abs(a.x * b.y - a.y * b.x) < 0.00001 && a.x * b.x + a.y * b.y > 0
        }
        for segment in path.segments {
            let end = endpoint(segment)
            switch segment {
            case .line:
                let direction = CGPoint(x: end.x - cursor.x, y: end.y - cursor.y)
                #expect(direction != .zero)
                if previousWasCurve, let previousDirection { #expect(sameDirection(previousDirection, direction)) }
                previousDirection = direction; previousWasCurve = false
            case .curve(_, let a, let b):
                let incoming = CGPoint(x: a.x - cursor.x, y: a.y - cursor.y)
                let outgoing = CGPoint(x: end.x - b.x, y: end.y - b.y)
                #expect(incoming != .zero && outgoing != .zero)
                if let previousDirection { #expect(sameDirection(previousDirection, incoming)) }
                previousDirection = outgoing; previousWasCurve = true
            }
            cursor = end
        }
    }

    private func checkTerminal(_ path: ERDiagramPath, route: ERDiagramRoute, zoom: Double) throws {
        let last = try #require(path.segments.last)
        guard case .line(let tip) = last else { Issue.record("The arrow must end on a straight segment"); return }
        let previous = path.segments.count > 1 ? endpoint(path.segments[path.segments.count - 2]) : path.start
        #expect(tip == route.points.last && tip.y == previous.y)
        #expect(abs(tip.x - previous.x) * zoom >= 14 - 0.00001)
        let head = route.arrowhead(zoom: zoom, obstacles: [])
        let base = try #require(head.dropFirst().first)
        #expect(abs(tip.x - base.x) < abs(tip.x - previous.x))
    }

    @Test func roundedCornersJoinStraightSegmentsTangentiallyWithoutMovingPorts() throws {
        let route = ERDiagramRoute(relationshipID: "fixture", points: [
            .zero, CGPoint(x: 100, y: 0), CGPoint(x: 100, y: 100), CGPoint(x: 200, y: 100)
        ])
        let path = try #require(route.roundedPath(zoom: 1, obstacles: []))
        #expect(path.start == .zero && path.segments.last.map(endpoint) == route.points.last)
        #expect(path.segments.filter { if case .curve = $0 { true } else { false } }.count == 2)
        checkTangency(path)
        #expect(samples(path).contains { $0.x < 100 && $0.y > 0 })
        try checkTerminal(path, route: route, zoom: 1)
    }

    @Test func adjacentShortCornersStayContinuousAndNeverBacktrack() throws {
        let route = ERDiagramRoute(relationshipID: "fixture", points: [
            .zero, CGPoint(x: 100, y: 0), CGPoint(x: 100, y: 8), CGPoint(x: 110, y: 8),
            CGPoint(x: 110, y: 100), CGPoint(x: 210, y: 100)
        ])
        let path = try #require(route.roundedPath(zoom: 1, obstacles: []))
        let points = samples(path)
        #expect(path.start == .zero && points.last == route.points.last)
        #expect(path.segments.contains { if case .curve = $0 { true } else { false } })
        for (a, b) in zip(points, points.dropFirst()) { #expect(b.x >= a.x - 0.00001 && b.y >= a.y - 0.00001) }
        checkTangency(path)
    }

    @Test(arguments: [0.2, 0.5, 0.88, 1.0, 3.0])
    func everyZoomRetainsAStraightArrowApproach(zoom: Double) throws {
        let route = ERDiagramRoute(relationshipID: "fixture", points: [
            .zero, CGPoint(x: 100, y: 0), CGPoint(x: 100, y: 100), CGPoint(x: 172, y: 100)
        ])
        let path = try #require(route.roundedPath(zoom: zoom, obstacles: []))
        checkTangency(path)
        try checkTerminal(path, route: route, zoom: zoom)
    }

    @Test func shortSourceLeadKeepsRoomForItsPortMarker() throws {
        let route = ERDiagramRoute(relationshipID: "fixture", points: [
            .zero, CGPoint(x: 12, y: 0), CGPoint(x: 12, y: 80), CGPoint(x: 100, y: 80)
        ])
        let path = try #require(route.roundedPath(zoom: 1, obstacles: []))
        let first = try #require(path.segments.first)
        guard case .line(let end) = first else { Issue.record("The source port requires a straight lead"); return }
        #expect(end.y == 0 && end.x >= 6)
        checkTangency(path)
    }

    @Test func obstacleBesideACornerReducesRoundingInsteadOfCuttingThroughTheCard() throws {
        let route = ERDiagramRoute(relationshipID: "fixture", points: [
            .zero, CGPoint(x: 100, y: 0), CGPoint(x: 100, y: 100), CGPoint(x: 200, y: 100)
        ])
        let obstacle = CGRect(x: 90, y: 2, width: 7, height: 8)
        let unrestricted = try #require(route.roundedPath(zoom: 1, obstacles: []))
        #expect(samples(unrestricted).contains { inside($0, obstacle) })
        let protected = try #require(route.roundedPath(zoom: 1, obstacles: [obstacle]))
        #expect(samples(protected).allSatisfy { !inside($0, obstacle) })
        #expect(protected != unrestricted)
        checkTangency(protected)
    }

    @Test func roundedSelfAndCyclicRoutesStayOutsideEveryCard() throws {
        let profile = UUID()
        let tables = ["a", "b", "c"].map { ERTableID(profileID: profile, schema: "fixture", name: $0) }
        let placements: [ERPlacement] = [
            .init(table: tables[0], point: .init()), .init(table: tables[1], point: .init(x: 600, y: 0)),
            .init(table: tables[2], point: .init(x: 600, y: 400))
        ]
        let pairs = [(0, 0), (0, 1), (1, 2), (2, 0)]
        let edges = pairs.enumerated().map { index, pair in
            ERRelationship(source: tables[pair.0], key: .init(name: "fk\(index)", target: tables[pair.1].reference,
                columns: [.init(source: "parent_id", target: "id", position: 1)]))
        }
        let geometry = ERDiagramRouting.Geometry(tables: tables, placements: placements, metadata: [:], collapsed: [])
        let cards = placements.map { CGRect(x: $0.point.x, y: $0.point.y, width: ERDiagramLayout.width,
            height: ERDiagramLayout.height(nil, collapsed: false)) }
        let routes = ERDiagramRouting.routes(geometry, relationships: edges)
        #expect(routes.count == edges.count)
        for route in routes {
            for zoom in [0.2, 1.0, 3.0] {
                let path = try #require(route.roundedPath(zoom: zoom, obstacles: cards))
                #expect(path.start == route.points.first && path.segments.last.map(endpoint) == route.points.last)
                #expect(samples(path).allSatisfy { point in cards.allSatisfy { !inside(point, $0) } })
                checkTangency(path)
                try checkTerminal(path, route: route, zoom: zoom)
            }
        }
    }
}
