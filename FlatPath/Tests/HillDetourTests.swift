//  HillDetourTests.swift
//
//  Holds a refused hill to what refusing it promises.
//
//  A tap on a marked stretch says one thing — not this hill — and the promise
//  behind it has four parts. The route that comes back must still be a route:
//  every consecutive pair of nodes joined by a real edge, still starting and
//  ending where the walk does. It must not contain the hill. It must be local,
//  so that the walker who objected to one block is not handed a different trip.
//  And it must be undoable, exactly: dropping the refusal has to give back the
//  route that was planned, node for node.
//
//  These run against the bundled graph over real climbs, found by asking the
//  planner for a route and marking it the way the map does. That is deliberate.
//  A hand-built hill would test the splice and prove nothing about whether this
//  city has a way round any of the hills the app actually draws.
//
//  Planning is done once for the whole file rather than per test. A route over
//  a city-sized graph is a couple of dozen searches, and re-running them for
//  each property below would spend minutes proving the same five routes.

import CoreLocation
import XCTest

@testable import FlatPath

final class HillDetourTests: XCTestCase {

    /// Trips over ground that is unambiguously hilly, so there is something on
    /// each of them to refuse.
    private static let trips: [(name: String, from: (Double, Double), to: (Double, Double))] = [
        ("Kearny to Nob Hill", (37.79060, -122.40380), (37.79435, -122.41837)),
        ("Mission to Nob Hill", (37.75220, -122.41840), (37.79290, -122.41610)),
        ("Embarcadero to Coit Tower", (37.79550, -122.39370), (37.80250, -122.40580)),
        ("Castro to the Ferry Building", (37.76090, -122.43500), (37.79550, -122.39370)),
        ("Sunset to Twin Peaks", (37.76000, -122.49000), (37.75440, -122.44770)),
    ]

    /// One trip, planned, with the stretches the map would mark on it.
    private struct Walk {
        let name: String
        let route: RouteOption
        let hills: [AvoidedHill]
    }

    private static var graph: WalkingGraph!
    private static var walks: [Walk] = []

    private var graph: WalkingGraph { Self.graph }
    private var walks: [Walk] { Self.walks }

    override class func setUp() {
        super.setUp()
        guard let loaded = try? GraphLoader.loadBundledGraph() else { return }
        graph = loaded
        walks = trips.compactMap { trip in
            guard let start = loaded.nearestNode(toLatitude: trip.from.0, longitude: trip.from.1),
                  let goal = loaded.nearestNode(toLatitude: trip.to.0, longitude: trip.to.1),
                  let route = RouteOptions.between(start: start, destination: goal, in: loaded).first
            else { return nil }
            return Walk(name: trip.name, route: route, hills: hills(of: route, in: loaded))
        }
    }

    override func setUpWithError() throws {
        try XCTSkipIf(Self.graph == nil, "the bundled walking graph did not load")
        XCTAssertEqual(walks.count, Self.trips.count, "not every trip here routed")
    }

    /// The stretches of a route the map marks, found the same way the map finds
    /// them: runs of neighbouring edges in a band worth warning about.
    private static func hills(of route: RouteOption, in graph: WalkingGraph) -> [AvoidedHill] {
        func band(of edge: Int) -> Grade {
            Grade(
                rise: Double(graph.edgeDeltaElevation[edge]),
                over: Double(graph.edgeLength[edge])
            )
        }

        var hills: [AvoidedHill] = []
        var position = 0

        while position < route.edges.count {
            let grade = band(of: route.edges[position])
            guard grade.isWorthWarningAbout else {
                position += 1
                continue
            }

            var last = position
            while last + 1 < route.edges.count, band(of: route.edges[last + 1]) == grade {
                last += 1
            }

            hills.append(
                AvoidedHill(id: hills.count, nodes: Array(route.nodes[position ... last + 1]), grade: grade)
            )
            position = last + 1
        }

        return hills
    }

    /// Every hill of every trip, as a flat list of cases to check.
    private func refusals() -> [(walk: Walk, hill: AvoidedHill)] {
        walks.flatMap { walk in walk.hills.map { (walk, $0) } }
    }

    private func length(of edges: some Sequence<Int>) -> Double {
        edges.reduce(0.0) { $0 + Double(graph.edgeLength[$1]) }
    }

    private func steepest(_ edges: some Sequence<Int>) -> Double {
        edges.reduce(0.0) { steepest, edge in
            max(steepest, WalkingCost.slope(
                rise: Double(graph.edgeDeltaElevation[edge]),
                over: Double(graph.edgeLength[edge])
            ))
        }
    }

    // MARK: What a refusal promises

