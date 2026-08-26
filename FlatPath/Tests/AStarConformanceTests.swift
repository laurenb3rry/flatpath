//  AStarConformanceTests.swift
//
//  Pins the router to a hand-traced result on a small grid whose edge costs are
//  known exactly: one block is steep enough that no route should ever take it,
//  and the correct answer climbs a different staircase.
//
//  Both the total cost and the exact sequence of nodes are asserted. Total alone
//  is not enough -- an equal-cost detour would pass while still proving the
//  search is not reproducing the intended path -- and the path alone is not
//  enough either, since several staircases across this grid cost the same.
//
//  The costs are asserted too, and that matters more than it used to. The graph
//  no longer carries them, so nothing outside this file would notice if the cost
//  function drifted; the three reference blocks below are what catch it.

import Foundation
import XCTest

@testable import FlatPath

final class AStarConformanceTests: XCTestCase {

    // MARK: The hand-traced grid

    /// The settings the fixture is traced at. A middling pair from the sweep:
    /// enough grade aversion to bend a route around a steep block, and an
    /// exchange rate between minutes and meters climbed close to the one an
    /// ordinary walker's own rule of thumb implies.
    private static let dial = WalkingCost(uphillSuffering: 0.5, ascentWeight: 4)

    /// A 4x4 lattice of intersections, 100 m between neighbours, wired one-way
    /// east and one-way north so every route from the south-west corner to the
    /// north-east one is exactly three blocks east and three blocks north.
    ///
    /// The costs are written here as literals rather than recomputed, because
    /// the point of this fixture is to be a fixed target the router and the cost
    /// function are measured against. Deriving them from the same code under
    /// test would let a drifting formula move its own target.
    private enum Block {
        /// 100 m on the level.
        static let flat = 71.5

        /// 100 m up a 6% grade -- an unremarkable San Francisco block, and the
        /// number worth watching. Twice the cost of the same distance on the
        /// level: about half of that from the grade being minded at all, and
        /// about half from the six meters of height it gains. Priced by grade
        /// alone this block was nearly free, and a route made of nothing else
        /// climbed two hundred feet while the cost function called it flat.
        static let climb = 156.3

        /// 100 m up an 18% grade. Twenty-six times the cost of walking around
        /// it, which is what makes avoiding it the unambiguously correct answer
        /// rather than a preference.
        static let steep = 1883.7
    }

    /// Honest walking time for the same three blocks, which the fixture stores
    /// and the cost function multiplies. Unrounded, because these are what the
    /// offline build bakes and the totals below are sums of many of them.
    private enum Walk {
        static let flat = 71.474_77
        static let climb = 88.176_86
        static let steep = 134.201_79
    }

    private static let gridSide = 4

    /// The one block the router has to refuse: north out of (1, 1).
    private static let steepBlock = (x: 1, y: 1)

    /// Anchor for the fixture's coordinates. Only the spacing between nodes
    /// matters to the search, but placing the grid in San Francisco keeps the
    /// distances the heuristic computes in the range it meets in production.
    private static let anchorLatitude = 37.7749
    private static let anchorLongitude = -122.4194

    // MARK: The conformance check

    func testRoutesAroundTheSteepBlock() throws {
        let grid = Self.makeGrid()

        let route = try XCTUnwrap(
            AStar.route(
                from: Self.index(x: 0, y: 0),
                to: Self.index(x: 3, y: 3),
                in: grid,
                cost: Self.dial
            ),
            "the grid is fully connected south-west to north-east, so a route must exist"
        )

        // Three flat blocks and three ordinary climbs: 3 x 71.5 + 3 x 156.3.
        // Every route that stays clear of the steep block costs this, and every
        // route that crosses it costs about 1,700 s more.
        XCTAssertEqual(route.cost, 683.2, accuracy: 0.1)

        XCTAssertEqual(
            Self.coordinates(of: route),
            [(0, 0), (1, 0), (2, 0), (3, 0), (3, 1), (3, 2), (3, 3)].map { Coordinate($0) },
            "the router climbed a different staircase than the traced one"
        )
    }

