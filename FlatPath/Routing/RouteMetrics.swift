//  RouteMetrics.swift
//
//  The three numbers on a route card: time, elevation gain, and distance.
//
//  Time is honest walking time accumulated along the path, not the router's
//  internal cost -- the router inflates steep edges to steer away from them, and
//  showing that inflated figure would misreport how long the walk actually takes.
//  Elevation gain counts only the climbs, since descents do not undo them.

import Foundation

/// What a route costs the walker, in the terms they choose between.
///
/// Everything here is accumulated from figures baked onto the edges offline, so
/// measuring a route is a single pass over it with no arithmetic beyond addition
/// -- the walking-speed curve and the elevation raster stay in the pipeline.
struct RouteMetrics {
    /// Seconds of walking, with no hill penalty folded in.
    let time: Double

    /// Meters climbed over the whole route.
    ///
    /// Only the ascents count. A route that climbs a hill and comes back down
    /// has gained everything it climbed: the descent is not a refund, and
    /// summing the signed changes instead would report a route over Nob Hill as
    /// costing nothing at all when its ends happen to sit at the same height.
    let elevationGain: Double

    /// Meters walked.
    let distance: Double
}

extension RouteMetrics {
    /// Measure a route from the edges it traverses.
    init(edges: [Int], in graph: WalkingGraph) {
        var time = 0.0
        var elevationGain = 0.0
        var distance = 0.0

        for edge in edges {
            time += Double(graph.edgeTime[edge])
            distance += Double(graph.edgeLength[edge])

            let rise = Double(graph.edgeDeltaElevation[edge])
            if rise > 0 {
                elevationGain += rise
            }
        }

        self.init(time: time, elevationGain: elevationGain, distance: distance)
    }
}
