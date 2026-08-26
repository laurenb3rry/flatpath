//  Theme.swift
//
//  The visual language: colors, type, motion, and the few measurements that have
//  to agree between screens.
//
//  Three rules hold the whole thing together.
//
//  The accent is reserved. Emerald means the route you chose, the position you
//  are at, and the action that starts you walking -- nothing else. The moment it
//  is spent on decoration it stops answering "which one is selected?", which is
//  the only question the route chooser exists to answer.
//
//  Red and amber are semantic. They mark ground that is steep, and they mark
//  nothing else. A palette that also uses them for emphasis leaves a walker
//  unable to tell a warning from a flourish.
//
//  Figures are monospaced, words are not. Minutes, feet and miles are read by
//  comparing digits in the same column between one route and the next, and a
//  proportional face puts the minutes of one route under the feet of another.

import SwiftUI

enum Theme {

    // MARK: Surfaces

    /// The map's surround and the color behind everything.
    static let background = Color(hex: 0x0E0E10)

    /// Panels laid over the map: the chooser, the trip strip, the instruction
    /// banner. A shade lighter and a shade cooler than the background, which is
    /// enough to separate them without drawing a box around them.
    static let surface = Color(hex: 0x111118)

    /// Divider and edge color. A hairline of this over a filled panel does the
    /// work that a border and a corner radius would otherwise do, and leaves the
    /// map as the thing on screen.
    static let hairline = Color.white.opacity(0.09)

    // MARK: Accent

    /// Emerald. The selected route, the walker's own position, and the primary
    /// action. Never decorative.
    static let accent = Color(hex: 0x00D4AA)

    /// The accent as a background wash, for the selected row. Faint on purpose:
    /// the rail and the weight of the type carry the selection, and this only
    /// has to tie the row to the line drawn on the map.
    static var accentWash: Color { accent.opacity(0.10) }

    // MARK: Semantic

    /// Ground steep enough to change the walk.
    static let steep = Color(hex: 0xF04F56)

    /// Ground steep enough to notice.
    static let moderate = Color(hex: 0xF5A623)

    /// The color a stretch of route is drawn in, or `nil` where it is not worth
    /// marking at all.
    static func warning(for grade: Grade) -> Color? {
        switch grade {
        case .gentle: nil
        case .moderate: moderate
        case .steep: steep
        }
    }

    // MARK: Route lines

    /// Routes on offer but not chosen. Cool and desaturated so that they read as
    /// context for the selected line rather than as competing answers, and so
    /// that the one warm color on the map is always a warning.
    ///
    /// Lighter than a slate would suggest, because the dark basemap draws its
    /// own streets in a neutral gray of about that weight: a route the same
    /// value as the road under it stops reading as a route at all. The tone has
    /// to sit above the street grid while staying well clear of the accent.
    static let routeAlternative = Color(hex: 0x74A8D8)

    /// The destination flag. Deliberately outside both the accent and the
    /// semantic palette: it is a place, not a state and not a hazard.
    static let destination = Color(hex: 0xE8E4DA)

    // MARK: Type

    /// Words.
    static let primaryText = Color(hex: 0xF4F5F7)
    static let secondaryText = Color(hex: 0x9AA3AD)
    static let tertiaryText = Color(hex: 0x5F6670)

    /// Figures — times, heights, distances, coordinates. Anything a walker reads
    /// as a number rather than as a sentence.
    static func figure(_ style: Font.TextStyle, weight: Font.Weight = .regular) -> Font {
        .system(style, design: .monospaced).weight(weight)
    }

    /// Everything that is words.
    static func label(_ style: Font.TextStyle, weight: Font.Weight = .regular) -> Font {
        .system(style, design: .default).weight(weight)
    }

    // MARK: Motion

    /// Springs rather than eased curves, and only where something moves that the
    /// walker set in motion.
    ///
    /// A spring settles the way a thing with weight does, so a card that takes
    /// the selection and a camera that reframes read as the same gesture
    /// continuing rather than as the screen redrawing itself. Nothing here
    /// bounces: overshoot on a map is the ground appearing to wobble.
    enum Motion {
        /// Choosing a route. Quick, because it answers a tap.
        static let selection = Animation.spring(response: 0.32, dampingFraction: 0.84)

        /// Reframing the map. Slower and fully damped: the walker is reading the
        /// ground while it moves, and has to be able to follow it there.
        static let camera = Animation.spring(response: 0.65, dampingFraction: 0.95)

        /// An instruction giving way to the next one.
        static let instruction = Animation.spring(response: 0.4, dampingFraction: 0.88)
    }

    // MARK: Measurements

    enum Line {
        /// The chosen route, drawn heaviest.
        static let selected: CGFloat = 7

        /// The rest, drawn thinner so the pile reads as one answer and some
        /// context rather than three equal lines.
        static let alternative: CGFloat = 4

        /// Steep stretches, laid over the selected route. Narrower than the line
        /// beneath so the emerald still shows at its edges — the warning marks
        /// part of the chosen route rather than replacing it.
        static let warning: CGFloat = 3.5

        static func stroke(_ width: CGFloat) -> StrokeStyle {
            StrokeStyle(lineWidth: width, lineCap: .round, lineJoin: .round)
        }
    }

    /// The emerald rail beside a selected row, echoing the line on the map.
    enum Rail {
        static let width: CGFloat = 3
        static let height: CGFloat = 26
    }
}

private extension Color {
    /// Builds a color from a six-digit hex literal, so the tokens above can be
    /// written the way the design states them.
    init(hex: UInt32) {
        self.init(
            .sRGB,
            red: Double((hex >> 16) & 0xFF) / 255,
            green: Double((hex >> 8) & 0xFF) / 255,
            blue: Double(hex & 0xFF) / 255
        )
    }
}