    /// The steep block is only evidence of anything if refusing it is a decision
    /// rather than an accident, so this prices what taking it would have cost.
    ///
    /// Every route across this grid climbs three blocks and crosses three, so
    /// the choice is only ever which three. The one staircase that uses the
    /// steep block pays `Block.steep` where the others pay `Block.climb`, which
    /// is more than three times the whole rest of the walk -- and the route the
    /// search returns costs the cheaper total, using no steep block anywhere.
    func testTheSteepBlockIsPricedOutOfEveryRoute() throws {
        let grid = Self.makeGrid()

        let climbOutOfTheCorner = try Self.edge(east: false, from: Self.steepBlock, in: grid)
        let throughTheSteepBlock = 3 * Block.flat + 2 * Block.climb + Block.steep

        let route = try XCTUnwrap(
            AStar.route(from: Self.index(x: 0, y: 0), to: Self.index(x: 3, y: 3), in: grid, cost: Self.dial)
        )

        XCTAssertLessThan(
            route.cost, throughTheSteepBlock / 3,
            "the cheapest staircase through the steep block costs \(throughTheSteepBlock) s; "
            + "a route anywhere near that has taken it"
        )
        XCTAssertFalse(
            grid.edges(along: route.nodes).contains(climbOutOfTheCorner),
            "the route walked the steep block at \(Block.steep) s rather than a \(Block.climb) s one"
        )
    }

    /// Ties are the normal case on a grid, and the tie-break has to be stable.
    ///
    /// Six of the twenty staircases across this fixture cost exactly the same,
    /// so which one comes back is decided by the queue's ordering rather than by
    /// the costs. That is why the path above is asserted at all: not because it
    /// is the only right answer, but because the same search on the same graph
    /// must not draw a different line on the map each time it runs.
    func testTheSameTripAlwaysReturnsTheSameRoute() throws {
        let grid = Self.makeGrid()

        let routes = (0 ..< 5).map { _ in
            AStar.route(from: Self.index(x: 0, y: 0), to: Self.index(x: 3, y: 3), in: grid, cost: Self.dial)?.nodes
        }

        XCTAssertEqual(Set(routes.map { $0 ?? [] }).count, 1, "the router is not deterministic")
    }

    /// The cost function itself, against the three reference blocks.
    ///
    /// The graph used to carry these numbers, so a drifting formula meant a
    /// rebuild that printed them. Now the formula runs on the phone and nothing
    /// prints anything, which makes this the only place the drift shows.
    func testReferenceBlocksCostWhatTheyShould() throws {
        let grid = Self.makeGrid()

        for (label, expected, edge) in [
            ("flat", Block.flat, try Self.edge(east: true, from: (0, 0), in: grid)),
            ("climb", Block.climb, try Self.edge(east: false, from: (0, 0), in: grid)),
            ("steep", Block.steep, try Self.edge(east: false, from: Self.steepBlock, in: grid)),
        ] {
            let cost = try XCTUnwrap(Self.dial.seconds(of: edge, in: grid), "\(label) was refused")
            XCTAssertEqual(cost, expected, accuracy: 0.1, "\(label) block")
        }
    }

    /// No edge may cost less than the time it takes to walk it.
    ///
    /// The heuristic bounds the remaining cost by straight-line distance at peak
    /// walking speed, which is only a lower bound while this holds. Checked
    /// across the whole sweep, both grade directions included, because a misery
    /// multiplier below 1 or a negative climb charge would not fail loudly --
    /// the router would simply start returning routes it had not proved.
    func testNoEdgeIsCheaperThanWalkingIt() throws {
        let grid = Self.makeGrid()

        for cost in RouteOptions.sweep {
            for edge in 0 ..< grid.edgeCount {
                let seconds = try XCTUnwrap(cost.seconds(of: edge, in: grid))
                XCTAssertGreaterThanOrEqual(
                    seconds, Double(grid.edgeTime[edge]),
                    "edge \(edge) priced below its walking time"
                )
            }
        }
    }

    // MARK: Fixture

    /// Node ordering: west to east within a row, then south to north. Any dense
    /// numbering would do — the search only requires that a node's outgoing
    /// edges sit together, which `makeGrid` guarantees by emitting them in this
    /// same order.
    private static func index(x: Int, y: Int) -> Int {
        y * gridSide + x
    }

