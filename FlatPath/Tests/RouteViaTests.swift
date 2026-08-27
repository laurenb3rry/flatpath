//  RouteViaTests.swift
//
//  Holds a steered route to what pressing a point on the map promises.
//
//  Four things. The route goes through the point. It still starts and ends
//  where the walk does — a stop is not a new destination, and the failure this
//  guards against is the one the gesture used to have. It is still a walkable
//  chain of real edges, because everything downstream indexes the route by edge
//  position. And it is still the kind of walk the walker chose: a flat option
//  steered through a point must come back flat, not direct under a flat name.
//
//  Stops are placed a few blocks to one side of a real route so that honouring
//  them means genuinely going somewhere else. A stop already on the line would
//  be satisfied by doing nothing.

import CoreLocation
import XCTest

@testable import FlatPath

final class RouteViaTests: XCTestCase {

    private static let trips: [(name: String, from: (Double, Double), to: (Double, Double))] = [
        ("Kearny to Nob Hill", (37.79060, -122.40380), (37.79435, -122.41837)),
        ("Castro to the Ferry Building", (37.76090, -122.43500), (37.79550, -122.39370)),
        ("SoMa to the Haight", (37.77850, -122.40560), (37.77000, -122.44690)),
        ("Marina to the Mission", (37.80200, -122.43600), (37.75950, -122.41830)),
    ]

    /// How far to one side of a route a test stop is placed, in degrees of
    /// latitude. Roughly three blocks — far enough that the route has to move.
    private static let sidestep = 0.0035

    private struct Walk {
        let name: String
        let route: RouteOption
    }

    private static var graph: WalkingGraph!
    private static var walks: [Walk] = []

    private var graph: WalkingGraph { Self.graph }
    private var walks: [Walk] { Self.walks }

    override class func setUp() {
        super.setUp()
        guard let loaded = try? GraphLoader.loadBundledGraph() else { return }
        graph = loaded

        // The flattest option rather than the first, because it is the one whose
        // character a naive re-plan would destroy.
        walks = trips.compactMap { trip in
            guard let start = loaded.nearestNode(toLatitude: trip.from.0, longitude: trip.from.1),
                  let goal = loaded.nearestNode(toLatitude: trip.to.0, longitude: trip.to.1),
                  let route = RouteOptions.between(start: start, destination: goal, in: loaded).last
            else { return nil }
            return Walk(name: trip.name, route: route)
        }
    }

    override func setUpWithError() throws {
        try XCTSkipIf(Self.graph == nil, "the bundled walking graph did not load")
        XCTAssertEqual(walks.count, Self.trips.count, "not every trip here routed")
    }

    /// A node a few blocks to one side of the middle of a route.
    ///
    /// Both sides are tried: one of them can fall in the bay or in a park with
    /// no paths, and a stop that does not snap to the network is not a test of
    /// anything here.
    private func sideStop(of route: RouteOption) -> Int? {
        let middle = route.nodes[route.nodes.count / 2]
        let latitude = graph.latitudes[middle]
        let longitude = graph.longitudes[middle]

        for offset in [Self.sidestep, -Self.sidestep] {
            guard let node = graph.nearestNode(
                toLatitude: latitude + offset,
                longitude: longitude,
                within: 200
            ) else { continue }
            if !route.nodes.contains(node) { return node }
        }
        return nil
    }

    private func stops() -> [(walk: Walk, stop: Int)] {
        walks.compactMap { walk in sideStop(of: walk.route).map { (walk, $0) } }
    }

    // MARK: What a pressed point promises

    /// Every trip here has somewhere off its route to be steered through.
    func testTheseTripsHaveSomewhereToSteerThrough() {
        XCTAssertEqual(
            stops().count, walks.count,
            "some trip has no node off its route to steer through, so it tests nothing"
        )
    }

    /// The route passes through the point, and the point is reported as
    /// reached.
    func testASteeredRoutePassesThroughTheStop() {
        for (walk, stop) in stops() {
            let steered = RouteVia.route(walk.route, through: [stop], in: graph)

            XCTAssertTrue(
                steered.reached.contains(stop),
                "\(walk.name): the stop was not reported as reached"
            )
            XCTAssertTrue(
                steered.nodes.contains(stop),
                "\(walk.name): the route does not go through the stop"
            )
            XCTAssertNotEqual(
                steered.nodes, walk.route.nodes,
                "\(walk.name): the route did not move to honour the stop"
            )
        }
    }

    /// Both ends of the trip survive. This is the whole point of the change:
    /// a press steers the walk, it does not replace where the walk is going.
    func testASteeredRouteKeepsBothEnds() {
        for (walk, stop) in stops() {
            let steered = RouteVia.route(walk.route, through: [stop], in: graph)

            XCTAssertEqual(
                steered.nodes.first, walk.route.nodes.first,
                "\(walk.name): steering moved the start"
            )
            XCTAssertEqual(
                steered.nodes.last, walk.route.nodes.last,
                "\(walk.name): steering moved the destination"
            )
        }
    }