    /// Every trip here has something on it to refuse.
    ///
    /// Guards the rest of this file: each of the tests below passes trivially
    /// on a route with no marked stretch, and a change that stopped marking
    /// hills would quietly turn all of them green.
    func testTheseTripsHaveHillsToRefuse() {
        for walk in walks {
            XCTAssertFalse(
                walk.hills.isEmpty,
                "\(walk.name): nothing on this route is marked, so there is nothing to test"
            )
        }
    }

    /// At least some of the hills the app draws can actually be routed around.
    ///
    /// The feature is a tap that does something, and every other test here
    /// forgives a hill with no way round. This one does not: if the answer were
    /// always "no easier way nearby", they would all pass and the tap would do
    /// nothing anywhere in the city.
    func testHillsCanBeRoutedAround() {
        let routable = refusals().filter { refusal in
            HillDetour.apply([refusal.hill], to: refusal.walk.route, in: graph)
                .applied.contains(refusal.hill.id)
        }

        XCTAssertGreaterThan(routable.count, 0, "no hill on any of these trips could be routed around")
    }

    /// A detoured route is still a route: a chain of real edges from the start
    /// to the destination.
    ///
    /// The splice replaces a run of nodes and the run of edges between them at
    /// once, and getting either bound wrong leaves a route that draws as a line
    /// with a jump in it and navigates as directions through a wall.
    func testARefusedHillLeavesAWalkableRoute() {
        for (walk, hill) in refusals() {
            let detoured = HillDetour.apply([hill], to: walk.route, in: graph)
            let context = "\(walk.name), hill at node \(hill.nodes[0])"

            XCTAssertEqual(detoured.nodes.first, walk.route.nodes.first, "\(context): moved the start")
            XCTAssertEqual(detoured.nodes.last, walk.route.nodes.last, "\(context): moved the destination")
            XCTAssertEqual(
                detoured.edges.count, detoured.nodes.count - 1,
                "\(context): the edges do not join the nodes"
            )
            XCTAssertEqual(
                detoured.detouredBy.count, detoured.edges.count,
                "\(context): every edge has to say whether it is new"
            )

            for (position, edge) in detoured.edges.enumerated() {
                XCTAssertEqual(
                    graph.edge(from: detoured.nodes[position], to: detoured.nodes[position + 1]),
                    edge,
                    "\(context): edge \(position) does not join the nodes it sits between"
                )
            }
        }
    }

    /// A hill the route was sent around is not on the route any more, in either
    /// direction.
    ///
    /// Only checked where the detour was actually found. Some hills have no way
    /// round — a hillside with no level street across it is ordinary here — and
    /// `applied` is how that is reported rather than hidden.
    func testARefusedHillIsGone() {
        for (walk, hill) in refusals() {
            let detoured = HillDetour.apply([hill], to: walk.route, in: graph)
            guard detoured.applied.contains(hill.id) else { continue }

            let walked = Set(detoured.edges)
            for (from, to) in zip(hill.nodes, hill.nodes.dropFirst()) {
                if let uphill = graph.edge(from: from, to: to) {
                    XCTAssertFalse(walked.contains(uphill), "\(walk.name): still climbs the refused hill")
                }
                if let downhill = graph.edge(from: to, to: from) {
                    XCTAssertFalse(
                        walked.contains(downhill),
                        "\(walk.name): walks the refused hill in the other direction"
                    )
                }
            }
        }
    }

    /// The way round replaces the hill and its approaches, and nothing else.
    ///
    /// Stated as the ground the detour took away rather than as a share of the
    /// route, because that is the bound the algorithm actually promises: the
    /// hill, plus `approachReach` on either side of it, plus at most the one
    /// edge each approach overshoots by as it counts out to that distance.
    func testTheWayRoundIsLocal() {
        for (walk, hill) in refusals() {
            let detoured = HillDetour.apply([hill], to: walk.route, in: graph)
            guard detoured.applied.contains(hill.id) else { continue }

            let abandoned = Set(walk.route.edges).subtracting(detoured.edges)
            let overshoot = abandoned.map { Double(graph.edgeLength[$0]) }.max() ?? 0
            let allowed = length(of: graph.edges(along: hill.nodes))
                + 2 * (HillDetour.approachReach + overshoot)

            XCTAssertLessThanOrEqual(
                length(of: abandoned), allowed,
                "\(walk.name): refusing one hill took away more route than the window it is allowed"
            )
            XCTAssertGreaterThan(
                detoured.detouredBy.filter { $0 != nil }.count, 0,
                "\(walk.name): the route changed but nothing is marked as the new stretch"
            )
        }
    }

