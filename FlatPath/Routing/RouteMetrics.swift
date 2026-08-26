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

// MARK: - Display

/// Feet, miles and minutes, unconditionally.
///
/// The app covers one American city, and the layouts these figures appear in
/// depend on them staying short and predictable: locale-driven units would put a
/// four-character number where a two-character one was budgeted and break the
/// column alignment the route cards are read by.
///
/// One place for all of them, because a route measured one way on a card and
/// another way in the turn-by-turn instructions for the same walk reads as two
/// different routes.
enum WalkingFigures {
    /// Rounded to the minute, and never to zero — a walk that takes forty
    /// seconds still takes a minute of the walker's attention.
    static func duration(seconds: Double) -> String {
        let minutes = max(1, Int((seconds / 60).rounded()))
        guard minutes >= 60 else { return "\(minutes) min" }
        return "\(minutes / 60) hr \(minutes % 60) min"
    }

    /// Climb in feet, to the nearest five.
    ///
    /// The elevation behind this is sampled from a 1-meter raster at each end of
    /// each block, so the foot digit is noise. Rounding it off states the
    /// precision the number actually has, and keeps the figure from twitching
    /// between recomputations of the same route.
    static func climb(meters: Double) -> String {
        let feet = meters * feetPerMeter
        return "\(Int((feet / 5).rounded() * 5)) ft ↑"
    }

    /// Miles to one decimal, or whole feet for anything under a tenth of one,
    /// where "0.1 mi" would be rounder than the walker needs.
    static func distance(meters: Double) -> String {
        let miles = meters / metersPerMile
        guard miles >= 0.1 else {
            return "\(Int((meters * feetPerMeter / 10).rounded() * 10)) ft"
        }
        return String(format: "%.1f mi", miles)
    }

    private static let feetPerMeter = 3.280_839_895
    private static let metersPerMile = 1_609.344
}

extension RouteMetrics {
    var timeText: String { WalkingFigures.duration(seconds: time) }
    var elevationGainText: String { WalkingFigures.climb(meters: elevationGain) }
    var distanceText: String { WalkingFigures.distance(meters: distance) }
}

extension WalkingFigures {
    /// A grade as whole percent, for the steepness warnings.
    ///
    /// Whole percent because the elevation behind it is sampled at the ends of a
    /// block: the number is good to a percent or two, and a decimal place would
    /// claim a precision the raster cannot support.
    static func grade(_ slope: Double) -> String {
        "\(Int((slope * 100).rounded()))%"
    }
}
