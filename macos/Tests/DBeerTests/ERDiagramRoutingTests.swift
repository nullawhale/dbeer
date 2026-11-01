import Foundation
import Testing
@testable import DBeer

/// Pure geometry: these checks never create windows or access databases.
struct ERDiagramRoutingTests {
    private func table(_ name: String, profile: UUID) -> ERTableID {
        .init(profileID: profile, schema: "fixture", name: name)
    }
    private func edge(_ source: ERTableID, _ target: ERTableID, name: String = "fk") -> ERRelationship {
        .init(source: source, key: .init(name: name, target: target.reference,
            columns: [.init(source: "parent_id", target: "id", position: 1)]))
    }
    private func facts(_ table: ERTableID) -> ERTableMetadata {
        .init(table: table, columns: [
            .init(name: "id", nativeType: "integer", nullable: false, primaryKeyPosition: 1),
            .init(name: "parent_id", nativeType: "integer", nullable: true, primaryKeyPosition: nil)
        ], columnState: .available)
    }
    private func checkClear(_ route: ERDiagramRoute, geometry: ERDiagramRouting.Geometry,
                            sourceLocation: SourceLocation = #_sourceLocation) {
        #expect(route.points.count >= 2, sourceLocation: sourceLocation)
        for (a, b) in zip(route.points, route.points.dropFirst()) {
            #expect(a != b && (a.x == b.x || a.y == b.y), sourceLocation: sourceLocation)
            for placement in geometry.placements {
                let rect = CGRect(x: placement.point.x, y: placement.point.y, width: ERDiagramLayout.width,
                    height: ERDiagramLayout.height(geometry.metadata[placement.table], collapsed: geometry.collapsed.contains(placement.table)))
                let crossesInterior: Bool
                if a.x == b.x {
                    crossesInterior = a.x > rect.minX && a.x < rect.maxX && max(a.y, b.y) > rect.minY && min(a.y, b.y) < rect.maxY
                } else {
                    crossesInterior = a.y > rect.minY && a.y < rect.maxY && max(a.x, b.x) > rect.minX && min(a.x, b.x) < rect.maxX
                }
                #expect(!crossesInterior, sourceLocation: sourceLocation)
            }
        }
    }

    @Test func crampedManualArrangementKeepsCardsFixedAndRoutesThroughSpaciousSides() throws {
        let profile = UUID(), parent = table("breweries", profile: profile), child = table("beers", profile: profile), orders = table("orders", profile: profile)
        let geometry = ERDiagramRouting.Geometry(tables: [parent, child, orders], placements: [
            .init(table: parent, point: .init(x: 25, y: 45)), .init(table: child, point: .init(x: 380, y: 45)),
            .init(table: orders, point: .init(x: 380, y: 370))
        ], metadata: [parent: facts(parent), child: facts(child), orders: facts(orders)], collapsed: [])
        let relationships = [edge(child, parent), edge(orders, child)]
        let routes = ERDiagramRouting.routes(geometry, relationships: relationships)
        #expect(routes.count == 2)
        for route in routes { checkClear(route, geometry: geometry) }
        for route in routes {
            let start = try #require(route.points.first), end = try #require(route.points.last)
            #expect(abs(route.points[1].x - start.x) >= ERDiagramRouting.terminalLead)
            #expect(abs(route.points[route.points.count - 2].x - end.x) >= ERDiagramRouting.terminalLead)
        }
        #expect(geometry.placements[0].point == ERPoint(x: 25, y: 45))
        #expect(geometry.placements[1].point == ERPoint(x: 380, y: 45))
    }

    @Test func interveningCardsRequireDetoursInsteadOfHiddenCrossings() throws {
        let profile = UUID()
        let tables = (0..<5).map { table("t\($0)", profile: profile) }
        let geometry = ERDiagramRouting.Geometry(tables: tables, placements: [
            .init(table: tables[0], point: .init(x: 0, y: 400)),
            .init(table: tables[1], point: .init(x: 1600, y: 400)),
            .init(table: tables[2], point: .init(x: 800, y: 370)),
            .init(table: tables[3], point: .init(x: 350, y: 100)),
            .init(table: tables[4], point: .init(x: 350, y: 650))
        ], metadata: [:], collapsed: [])
        let routes = ERDiagramRouting.routes(geometry, relationships: [edge(tables[0], tables[1])])
        let route = try #require(routes.first)
        checkClear(route, geometry: geometry)
        #expect(route.points.contains { $0.y < 370 || $0.y > 482 })
        #expect(route.points.count >= 4)
    }