    /// The result is a chain of real edges, one per pair of nodes.
    ///
    /// The legs are concatenated at shared nodes, and an off-by-one there would
    /// leave a route that draws with a jump in it and whose hill marks land on
    /// the wrong blocks.
    func testASteeredRouteIsWalkable() {
        for (walk, stop) in stops() {
            let steered = RouteVia.route(walk.route, through: [stop], in: graph)

            XCTAssertEqual(
                steered.edges.count, steered.nodes.count - 1,
                "\(walk.name): the edges do not join the nodes"
            )
            for (position, edge) in steered.edges.enumerated() {
                XCTAssertEqual(
                    graph.edge(from: steered.nodes[position], to: steered.nodes[position + 1]),
                    edge,
                    "\(walk.name): edge \(position) does not join the nodes it sits between"
                )
            }
        }
    }

    /// A flat route steered through a point comes back flat.
    ///
    /// The legs are planned with the settings that produced the card, so what
    /// comes back has to be no worse than what a neutral, direct-minded search
    /// would produce through the same point. Planned the wrong way this passes
    /// nothing: the walker would tap "Flattest", press a point, and be handed
    /// the direct way there under the flat route's name.
    func testSteeringKeepsTheRoutesCharacter() {
        let direct = WalkingCost(uphillSuffering: 0, ascentWeight: 0)

        for (walk, stop) in stops() {
            let steered = RouteVia.route(walk.route, through: [stop], in: graph)
            guard steered.reached.contains(stop) else { continue }

            let asPlanned = RouteMetrics(edges: steered.edges, in: graph)

            let neutral = RouteOption(
                id: walk.route.id,
                name: walk.route.name,
                nodes: walk.route.nodes,
                edges: walk.route.edges,
                metrics: walk.route.metrics,
                cost: direct
            )
            let asDirect = RouteVia.route(neutral, through: [stop], in: graph)
            guard asDirect.reached.contains(stop) else { continue }

            XCTAssertLessThanOrEqual(
                asPlanned.elevationGain,
                RouteMetrics(edges: asDirect.edges, in: graph).elevationGain,
                "\(walk.name): steering the flattest option climbed more than steering a direct one"
            )
        }
    }

    /// No stops leaves the planned route untouched, exactly.
    ///
    /// Taking a stop back is this call with the stop dropped from the list, so
    /// this is what makes tapping a dot put the walker back on the line they
    /// were shown rather than near it.
    func testNoStopsLeavesTheRouteAlone() {
        for walk in walks {
            let steered = RouteVia.route(walk.route, through: [], in: graph)

            XCTAssertEqual(steered.nodes, walk.route.nodes, "\(walk.name): an empty list moved the route")
            XCTAssertEqual(steered.edges, walk.route.edges, "\(walk.name): an empty list moved the edges")
            XCTAssertTrue(steered.reached.isEmpty, "\(walk.name): an empty list reached something")
        }
    }

    /// Two stops are both honoured, and the route reaches them in the order it
    /// walks rather than the order they were dropped.
    func testTwoStopsAreBothHonouredInTravelOrder() {
        for walk in walks {
            let quarter = walk.route.nodes[walk.route.nodes.count / 4]
            let threeQuarters = walk.route.nodes[3 * walk.route.nodes.count / 4]

            guard let early = offRoute(near: quarter, of: walk.route),
                  let late = offRoute(near: threeQuarters, of: walk.route)
            else { continue }

            // Dropped in the wrong order on purpose: the far one first.
            let ordered = RouteVia.insert(
                early,
                into: RouteVia.insert(late, into: [], along: walk.route.nodes, in: graph),
                along: walk.route.nodes,
                in: graph
            )
            XCTAssertEqual(
                ordered, [early, late],
                "\(walk.name): stops were not ordered along the route"
            )

            let steered = RouteVia.route(walk.route, through: ordered, in: graph)
            guard steered.reached.count == 2 else { continue }

            XCTAssertEqual(
                steered.reached, [early, late],
                "\(walk.name): the route did not reach the stops in travel order"
            )
            guard let first = steered.nodes.firstIndex(of: early),
                  let second = steered.nodes.firstIndex(of: late)
            else {
                XCTFail("\(walk.name): a reached stop is not on the route")
                continue
            }
            XCTAssertLessThan(first, second, "\(walk.name): the route reaches the stops out of order")
        }
    }

    /// A node a few blocks off the route, near a given point on it.
    private func offRoute(near node: Int, of route: RouteOption) -> Int? {
        let latitude = graph.latitudes[node]
        let longitude = graph.longitudes[node]

        for offset in [Self.sidestep, -Self.sidestep] {
            guard let found = graph.nearestNode(
                toLatitude: latitude + offset,
                longitude: longitude,
                within: 200
            ) else { continue }
            if !route.nodes.contains(found) { return found }
        }
        return nil
    }
}
