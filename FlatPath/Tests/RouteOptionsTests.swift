//  RouteOptionsTests.swift
//
//  Holds the route cards to the promise they make.
//
//  The cards are read top to bottom as a trade: each one costs more time than
//  the one above it, so each has to return less climbing. What guarantees that
//  is domination -- a route that is slower than another and also climbs more is
//  not a choice, it is a worse version of the one above it, and no walker's
//  taste would ever land on it.
//
//  The property worth testing is that nothing returned is dominated by anything
//  else returned. A property like that can pass for the wrong reason, so it is
//  tested alongside proof that it has something to catch: the same check run on
//  the unfiltered sweep must fail.
//
//  These are properties rather than pinned numbers, and they run against the
//  bundled graph over real trips. Rebuilding the graph moves every figure here;
//  it must not break the ordering, and this fails if it does.

import CoreLocation
import XCTest

@testable import FlatPath

final class RouteOptionsTests: XCTestCase {

    /// Trips chosen to exercise the ground the app exists for: across the city,
    /// up and down the hills that make the choice interesting, and in both
    /// directions, since an uphill trip and its downhill twin are not the same
    /// problem.
    private static let trips: [(name: String, from: (Double, Double), to: (Double, Double))] = [
        ("Kearny to Nob Hill", (37.79060, -122.40380), (37.79435, -122.41837)),
        ("Mission to Nob Hill", (37.75220, -122.41840), (37.79290, -122.41610)),
        ("Nob Hill to Mission", (37.79290, -122.41610), (37.75220, -122.41840)),
        ("Marina to the Mission", (37.80200, -122.43600), (37.75950, -122.41830)),
        ("Castro to the Ferry Building", (37.76090, -122.43500), (37.79550, -122.39370)),
        ("Ferry Building to Castro", (37.79550, -122.39370), (37.76090, -122.43500)),
        ("SoMa to the Haight", (37.77850, -122.40560), (37.77000, -122.44690)),
        ("Embarcadero to Coit Tower", (37.79550, -122.39370), (37.80250, -122.40580)),
        ("Sunset to Twin Peaks", (37.76000, -122.49000), (37.75440, -122.44770)),
        // Six flat blocks inside the Mission. There is no trade to be had here
        // and the app should say so with one card rather than three.
        ("Across the Mission", (37.75980, -122.41880), (37.75440, -122.41390)),
    ]

    private var graph: WalkingGraph!

    override func setUpWithError() throws {
        graph = try GraphLoader.loadBundledGraph()
    }

    private func endpoints(
        _ trip: (name: String, from: (Double, Double), to: (Double, Double))
    ) throws -> (start: Int, goal: Int) {
        let start = try XCTUnwrap(
            graph.nearestNode(toLatitude: trip.from.0, longitude: trip.from.1),
            "\(trip.name): the start does not reach the network"
        )
        let goal = try XCTUnwrap(
            graph.nearestNode(toLatitude: trip.to.0, longitude: trip.to.1),
            "\(trip.name): the destination does not reach the network"
        )
        return (start, goal)
    }

    private func options(
        _ trip: (name: String, from: (Double, Double), to: (Double, Double)),
        tolerance: DetourTolerance = .default
    ) throws -> [RouteOption] {
        let (start, goal) = try endpoints(trip)
        return RouteOptions.between(start: start, destination: goal, in: graph, tolerance: tolerance)
    }

    private func candidates(
        _ trip: (name: String, from: (Double, Double), to: (Double, Double))
    ) throws -> [RouteOptions.Candidate] {
        let (start, goal) = try endpoints(trip)
        return RouteOptions.candidates(start: start, destination: goal, in: graph)
    }

    /// Every pair where the first route beats the second on both time and climb.
    private func dominatedPairs(_ metrics: [RouteMetrics]) -> [(Int, Int)] {
        metrics.indices.flatMap { winner in
            metrics.indices.compactMap { loser in
                guard winner != loser,
                      RouteOptions.dominates(metrics[winner], metrics[loser])
                else { return nil }
                return (winner, loser)
            }
        }
    }

    /// Every trip between two points on the network has at least one answer, and
    /// never more answers than there are cards to put them on.
    func testEveryTripIsOffered() throws {
        for trip in Self.trips {
            let offered = try options(trip)
            XCTAssertFalse(offered.isEmpty, "\(trip.name): no route offered")
            XCTAssertLessThanOrEqual(offered.count, RouteOptions.maximumOptions, "\(trip.name)")
        }
    }

    /// The property the whole filter exists to establish: nothing offered is
    /// beaten outright by something else offered.
    ///
    /// Checked at two stages, and the earlier one is the one with teeth. By the
    /// time the list has been cut to three points taken from opposite ends of
    /// the frontier, domination is nearly impossible to observe whether or not
    /// anything filtered for it -- the quickest and the flattest route cannot
    /// beat each other by construction. The frontier the three are drawn from is
    /// where the filter either did its job or did not, so both are asserted:
    /// the second is the promise, the first is what makes the promise testable.
    func testNoOfferedRouteIsDominatedByAnother() throws {
        for trip in Self.trips {
            let frontier = RouteOptions.paretoFrontier(try candidates(trip))
            XCTAssertTrue(
                dominatedPairs(frontier.map(\.metrics)).isEmpty,
                "\(trip.name): the frontier the options come from holds a beaten route"
            )

            let offered = try options(trip)
            let dominated = dominatedPairs(offered.map(\.metrics))
            XCTAssertTrue(
                dominated.isEmpty,
                "\(trip.name): " + dominated.map { winner, loser in
                    "'\(offered[loser].name)' is beaten on both counts by '\(offered[winner].name)'"
                }.joined(separator: "; ")
            )
        }
    }