    @Test func selfParallelAndCyclicEdgesRemainDirectedAndFitWithTheirDetours() throws {
        let profile = UUID(), a = table("a", profile: profile), b = table("b", profile: profile)
        let geometry = ERDiagramRouting.Geometry(tables: [a, b], placements: [
            .init(table: a, point: .init(x: 0, y: 0)), .init(table: b, point: .init(x: 0, y: 300))
        ], metadata: [a: facts(a), b: facts(b)], collapsed: [])
        let relationships = [edge(a, a), edge(a, b), edge(a, b, name: "other"), edge(b, a)]
        let routes = ERDiagramRouting.routes(geometry, relationships: relationships)
        #expect(routes.count == 4 && Set(routes.map(\.relationshipID)).count == 4)
        #expect(routes == ERDiagramRouting.routes(geometry, relationships: relationships.reversed()))
        let parallel = routes.filter { $0.relationshipID == relationships[1].id || $0.relationshipID == relationships[2].id }
        #expect(parallel[0].points != parallel[1].points)
        let fitted = ERDiagramLayout.fit(geometry.placements, metadata: geometry.metadata, collapsed: [],
            size: CGSize(width: 800, height: 700), routes: routes)
        for route in routes {
            checkClear(route, geometry: geometry)
            for point in route.points {
                let screen = fitted.screen(.init(x: point.x, y: point.y))
                #expect((20...780).contains(screen.x) && (20...680).contains(screen.y))
            }
        }
    }

    @Test func concealedTerminalsNeverFallBackToLinesThroughOverlappingCards() {
        let profile = UUID(), a = table("a", profile: profile), b = table("b", profile: profile)
        let geometry = ERDiagramRouting.Geometry(tables: [a, b], placements: [
            .init(table: a, point: .init()), .init(table: b, point: .init())
        ], metadata: [:], collapsed: [])
        #expect(ERDiagramRouting.routes(geometry, relationships: [edge(a, b)]).isEmpty)
    }

    @Test(arguments: [0.2, 0.88, 1.0, 3.0])
    func arrowheadsKeepTheirScreenSizeAndDirectionWithReservedTerminalSegments(zoom: Double) throws {
        for direction in [-1.0, 1.0] {
            let tip = CGPoint(x: 200, y: 100)
            let route = ERDiagramRoute(relationshipID: "fixture", points: [
                CGPoint(x: tip.x - direction * 80, y: tip.y), tip
            ])
            let head = route.arrowhead(zoom: zoom, obstacles: [])
            #expect(head.count == 3 && head.first == tip)
            let base = try #require(head.dropFirst().first)
            #expect(abs(abs(base.x - tip.x) * zoom - 12) < 0.00001)
            #expect(abs(abs(head[2].y - base.y) * zoom - 10) < 0.00001)
            #expect((tip.x - base.x) * direction > 0)
        }
    }

    @Test func arrowheadsNeverExtendPastTheLastBendOrIntoNeighboringCards() throws {
        let route = ERDiagramRoute(relationshipID: "fixture", points: [
            CGPoint(x: 380, y: 126), CGPoint(x: 370, y: 126), CGPoint(x: 370, y: 104), CGPoint(x: 365, y: 104)
        ])
        let cards = [CGRect(x: 25, y: 45, width: 340, height: 156), CGRect(x: 380, y: 45, width: 340, height: 222)]
        let zoom = 0.88
        let head = route.arrowhead(zoom: zoom, obstacles: cards)
        let base = try #require(head.dropFirst().first)
        #expect(base.x > 365 && base.x < 370)
        #expect(head.allSatisfy { $0.x >= 365 && $0.x < 370 })
        let crowded = route.arrowhead(zoom: 0.2, obstacles: cards)
        #expect(crowded.count == 3 && crowded.allSatisfy { $0.x >= 365 && $0.x < 370 })
    }

    @Test func autoLayoutReservesStraightTerminalsForFullSizeArrowsAtEveryZoom() throws {
        let profile = UUID(), parent = table("breweries", profile: profile), child = table("beers", profile: profile), orders = table("orders", profile: profile)
        let tables = [parent, child, orders]
        let metadata = Dictionary(uniqueKeysWithValues: tables.map { ($0, facts($0)) })
        let relationships = [edge(child, parent), edge(orders, child)]
        let placements = ERDiagramLayout.positions(tables: tables, relationships: relationships, metadata: metadata, preserving: [], collapsed: [])
        let geometry = ERDiagramRouting.Geometry(tables: tables, placements: placements, metadata: metadata, collapsed: [])
        let routes = ERDiagramRouting.routes(geometry, relationships: relationships)
        #expect(routes.count == 2)
        let cards = placements.map { CGRect(x: $0.point.x, y: $0.point.y, width: ERDiagramLayout.width, height: ERDiagramLayout.height(metadata[$0.table], collapsed: false)) }
        for route in routes {
            checkClear(route, geometry: geometry)
            let tip = try #require(route.points.last)
            let bend = route.points[route.points.count - 2]
            #expect(abs(tip.x - bend.x) >= ERDiagramRouting.terminalLead)
            for zoom in [0.2, 0.5, 0.88, 1.0, 3.0] {
                let head = route.arrowhead(zoom: zoom, obstacles: cards)
                let base = try #require(head.dropFirst().first)
                #expect(abs(abs(base.x - tip.x) * zoom - 12) < 0.00001)
                #expect(abs(base.x - tip.x) < abs(bend.x - tip.x))
            }
        }
    }

