//  Heuristic.swift
//
//  Lower bound on the walking time remaining from a node to the destination:
//  straight-line distance divided by the fastest speed any edge can be walked.
//
//  Both the running total and this estimate are in seconds, and the estimate
//  must never exceed the true remaining time. Dividing by peak walking speed
//  guarantees that, which is what keeps the returned route optimal.

import Foundation

/// Remaining walking time from a point to a fixed destination, as an estimate
/// the search is allowed to trust.
///
/// The destination is baked in at construction because a single search asks
/// this question once per node discovered — tens of thousands of times — and
/// the parts of the answer that depend only on the destination are the
/// expensive ones. Converting them once turns each query into a handful of
/// trigonometric operations on values already in registers.
struct RemainingTimeEstimate {
    /// The fastest a walker covers ground on any edge, in meters per second —
    /// the peak of the speed curve the baked edge costs come from.
    ///
    /// Every guarantee the router makes rests on this being an upper bound on
    /// real walking speed. Because no edge is walked faster, distance divided
    /// by this speed cannot exceed the true time to cover it, so the estimate
    /// only ever undershoots — and an estimate that never overshoots is what
    /// makes the first route the search finalizes also the cheapest one.
    /// Raising this value would not make routing faster, it would make routing
    /// quietly wrong: the search would start accepting routes it has not
    /// finished proving.
    static let peakWalkingSpeed: Double = 1.667

    /// Mean Earth radius in meters. The graph spans a single city, so the error
    /// from treating the Earth as a sphere is far below the meter-scale noise
    /// already present in the edge lengths.
    private static let earthRadius: Double = 6_371_000

    private let goalLatitude: Double
    private let goalLongitude: Double
    private let goalLatitudeCosine: Double

    init(goal: Int, in graph: WalkingGraph) {
        goalLatitude = graph.latitudes[goal] * .pi / 180
        goalLongitude = graph.longitudes[goal] * .pi / 180
        goalLatitudeCosine = cos(goalLatitude)
    }

    /// Seconds to reach the destination from a point, assuming a straight line
    /// walked at peak speed. Always at or below the true remaining time.
    func seconds(fromLatitude latitude: Double, longitude: Double) -> Double {
        let latitudeRadians = latitude * .pi / 180
        let longitudeRadians = longitude * .pi / 180

        // Haversine rather than the simpler spherical law of cosines: most pairs
        // this is asked about are a few hundred meters apart, and the law of
        // cosines loses most of its significant digits at that scale.
        let halfLatitudeDelta = (goalLatitude - latitudeRadians) / 2
        let halfLongitudeDelta = (goalLongitude - longitudeRadians) / 2
        let chord =
            sin(halfLatitudeDelta) * sin(halfLatitudeDelta)
            + cos(latitudeRadians) * goalLatitudeCosine
            * sin(halfLongitudeDelta) * sin(halfLongitudeDelta)
        let distance = 2 * Self.earthRadius * asin(min(1, sqrt(chord)))

        return distance / Self.peakWalkingSpeed
    }

    /// Convenience for the common case: the estimate from a node of the graph.
    func seconds(from node: Int, in graph: WalkingGraph) -> Double {
        seconds(fromLatitude: graph.latitudes[node], longitude: graph.longitudes[node])
    }
}
