//  RouteOptionsTests.swift
//
//  Holds the route cards to the promise they make.
//
//  The cards are read top to bottom as a trade: each one costs more time than
//  the one above it, so each has to return less climbing. That is not what the
//  router optimizes -- it prices how steep a block is, not how much climbing a
//  route adds up to, and a high hill-aversion setting will accept a few more
//  meters of total ascent to keep every block gentle. Which is the right thing
//  to optimize and the wrong thing to put on a card unexplained, so the offering
//  rule drops any option that does not pay its way.
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
        ("Castro to the Ferry Building", (37.76090, -122.43500), (37.79550, -122.39370)),
        ("Ferry Building to Castro", (37.79550, -122.39370), (37.76090, -122.43500)),
        ("SoMa to the Haight", (37.77850, -122.40560), (37.77000, -122.44690)),
        ("Embarcadero to Coit Tower", (37.79550, -122.39370), (37.80250, -122.40580)),
        ("Sunset to Twin Peaks", (37.76000, -122.49000), (37.75440, -122.44770)),
    ]

    private var graph: WalkingGraph!

    override func setUpWithError() throws {
        graph = try GraphLoader.loadBundledGraph()
    }

    private func options(_ trip: (name: String, from: (Double, Double), to: (Double, Double))) throws -> [RouteOption] {
        let start = try XCTUnwrap(
            graph.nearestNode(toLatitude: trip.from.0, longitude: trip.from.1),
            "\(trip.name): the start does not reach the network"
        )
        let goal = try XCTUnwrap(
            graph.nearestNode(toLatitude: trip.to.0, longitude: trip.to.1),
            "\(trip.name): the destination does not reach the network"
        )
        return RouteOptions.between(start: start, destination: goal, in: graph)
    }

    /// Every trip between two points on the network has at least one answer, and
    /// never more answers than there are settings to find them with.
    func testEveryTripIsOffered() throws {
        for trip in Self.trips {
            let offered = try options(trip)
            XCTAssertFalse(offered.isEmpty, "\(trip.name): no route offered")
            XCTAssertLessThanOrEqual(offered.count, RouteOptions.names.count, "\(trip.name)")
        }
    }

    /// The cards must read as a trade in both columns at once: down the list,
    /// time rises and climb falls.
    ///
    /// This is the one that fails when the router's idea of flat and the card's
    /// idea of flat come apart -- a slower route that also climbs more, which is
    /// not an option the walker can choose between, only a worse version of the
    /// one above it.
    func testSlowerOptionsAlwaysClimbLess() throws {
        for trip in Self.trips {
            for (quicker, slower) in zip(try options(trip), try options(trip).dropFirst()) {
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

    /// An option has to buy enough with the time it costs to be worth reading.
    func testEveryOptionEarnsItsPlace() throws {
        for trip in Self.trips {
            for (quicker, slower) in zip(try options(trip), try options(trip).dropFirst()) {
                let minutes = (slower.metrics.time - quicker.metrics.time) / 60
                let saved = quicker.metrics.elevationGain - slower.metrics.elevationGain

                XCTAssertGreaterThanOrEqual(
                    saved, minutes * RouteOptions.worthwhileClimbPerMinute,
                    "\(trip.name): '\(slower.name)' costs \(minutes) min to save \(saved) m of climb"
                )
            }
        }
    }
}
