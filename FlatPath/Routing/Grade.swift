//  Grade.swift
//
//  How steep a stretch of walking is, in the three bands the app treats
//  differently.
//
//  The bands are the app's one judgment about what counts as steep, and both
//  the app and the widget extension read from this file so that a hill cannot
//  be drawn as a warning on the map and as ordinary ground on the Lock Screen.
//  It is deliberately free of every other type here -- no graph, no route -- so
//  that sharing it costs the extension nothing but a few lines of arithmetic.

import Foundation

/// How steep a stretch of walking is, in the three bands the app draws
/// differently.
///
/// Climbs only. A route down a San Francisco hill is a long descent, and
/// marking all of it would paint half of every route on the map -- which would
/// leave the marks meaning "this is a hill somewhere" rather than "this is the
/// part that is work". The walker chose a route to avoid climbing, so climbing
/// is what the warnings answer.
enum Grade: String, Codable, Hashable {
    case gentle
    case moderate
    case steep

    /// Where a climb stops being merely slower and starts being work.
    ///
    /// The same grade the baked edge costs use as the point at which a hill is
    /// charged more than the extra time it takes. Below it a block is priced as
    /// walking; above it the penalty starts compounding, so this is the first
    /// grade the router itself treats as a hill rather than as ground.
    static let moderateSlope = 0.05

    /// Where a climb costs twice the walking it takes.
    ///
    /// Read off the middle hill-aversion setting: at that dial the penalty
    /// doubles a block's cost at a grade of about 12%. Past here the router is
    /// willing to walk twice as far to avoid the block, which is a fair
    /// definition of steep for a walker looking at the same block on a map.
    static let steepSlope = 0.12

    /// The band a stretch falls in, from its rise and the ground it covers.
    ///
    /// Very short stretches are guarded against: two nodes can sit centimeters
    /// apart, and a real elevation change divided by that is a grade no street
    /// has. The offline build clamps the same way when it prices an edge.
    init(rise: Double, over run: Double) {
        self.init(slope: rise / max(run, Self.shortestMeaningfulRun))
    }

    /// The band a signed grade falls in, positive uphill.
    init(slope: Double) {
        switch slope {
        case Self.steepSlope...: self = .steep
        case Self.moderateSlope...: self = .moderate
        default: self = .gentle
        }
    }

    /// Whether the grade is worth marking at all.
    var isWorthWarningAbout: Bool { self != .gentle }

    private static let shortestMeaningfulRun = 5.0
}