    /// And proof the check above is not passing for want of anything to catch.
    ///
    /// The unfiltered sweep genuinely contains dominated routes -- harsher
    /// settings that bought nothing, and ceiling runs that took the long way
    /// round for no saving -- so with the domination filter removed the property
    /// above fails. If this stops holding, the sweep has stopped producing
    /// routes worth filtering and the guarantee has quietly become vacuous.
    func testDominationFilterHasSomethingToCatch() throws {
        var tripsWithDominatedCandidates: [String] = []

        for trip in Self.trips {
            let raw = try candidates(trip)
            if !dominatedPairs(raw.map(\.metrics)).isEmpty {
                tripsWithDominatedCandidates.append(trip.name)
            }
        }

        XCTAssertFalse(
            tripsWithDominatedCandidates.isEmpty,
            "no trip produced a dominated candidate, so the domination filter proves nothing"
        )
    }

    /// The cards must read as a trade in both columns at once: down the list,
    /// time rises and climb falls.
    ///
    /// This follows from the two properties above rather than standing on its
    /// own, and it is asserted anyway because it is what the walker actually
    /// reads. A slower route that also climbs more is not an option to choose
    /// between, only a worse version of the one above it.
    func testSlowerOptionsAlwaysClimbLess() throws {
        for trip in Self.trips {
            let offered = try options(trip)
            for (quicker, slower) in zip(offered, offered.dropFirst()) {
                XCTAssertGreaterThan(
                    slower.metrics.time, quicker.metrics.time,
                    "\(trip.name): '\(slower.name)' is not slower than '\(quicker.name)'"
                )
                XCTAssertLessThan(
                    slower.metrics.elevationGain, quicker.metrics.elevationGain,
                    "\(trip.name): '\(slower.name)' takes longer than '\(quicker.name)' and climbs more"
                )
            }
        }
    }

    /// No option may wander further than the walker gave it permission to.
    func testNoOptionExceedsTheDetourTolerance() throws {
        for tolerance in DetourTolerance.allCases {
            for trip in Self.trips {
                let offered = try options(trip, tolerance: tolerance)
                guard let quickest = offered.map(\.metrics.time).min() else { continue }

                for route in offered {
                    XCTAssertLessThanOrEqual(
                        route.metrics.time, quickest * tolerance.multiple + 1e-6,
                        "\(trip.name) at \(tolerance.label): '\(route.name)' overruns the bound"
                    )
                }
            }
        }
    }

    /// Two cards have to be two walks. Options whose climb figures sit on top of
    /// each other are the same route described twice, and the walker cannot act
    /// on the difference.
    func testOfferedOptionsDifferMeaningfullyInClimb() throws {
        for trip in Self.trips {
            let offered = try options(trip)
            for (quicker, slower) in zip(offered, offered.dropFirst()) {
                let saved = quicker.metrics.elevationGain - slower.metrics.elevationGain
                XCTAssertGreaterThanOrEqual(
                    saved, RouteOptions.minimumClimbSeparation,
                    "\(trip.name): '\(slower.name)' saves only \(saved) m over '\(quicker.name)'"
                )
            }
        }
    }

    /// A short flat trip has one honest answer, and padding it with two more
    /// would invent a choice that is not there.
    func testAFlatTripReturnsOneRoute() throws {
        let trip = try XCTUnwrap(Self.trips.first { $0.name == "Across the Mission" })
        XCTAssertEqual(try options(trip).count, 1)
    }

    /// Regression for the trip that exposed the missing neutral baseline. A
    /// generous detour from Kearny into Nob Hill must offer the direct walk and
    /// at least one flatter trade, not collapse every hill-aware run into one
    /// route before the walker gets a choice.
    func testKearnyToNobHillOffersAChoiceAtGenerousTolerance() throws {
        let trip = try XCTUnwrap(Self.trips.first { $0.name == "Kearny to Nob Hill" })
        let offered = try options(trip, tolerance: .generous)

        XCTAssertGreaterThanOrEqual(offered.count, 2)
        XCTAssertEqual(offered.first?.name, "Direct")
        XCTAssertEqual(offered.last?.name, "Flattest")
    }

    /// A generous budget is an explicit request for choice on a substantive
    /// walk. The only fixture exempted is the deliberately short, flat trip.
    func testGenerousToleranceOffersAlternativesForSubstantiveTrips() throws {
        for trip in Self.trips where trip.name != "Across the Mission" {
            XCTAssertGreaterThanOrEqual(
                try options(trip, tolerance: .generous).count,
                2,
                "\(trip.name): generous tolerance still produced only one path"
            )
        }
    }
}