    private static func edge(east: Bool, from origin: (x: Int, y: Int), in grid: WalkingGraph) throws -> Int {
        let target = east
            ? index(x: origin.x + 1, y: origin.y)
            : index(x: origin.x, y: origin.y + 1)
        return try XCTUnwrap(
            grid.outgoingEdges(of: index(x: origin.x, y: origin.y)).first {
                Int(grid.edgeTo[$0]) == target
            },
            "the fixture should wire a block out of \(Coordinate(origin))"
        )
    }

    private static func makeGrid() -> WalkingGraph {
        var latitudes = [Double]()
        var longitudes = [Double]()
        var elevations = [Float]()

        // 100 m in degrees, north and east. The east step shrinks with latitude,
        // so it is taken at the anchor rather than assumed equal to the north
        // one; a square grid on paper that is oblong in coordinates would feed
        // the heuristic distances that do not match the edge lengths.
        let metresPerDegreeLatitude = 111_320.0
        let northStep = 100.0 / metresPerDegreeLatitude
        let eastStep = 100.0 / (metresPerDegreeLatitude * cos(anchorLatitude * .pi / 180))

        for y in 0 ..< gridSide {
            for x in 0 ..< gridSide {
                latitudes.append(anchorLatitude + Double(y) * northStep)
                longitudes.append(anchorLongitude + Double(x) * eastStep)
                // The ground rises 6 m per row northward. Nothing in the search
                // reads this — the climb the router prices is the one recorded
                // on each edge — but the field is what the route cards sum.
                elevations.append(Float(y) * 6)
            }
        }

        var edgeStart = [UInt32]()
        var edgeTo = [UInt32]()
        var edgeLength = [Float]()
        var edgeDeltaElevation = [Float]()
        var edgeTime = [Float]()

        for y in 0 ..< gridSide {
            for x in 0 ..< gridSide {
                edgeStart.append(UInt32(edgeTo.count))

                if x < gridSide - 1 {
                    edgeTo.append(UInt32(index(x: x + 1, y: y)))
                    edgeLength.append(100)
                    edgeDeltaElevation.append(0)
                    edgeTime.append(Float(Walk.flat))
                }

                if y < gridSide - 1 {
                    let isSteep = (x, y) == steepBlock
                    edgeTo.append(UInt32(index(x: x, y: y + 1)))
                    edgeLength.append(100)
                    edgeDeltaElevation.append(isSteep ? 18 : 6)
                    // Honest walking time, with no hill penalty in it. It trails
                    // the routing cost by more the steeper the block is, which
                    // is the whole reason the two are different numbers.
                    edgeTime.append(Float(isSteep ? Walk.steep : Walk.climb))
                }
            }
        }
        edgeStart.append(UInt32(edgeTo.count))

        return WalkingGraph(
            latitudes: latitudes,
            longitudes: longitudes,
            elevations: elevations,
            edgeStart: edgeStart,
            edgeTo: edgeTo,
            edgeLength: edgeLength,
            edgeDeltaElevation: edgeDeltaElevation,
            edgeTime: edgeTime,
            // Nothing in the fixture crosses a street: the grid is there to
            // exercise how grade is priced, and a crossing charge on some edges
            // and not others would move the totals for an unrelated reason.
            edgeCrossingShare: [Float](repeating: 0, count: edgeTo.count),
            edgeNameIndex: [UInt32](repeating: 0, count: edgeTo.count),
            streetNames: [""]
        )
    }

    // MARK: Reporting

    /// Grid coordinates, so a failure prints the staircase the router walked
    /// rather than a row of node numbers nobody can read.
    private struct Coordinate: Equatable, CustomStringConvertible {
        let x: Int
        let y: Int

        init(_ pair: (Int, Int)) {
            x = pair.0
            y = pair.1
        }

        init(node: Int) {
            x = node % AStarConformanceTests.gridSide
            y = node / AStarConformanceTests.gridSide
        }

        var description: String { "(\(x), \(y))" }
    }

    private static func coordinates(of route: Route) -> [Coordinate] {
        route.nodes.map(Coordinate.init(node:))
    }
}
