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

import MapKit
import SwiftUI

enum Theme {

    // MARK: Surfaces

    /// The map's surround and the color behind everything.
    ///
    /// The ground behind everything, seen only at the edges of a floating panel
    /// and inside the rings drawn around map markers. Darker than any panel,
    /// because its whole job is to be the thing a panel is lifted off.
    static let background = Color(hex: 0x10151B)

    /// Every panel: the trip sheet, the search card, the instruction banner.
    ///
    /// Pitched into the same tonal family as the dark basemap rather than below
    /// it. A near-black panel under a blue-slate map is a tonal cliff — the map
    /// stops and a wall starts — and no amount of rounding the corners fixes a
    /// value that far apart. At this weight the panel reads as the same material
    /// as the ground it covers, just nearer.
    static let panelBackground = Color(hex: 0x20272F)

    /// Controls that sit *on* a panel: a search field, the segment holding the
    /// selection.
    ///
    /// White at a few percent rather than another opaque slate. A fixed color
    /// has to be re-picked every time the surface under it moves; a sheer white
    /// lightens whatever it is laid over by the same amount, so one token works
    /// on the panel, on the card, and over the map.
    static let raised = Color.white.opacity(0.06)

    /// Divider and edge color. A hairline of this over a filled panel does the
    /// work that a border and a corner radius would otherwise do, and leaves the
    /// map as the thing on screen.
    static let hairline = Color.white.opacity(0.09)

    /// Darkens the map while a panel has the walker's whole attention. Deep
    /// enough to take the contrast out of the basemap, sheer enough that the
    /// ground underneath is still legible as context.
    static var scrim: Color { background.opacity(0.76) }

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

    /// The selected route's color at a point `distance` of the way along it,
    /// from the walker at 0 to the destination at 1.
    ///
    /// A brightness falloff along one hue, not a second color. The line is
    /// strongest where the walker is standing, because that is where the next
    /// decision is, and deepens ahead of them — which gives the route a
    /// direction to be read in without spending a color to say so.
    ///
    /// The far end is held well above the value of the basemap's own streets.
    /// Taking it darker would reproduce, in emerald, exactly the fault the pale
    /// blue alternative line had: a route that sinks into the map it is drawn
    /// on.
    ///
    /// Interpolated here rather than handed to a gradient because MapKit does
    /// not render one. `MapPolyline.stroke` takes any `ShapeStyle`, and quietly
    /// flattens a `LinearGradient` to a single flat color — verified on device
    /// by driving the far stop to pure red and seeing none of it. The falloff is
    /// therefore drawn as a run of solid segments, which is also the only form
    /// that follows the path rather than the bounding box.
    static func routeShade(at distance: Double) -> Color {
        let t = min(max(distance, 0), 1)
        return Color(
            .sRGB,
            red: 0,
            green: 0.831 + (0.576 - 0.831) * t,
            blue: 0.667 + (0.486 - 0.667) * t
        )
    }

    /// How many solid runs the selected route is drawn in.
    ///
    /// Enough that the steps between them are not visible at street zoom,
    /// few enough that a cross-town walk is still a couple of dozen overlays
    /// rather than a couple of hundred.
    static let routeShadeCount = 28

    /// The stretch of route that exists because the walker refused a hill.
    ///
    /// Drawn as a wash under the line rather than as a color of its own: the
    /// detour is route like the rest of it, and painting it differently would
    /// say the walker had been given a second, lesser kind of road. It has to
    /// be visible only because it is the one part of the line that answers a
    /// tap — the glow is what says "this stretch is yours to undo".
    static var detourGlow: Color { accent.opacity(0.22) }

    /// Routes on offer but not chosen.
    ///
    /// The same emerald held far back, rather than a second hue. A pale blue
    /// here was the one genuinely muddy thing on the map: it sat at the value of
    /// the basemap's own streets, so it read as a piece of the map rather than
    /// as an answer, and it made "which line is the route?" a question about
    /// color instead of about weight. One hue, and the selection carried by
    /// brightness and thickness — the same way the chooser carries it.
    static var routeAlternative: Color { accent.opacity(0.30) }

    /// The destination flag. Deliberately outside both the accent and the
    /// semantic palette: it is a place, not a state and not a hazard.
    static let destination = Color(hex: 0xE8E4DA)

    // MARK: Basemap

    /// How the ground underneath is drawn.
    ///
    /// Points of interest are off. Apple's are a saturated orange, pink and
    /// yellow scattered at high density across exactly the streets a route runs
    /// along, and every one of them is brighter than anything this app draws.
    /// The result is that the single most saturated thing on screen is never the
    /// route — the eye is pulled to a cheesecake restaurant while the answer to
    /// the walker's question sits underneath it. They cannot be restyled, only
    /// admitted or not, so they are not admitted.
    ///
    /// Flat rather than realistic elevation: this app has one thing to say about
    /// terrain, it says it on the route line, and a shaded 3-D hillside would be
    /// a second, louder, less precise version of the same claim.
    static let mapStyle = MapStyle.standard(
        elevation: .flat,
        pointsOfInterest: .excludingAll,
        showsTraffic: false
    )

    // MARK: Type