    @Test func incompleteRoutesAndInvalidZoomNeverCreateArrowheads() {
        for points in [[CGPoint](), [CGPoint.zero], [CGPoint.zero, CGPoint.zero], [CGPoint.zero, CGPoint(x: 1, y: 1)]] {
            #expect(ERDiagramRoute(relationshipID: "fixture", points: points).arrowhead(zoom: 1, obstacles: []).isEmpty)
        }
        let route = ERDiagramRoute(relationshipID: "fixture", points: [.zero, CGPoint(x: 10, y: 0)])
        for zoom in [0, -1, Double.nan, .infinity] { #expect(route.arrowhead(zoom: zoom, obstacles: []).isEmpty) }
    }

    @MainActor
    @Test func movingAndCollapsingCardsRefreshGeometryWhilePanAndZoomPreserveRoutes() throws {
        let profile = UUID(), a = table("a", profile: profile), b = table("b", profile: profile)
        let model = ERDiagramModel(stored: .init(profileID: profile, engine: .postgresql, database: "fixture", tables: [a, b]))
        var source = facts(a); source.foreignKeys = [edge(a, b).key]; source.relationshipState = .available
        model.setMetadata(source); model.setMetadata(facts(b))
        model.move(a, to: .init()); model.move(b, to: .init(x: 500, y: 100))
        let original = model.relationshipRoutes
        #expect(original.count == 1)
        model.stored.viewport = .init(zoom: 2, pan: .init(x: 300, y: -200))
        #expect(model.relationshipRoutes == original)
        model.move(b, to: .init(x: -500, y: 100))
        #expect(model.relationshipRoutes != original)
        var many = facts(a)
        many.columns = (0..<20).map { .init(name: $0 == 19 ? "parent_id" : "c\($0)", nativeType: "integer", nullable: true, primaryKeyPosition: nil) }
        many.foreignKeys = source.foreignKeys; many.relationshipState = .available
        model.setMetadata(many)
        let expanded = try #require(model.relationshipRoutes.first?.points.first)
        model.toggleCollapse(a)
        #expect(model.relationshipRoutes.first?.points.first?.y != expanded.y)
    }

    @Test func boundedThousandRelationshipGraphRoutesWithoutCrossingCards() {
        let profile = UUID(), clock = ContinuousClock(), start = clock.now
        let tables = (0..<100).map { table("t\($0)", profile: profile) }
        let geometry = ERDiagramRouting.Geometry(tables: tables, placements: tables.enumerated().map {
            .init(table: $0.element, point: .init(x: Double($0.offset % 10) * 440, y: Double($0.offset / 10) * 200))
        }, metadata: [:], collapsed: [])
        let edges = (0..<1000).map { edge(tables[$0 % 100], tables[($0 * 7 + 1) % 100], name: "fk\($0)") }
        let routes = ERDiagramRouting.routes(geometry, relationships: edges)
        #expect(start.duration(to: clock.now) < .seconds(10))
        #expect(routes.count == 1000)
        for route in routes { checkClear(route, geometry: geometry) }
    }

    @MainActor
    @Test func refreshedCanonicallyEquivalentColumnNamesStillInvalidateAnchors() throws {
        let profile = UUID(), a = table("a", profile: profile), b = table("b", profile: profile)
        let model = ERDiagramModel(stored: .init(profileID: profile, engine: .postgresql, database: "fixture", tables: [a, b]))
        var source = facts(a)
        source.columns = [.init(name: "é", nativeType: "integer", nullable: true, primaryKeyPosition: nil)]
        source.foreignKeys = [.init(name: "fk", target: b.reference, columns: [.init(source: "é", target: "id", position: 1)])]
        source.relationshipState = .available
        model.setMetadata(source); model.setMetadata(facts(b))
        model.move(a, to: .init()); model.move(b, to: .init(x: 500, y: 0))
        let original = try #require(model.relationshipRoutes.first?.points.first)
        source.columns = [.init(name: "e\u{301}", nativeType: "integer", nullable: true, primaryKeyPosition: nil)]
        model.setMetadata(source)
        #expect(model.relationshipRoutes.first?.points.first?.y != original.y)
    }

    @MainActor
    @Test func removingATableClearsRelationshipFocusForEitherEndpoint() {
        for removeSource in [true, false] {
            let profile = UUID(), a = table("a", profile: profile), b = table("b", profile: profile)
            let model = ERDiagramModel(stored: .init(profileID: profile, engine: .postgresql, database: "fixture", tables: [a, b]))
            var source = facts(a)
            let relationship = edge(a, b)
            source.foreignKeys = [relationship.key]; source.relationshipState = .available
            model.setMetadata(source); model.selectedRelationshipID = relationship.id
            #expect(model.selectedRelationship != nil)
            model.remove(removeSource ? a : b)
            #expect(model.selectedRelationshipID == nil)
        }
    }
}
