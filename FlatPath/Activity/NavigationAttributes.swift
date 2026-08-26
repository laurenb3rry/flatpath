//  NavigationAttributes.swift
//
//  What a walk in progress looks like from outside the app: on the Lock Screen,
//  in the Dynamic Island, and in Notification Center.
//
//  Shared between the app and the widget extension, which is why it is only
//  data. Everything here is already formatted -- the distances carry their
//  units, the instruction is a finished sentence -- because the extension is a
//  separate process that renders what it is handed and has no access to the
//  graph, the route, or the walker's position. The app measures, the extension
//  draws.
//
//  Held to what a glance can use. The point of this surface is that the walker
//  can put the phone away and be told the next thing without unlocking it.

import ActivityKit
import Foundation

struct NavigationAttributes: ActivityAttributes {
    /// Which of the offered routes is being walked: "Flattest", "Balanced".
    let routeName: String

    /// What the walker is heading to, for the line that says where this is going.
    let destination: String

    /// Everything that changes as the walker moves.
    ///
    /// Equatable so the app can tell whether a new position actually changed
    /// anything worth showing. A fix arrives every few meters; pushing an
    /// identical instruction each time would spend the system's update budget
    /// redrawing the same words.
    struct ContentState: Codable, Hashable {
        /// The maneuver ahead, as a sentence.
        let instruction: String

        /// How far to it, already in feet or miles, or `nil` before the first fix.
        let distanceToManeuver: String?

        /// SF Symbol for the maneuver.
        let symbol: String

        /// The instruction after this one, for the second line when there is room.
        let following: String?

        let timeRemaining: String
        let distanceRemaining: String
        let climbRemaining: String

        /// The steep ground around the walker, when there is any worth marking.
        let climb: Climb?

        let hasArrived: Bool
    }

    /// A steepness warning, reduced to what it takes to draw one.
    ///
    /// The band is decided here and sent as a band, rather than as a raw grade
    /// the extension re-judges. Both sides share the one definition of steep,
    /// so the same hill cannot come out red on the map and amber on the Lock
    /// Screen; all the extension does with it is look up a color.
    struct Climb: Codable, Hashable {
        let grade: Grade
        let percentage: String
    }
}
