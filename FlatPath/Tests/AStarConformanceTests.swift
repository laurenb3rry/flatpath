//  AStarConformanceTests.swift
//
//  Pins the router to a hand-traced result on a small grid whose edge costs are
//  known exactly: one steep block sits on the otherwise-cheapest path, and the
//  correct answer routes around it.
//
//  Both the total cost and the exact sequence of nodes are asserted. Total alone
//  is not enough -- an equal-cost detour would pass while still proving the
//  search is not reproducing the intended path.

import Foundation
import XCTest

@testable import FlatPath

final class AStarConformanceTests: XCTestCase {

    // MARK: The hand-traced grid

    /// A 4x4 lattice of intersections, 100 m between neighbours, wired one-way
    /// east and one-way north so every route from the south-west corner to the
    /// north-east one is exactly three blocks east and three blocks north.
    ///
    /// Costs come from the same tuned curve the offline build bakes into the
    /// real graph, at the middle hill-aversion setting, and are written here as
    /// literals: the point of this fixture is to be a fixed target the router
    /// is measured against, so recomputing them would let a drifting cost
    /// function move the target it is supposed to be held to.
    private enum Block {
        /// 100 m on the level.
        static let flat = 71.5
        /// 100 m up a 6% grade — a normal San Francisco block.
        static let climb = 90.0
        /// 100 m up an 18% grade. Eight times the cost of walking around it,
        /// which is what makes avoiding it the unambiguously correct answer
        /// rather than a preference.
        static let steep = 587.8
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
                setting: 0
            ),
            "the grid is fully connected south-west to north-east, so a route must exist"
        )

        // Three flat blocks and three ordinary climbs: 3 x 71.5 + 3 x 90.0.
        // Every route that stays clear of the steep block costs this, and every
        // route that crosses it costs about 500 s more.
        XCTAssertEqual(route.cost, 484.5, accuracy: 0.1)

        XCTAssertEqual(
            Self.coordinates(of: route),
            [(0, 0), (1, 0), (1, 1), (2, 1), (2, 2), (3, 2), (3, 3)].map { Coordinate($0) },
            "the router climbed a different staircase than the traced one"
        )
    }

    /// The steep block is only evidence of anything if it is genuinely in the
    /// way, so this confirms the trap is laid: the route the assertion above
    /// expects passes through the corner the steep block leaves from, and turns
    /// east there instead of climbing.
    func testSteepBlockIsOnTheRouteAndRefused() throws {
        let grid = Self.makeGrid()
        let corner = Self.index(x: Self.steepBlock.x, y: Self.steepBlock.y)

        let climbOutOfTheCorner = try XCTUnwrap(
            grid.outgoingEdges(of: corner).first {
                Int(grid.edgeTo[$0]) == Self.index(x: Self.steepBlock.x, y: Self.steepBlock.y + 1)
            },
            "the fixture should wire a north block out of \(Coordinate(node: corner))"
        )
        XCTAssertEqual(Double(grid.cost(of: climbOutOfTheCorner, setting: 0)), Block.steep, accuracy: 0.1)

        let route = try XCTUnwrap(
            AStar.route(from: Self.index(x: 0, y: 0), to: Self.index(x: 3, y: 3), in: grid, setting: 0)
        )
        XCTAssertTrue(
            route.nodes.contains(corner),
            "the route should reach the steep corner and decline the climb, not avoid the corner"
        )
    }

    // MARK: Fixture

    /// Node ordering: west to east within a row, then south to north. Any dense
    /// numbering would do — the search only requires that a node's outgoing
    /// edges sit together, which `makeGrid` guarantees by emitting them in this
    /// same order.
    private static func index(x: Int, y: Int) -> Int {
        y * gridSide + x
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
                // reads this — the climb is already priced into the edge costs —
                // but the field is what the route cards will sum later.
                elevations.append(Float(y) * 6)
            }
        }

        var edgeStart = [UInt32]()
        var edgeTo = [UInt32]()
        var edgeLength = [Float]()
        var edgeDeltaElevation = [Float]()
        var edgeTime = [Float]()
        var costs = [Float]()

        for y in 0 ..< gridSide {
            for x in 0 ..< gridSide {
                edgeStart.append(UInt32(edgeTo.count))

                if x < gridSide - 1 {
                    edgeTo.append(UInt32(index(x: x + 1, y: y)))
                    edgeLength.append(100)
                    edgeDeltaElevation.append(0)
                    edgeTime.append(Float(Block.flat))
                    costs.append(Float(Block.flat))
                }

                if y < gridSide - 1 {
                    let isSteep = (x, y) == steepBlock
                    edgeTo.append(UInt32(index(x: x, y: y + 1)))
                    edgeLength.append(100)
                    edgeDeltaElevation.append(isSteep ? 18 : 6)
                    // Honest walking time, with the hill penalty left out. It
                    // trails the routing cost by more the steeper the block is,
                    // which is the whole reason the two are stored separately.
                    edgeTime.append(isSteep ? 134.2 : 88.2)
                    costs.append(Float(isSteep ? Block.steep : Block.climb))
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
            edgeCosts: [costs],
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
