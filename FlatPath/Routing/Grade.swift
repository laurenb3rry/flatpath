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
    /// Drawn a little above the grade at which the router first charges a block
    /// more than the walking it takes, and deliberately so. These bands are
    /// marks on a map rather than a cost, and this city has so many blocks just
    /// past the router's threshold that marking all of them would paint most of
    /// most routes -- leaving the marks meaning "there is ground here" instead
    /// of "this is the part that is work".
    static let moderateSlope = 0.05

    /// Where a climb is unmistakably a climb.
    ///
    /// Read off the gentlest setting the router sweeps: even there, a block this
    /// steep already costs several times the walking it takes, so every route
    /// option on offer would rather go a long way round than accept one. A grade
    /// that the most hill-tolerant walker the app will plan for still refuses is
    /// a fair definition of steep for anyone looking at the block on a map.
    static let steepSlope = 0.12

    /// The band a stretch falls in, from its rise and the ground it covers.
    ///
    /// Very short stretches are guarded against: two nodes can sit centimeters
    /// apart, and a real elevation change divided by that is a grade no street
    /// has. The router clamps the same way when it prices an edge.
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