    /// The way round is easier ground than the stretch it replaced — gentler,
    /// or less climbing, or both. A detour that is neither is not worth the
    /// walk.
    ///
    /// Compared stretch against stretch, not route against route, because that
    /// is the promise being made. A route's total climb can rise when a hill is
    /// refused and that is the correct answer, not a bug: the ends of a climb
    /// sit where they sit, and a gentler way up between the same two heights
    /// gains every meter the steep way did, over more ground. What the walker
    /// asked for was to not walk up that, and less steep is what answers them.
    ///
    /// The whole trip is still held to the detour budget, which is the one
    /// thing that has to stay true end to end: refusing a hill can lengthen a
    /// walk, but not turn it into a different afternoon.
    func testTheWayRoundIsEasier() {
        for (walk, hill) in refusals() {
            let detoured = HillDetour.apply([hill], to: walk.route, in: graph)
            guard detoured.applied.contains(hill.id) else { continue }

            let abandoned = Set(walk.route.edges).subtracting(detoured.edges)
            let taken = Set(detoured.edges).subtracting(walk.route.edges)
            guard !abandoned.isEmpty, !taken.isEmpty else { continue }

            let gentler = steepest(taken) < steepest(abandoned)
            let lessClimb = climb(of: taken) < climb(of: abandoned)

            XCTAssertTrue(
                gentler || lessClimb,
                """
                \(walk.name): the new stretch is neither gentler nor less climbing than the one it \
                replaced — steepest \(steepest(taken)) against \(steepest(abandoned)), \
                climbing \(climb(of: taken))m against \(climb(of: abandoned))m
                """
            )

            let before = RouteMetrics(edges: walk.route.edges, in: graph)
            let after = RouteMetrics(edges: detoured.edges, in: graph)
            XCTAssertLessThanOrEqual(
                after.time,
                before.time * HillDetour.longestDetour + HillDetour.detourAllowance,
                "\(walk.name): the way round costs more time than a detour is allowed"
            )
        }
    }

    /// Meters climbed over a set of edges. Ascents only, as everywhere else.
    private func climb(of edges: some Sequence<Int>) -> Double {
        edges.reduce(0.0) { $0 + max(0, Double(graph.edgeDeltaElevation[$1])) }
    }

    /// Taking a refusal back gives the planned route, exactly.
    ///
    /// This is the whole reason the detours are rebuilt from the original
    /// instead of edited in place, and it is the half of the feature a walker
    /// notices immediately if it is wrong: a tap on the new stretch has to put
    /// them back on the route they were shown, not near it.
    func testTakingARefusalBackRestoresTheRoute() {
        for (walk, hill) in refusals() {
            let detoured = HillDetour.apply([hill], to: walk.route, in: graph)
            guard detoured.applied.contains(hill.id) else { continue }

            // The refusal has to have changed something, or restoring it proves
            // nothing about restoring anything.
            XCTAssertNotEqual(detoured.nodes, walk.route.nodes, "\(walk.name): the refusal changed nothing")

            let restored = HillDetour.apply([], to: walk.route, in: graph)
            XCTAssertEqual(restored.nodes, walk.route.nodes, "\(walk.name): undoing did not restore the route")
            XCTAssertEqual(restored.edges, walk.route.edges, "\(walk.name): undoing did not restore the edges")
            XCTAssertTrue(
                restored.detouredBy.allSatisfy { $0 == nil },
                "\(walk.name): the restored route still claims to have a detour on it"
            )
        }
    }

    /// Refusing two hills and then taking back the first leaves the second in
    /// force, and gives the first hill back.
    ///
    /// The list of refusals is replayed from the planned route every time it
    /// changes, and this is what that buys: any one of them can be taken back
    /// while the others stand. A stack of edits applied in place could only
    /// undo the most recent.
    func testOneRefusalCanBeTakenBackWhileAnotherStands() {
        var checked = 0

        for walk in walks {
            // The two ends of the route, so neither detour's window can reach
            // the other. Neighbouring hills share an approach, and a pair like
            // that tests the splice rather than independence.
            guard let first = walk.hills.first, let last = walk.hills.last, first.id != last.id else {
                continue
            }

            let both = HillDetour.apply([first, last], to: walk.route, in: graph)
            guard both.applied.contains(first.id), both.applied.contains(last.id) else { continue }
            checked += 1

            let afterUndoingFirst = HillDetour.apply([last], to: walk.route, in: graph)
            let walked = Set(afterUndoingFirst.edges)

            XCTAssertTrue(
                afterUndoingFirst.applied.contains(last.id),
                "\(walk.name): taking back one refusal stopped the other applying"
            )

            let firstHillEdges = graph.edges(along: first.nodes)
            XCTAssertTrue(
                firstHillEdges.allSatisfy { walked.contains($0) },
                "\(walk.name): taking back the first refusal did not give its hill back"
            )

            let lastHillEdges = graph.edges(along: last.nodes)
            XCTAssertTrue(
                lastHillEdges.allSatisfy { !walked.contains($0) },
                "\(walk.name): the refusal that was kept stopped being honoured"
            )
        }

        XCTAssertGreaterThan(checked, 0, "no trip here supported two refusals at once")
    }
}