    /// Words, in a warm off-white rather than a system near-white.
    ///
    /// Deliberately against the grain of the surfaces. Everything else on screen
    /// — basemap, panels, controls — is a cool slate, and cool text on it is the
    /// default no one chose. A warm ramp reads as lit rather than as printed,
    /// and gives the panel the one thing a flat fill cannot supply on its own.
    static let primaryText = Color(hex: 0xE8E3D8)
    static let secondaryText = Color(hex: 0xA9A296)
    static let tertiaryText = Color(hex: 0x6F6A60)

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

        /// The trip's two ends travelling between the foot of the map and the
        /// search card at the top. Slightly slower than a selection because the
        /// walker has to follow the rows with their eye to understand that the
        /// thing they tapped is the thing that moved.
        static let sheet = Animation.spring(response: 0.42, dampingFraction: 0.86)
    }

    // MARK: Measurements

    enum Line {
        /// The chosen route, drawn heaviest.
        static let selected: CGFloat = 7

        /// The rest, drawn thinner so the pile reads as one answer and some
        /// context rather than three equal lines.
        static let alternative: CGFloat = 4

        /// The wave drawn over a steep stretch. Narrower than the line beneath
        /// so the straight route still reads through it: the mark says the
        /// walking here is work, not that the route goes somewhere else.
        static let hill: CGFloat = 3.5

        /// How far to either side of the route the hill wave reaches, in
        /// points.
        ///
        /// Set wide enough to clear the route line it is drawn over. At half
        /// that the wave stays inside the line's own width and reads as a
        /// serrated edge -- something slightly wrong with the drawing rather
        /// than a mark someone put there on purpose. It has to break the
        /// line's silhouette to say that this stretch is different.
        static let hillAmplitude: CGFloat = 7

        /// Ground covered by one full turn of the hill wave, in points.
        ///
        /// Tight enough that a single steep block carries several full cycles,
        /// which is what makes the mark read as roughness rather than as a
        /// couple of kinks in the route.
        static let hillWave: CGFloat = 10

        /// The casing under a stretch the walker's own tap put on the route.
        /// Wider than the line it sits beneath, so it reads as a glow around
        /// that stretch rather than as another route crossing it.
        static let detour: CGFloat = selected + 7

        static func stroke(_ width: CGFloat) -> StrokeStyle {
            StrokeStyle(lineWidth: width, lineCap: .round, lineJoin: .round)
        }
    }

    /// The emerald rail beside a selected row, echoing the line on the map.
    enum Rail {
        static let width: CGFloat = 3
        static let height: CGFloat = 26
    }

    /// Corner radii. Only things that leave the edges of the screen are rounded
    /// — a panel anchored to the bottom is a part of the frame and stays square,
    /// while the search card floats and has to say so.
    enum Radius {
        /// The trip sheet and the navigation banner: the large panels that hold
        /// a screen's worth of content and float clear of every edge.
        static let sheet: CGFloat = 26

        /// A floating card.
        static let card: CGFloat = 18

        /// A control on a card: a field, a segment track.
        static let control: CGFloat = 12

        /// The moving part inside a segment track.
        static let segment: CGFloat = 9
    }

    /// The gutter a floating card keeps from the edges of the screen, and the
    /// gap it keeps below the status bar. Not flush to the top: a card pinned
    /// under the clock reads as a system bar rather than as something the walker
    /// summoned and can dismiss.
    enum Inset {
        static let card: CGFloat = 12
        static let cardTop: CGFloat = 10

        /// The gutter the trip sheet and the navigation panels keep from the
        /// sides and the bottom of the screen.
        ///
        /// Not decoration. A panel that spans the full width and runs off the
        /// bottom edge has no outside, so the map appears to end where it starts
        /// — the seam reads as the bottom of the world. Leaving map visible down
        /// both sides and underneath is what makes the same panel read as
        /// something laid on the map rather than something the map stops for.
        static let sheet: CGFloat = 10
    }

    /// The backing for anything that floats: a blur that takes its color from
    /// the map showing through, tinted back toward the panel tone.
    ///
    /// Material alone goes the gray of whatever is under it; the tint alone is
    /// an opaque slab. Together the panel keeps one tone across the screen while
    /// still admitting that there is a map behind it.
    struct FloatingSurface: ViewModifier {
        var radius: CGFloat = Radius.sheet

        func body(content: Content) -> some View {
            let shape = RoundedRectangle(cornerRadius: radius, style: .continuous)

            return content
                // Clipped before it is backed, so that a selected row's wash
                // and the rules between rows stop at the rounded corner instead
                // of squaring it off from the inside.
                .clipShape(shape)
                .background(.ultraThinMaterial, in: shape)
                .background(panelBackground.opacity(0.9), in: shape)
                .overlay {
                    // Catches the light along the top edge the way a raised
                    // surface does, which is what separates the panel from the
                    // map without a rule drawn between them.
                    shape.strokeBorder(
                        LinearGradient(
                            colors: [.white.opacity(0.14), .white.opacity(0.04)],
                            startPoint: .top,
                            endPoint: .bottom
                        ),
                        lineWidth: 0.5
                    )
                }
                .shadow(color: .black.opacity(0.5), radius: 24, y: 10)
        }
    }
}

extension View {
    /// Lifts a panel off the map: blurred, tinted, rounded on every corner, and
    /// carrying a shadow onto the ground below it.
    func floatingSurface(radius: CGFloat = Theme.Radius.sheet) -> some View {
        modifier(Theme.FloatingSurface(radius: radius))
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
