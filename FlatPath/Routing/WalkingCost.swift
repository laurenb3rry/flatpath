//  WalkingCost.swift
//
//  What one stretch of walking costs a particular walker, in seconds.
//
//  The graph carries measurements — how long an edge is, how much it rises, how
//  long it takes to walk, whether it crosses a street — and this turns them into
//  the number the router minimizes. It is evaluated once per edge relaxation,
//  tens of thousands of times per search, which is why it reads the flat arrays
//  directly rather than through a materialized edge.
//
//  Computing this here rather than baking it into the file is a deliberate
//  trade. It costs a handful of arithmetic operations per expansion; it buys the
//  ability to change how hills are priced without rebuilding a twenty-megabyte
//  binary and reshipping the app. The dials below are being actively tuned, and
//  a rebuild per constant is not a tuning loop.
//
//  There are two terms and they answer different questions.
//
//  The misery multiplier asks how steep the ground is. It grows with the square
//  of how far a grade exceeds what is comfortable, so a block a little past
//  comfortable stays nearly free while a genuinely steep one becomes expensive
//  fast — which is what bends a route around the block that hurts rather than
//  around every rise.
//
//  The climb charge asks how much of the walk is climbing at all: a flat number
//  of seconds per meter gained, regardless of how gently it is gained. Without
//  it, "flat" meant only "no steep block", and a route that gained two hundred
//  feet at a steady 4% was priced at nothing — every block comfortable, the
//  walker two hundred feet higher, and the card claiming a level walk. This is
//  the term that makes flat mean less climbing.
//
//  Admissibility. The router's heuristic bounds the remaining cost by
//  straight-line distance at peak walking speed, which is only a lower bound if
//  no edge can cost less than the time it takes to walk. That still holds: the
//  misery multiplier is never below 1, the climb charge is never negative, and
//  the crossing charge is never negative, so `seconds(of:in:) >= edgeTime`
//  always. A grade ceiling removes edges from the search rather than discounting
//  them, which cannot lower the cost of any route that remains. Every change
//  here has to preserve that or the search stops proving what it claims to
//  prove: it would return routes it has not finished showing are cheapest,
//  silently and only sometimes.

import Foundation

/// How a walker prices a stretch of walking: what they think of steep ground,
/// what a meter of climb is worth to them, and what they refuse outright.
///
/// One search runs against one of these from start to finish. Producing several
/// route options means running several searches at different settings, which is
/// why this is a value rather than global state.
struct WalkingCost {
    /// How strongly grade past comfortable is minded. Higher settings refuse
    /// steeper blocks and will walk further around them.
    let uphillSuffering: Double

    /// Seconds the walker will spend to avoid one meter of climb.
    ///
    /// Naismith's rule — an hour added per 600 m of ascent — puts an ordinary
    /// walker's own exchange rate near 6 s/m. That is a reference point, not a
    /// ceiling: someone who opened this app to avoid hills will pay several
    /// times it, and the sweep goes well past.
    let ascentWeight: Double

    /// The steepest climb the walker will accept, or `nil` for no limit.
    ///
    /// Different in kind from `uphillSuffering`, not merely stronger. A penalty
    /// can always be outweighed — price a block high enough and a long enough
    /// detour still loses to it — whereas this means never, at any price. It is
    /// how the genuinely level way across the city gets found when one exists,
    /// since no amount of grade aversion can guarantee a route without a single
    /// hard block in it.
    ///
    /// Climbs only. The walker's problem is what they have to go up: descents
    /// are already treated as tolerable to far steeper grades below, and this
    /// city has no crosstown route that descends gently everywhere, so a limit
    /// applied to both directions would find nothing on most trips and offer
    /// the walker nothing in exchange.
    let steepestClimb: Double?

    init(uphillSuffering: Double, ascentWeight: Double, steepestClimb: Double? = nil) {
        self.uphillSuffering = uphillSuffering
        self.ascentWeight = ascentWeight
        self.steepestClimb = steepestClimb
    }

    /// Cost in seconds of walking `edge`, or `nil` if this walker refuses it.
    ///
    /// Never less than the edge's honest walking time — the guarantee the
    /// router's heuristic rests on.
    @inline(__always)
    func seconds(of edge: Int, in graph: WalkingGraph) -> Double? {
        let length = Double(graph.edgeLength[edge])
        let rise = Double(graph.edgeDeltaElevation[edge])
        let slope = Self.slope(rise: rise, over: length)

        if let steepestClimb, slope > steepestClimb { return nil }

        let misery: Double
        if slope >= 0 {
            let excess = max(0, slope - Self.uphillMiseryGrade) / Self.uphillMiseryGrade
            misery = 1 + uphillSuffering * excess * excess
        } else {
            let excess = max(0, -slope - Self.downhillMiseryGrade) / Self.downhillMiseryGrade
            misery = 1 + Self.downhillSuffering * excess * excess
        }

        // The climb charge is levied on the elevation change as measured, not on
        // the guarded slope above, so that it is exactly proportional to the
        // gain figure the route card leads with. A route the router calls twice
        // as expensive in climb is a route the card shows as twice the climb.
        return Double(graph.edgeTime[edge]) * misery
            + ascentWeight * max(0, rise)
            + Self.crossingPenalty * Double(graph.edgeCrossingShare[edge])
    }

    /// Signed grade of an edge, positive uphill, guarded the same way the
    /// offline build guards it when it measures walking time.
    ///
    /// Two mapped nodes can sit centimeters apart, and a real elevation change
    /// divided by that is a grade no street has; a node that landed on a
    /// building edge in the elevation raster produces the same thing. Both would
    /// otherwise price as cliffs and become walls the router steers around.
    @inline(__always)
    static func slope(rise: Double, over length: Double) -> Double {
        let raw = rise / max(length, shortestSlopeRun)
        return min(max(raw, -steepestBelievableGrade), steepestBelievableGrade)
    }
}

// MARK: - The shape of the curve

// These describe what walking feels like rather than what any one walker wants,
// so they are fixed while the dials above vary per route option. The offline
// build states the same numbers, because the walking time it bakes is the term
// this multiplies; the two files have to be changed together.
extension WalkingCost {
    /// Grade above which climbing stops being merely slower and starts being
    /// work. Below it a hill costs only the extra time it takes.
    ///
    /// San Francisco is full of 3–5% blocks. Drawn any higher, all of them are
    /// free, and a route can gain a couple of hundred feet without the cost
    /// function pricing a meter of it.
    static let uphillMiseryGrade = 0.03

    /// Grade above which descending starts to punish the knees. Far higher than
    /// the uphill threshold: gentle descents are a pleasure, and only genuinely
    /// steep ones are work.
    static let downhillMiseryGrade = 0.20

    /// How strongly excess downhill grade is minded. Below every uphill setting
    /// the sweep uses: a steep descent is unpleasant, never as costly as the
    /// same climb.
    static let downhillSuffering = 0.15

    /// Seconds charged for crossing a street.
    ///
    /// Both sides of most SF streets are mapped as their own sidewalks, joined
    /// by marked crossings. Priced at nothing, a crossing is free, so the router
    /// hops the street to save a couple of meters and hops back at the next
    /// corner — technically optimal, and useless to a walker who waits at two
    /// lights to collect it. This is what a crossing actually costs: the wait
    /// and the interruption, not the seconds spent walking it.
    ///
    /// Sized between the two mistakes. Well above the few seconds a pointless
    /// side-swap saves, so those stop happening; well below the ~70 seconds a
    /// block takes to walk, so the router still crosses when crossing is the way
    /// there rather than walking the long side of a block to avoid it.
    ///
    /// Charged once per crossing, not once per segment: the graph records each
    /// segment's share of the crossing it belongs to, so a crossing split in two
    /// by a traffic island does not cost double for being drawn in more detail.
    static let crossingPenalty = 25.0

    /// Length below which an edge's grade is computed as though it were this
    /// long. Guards the ratio, not the reported distance.
    static let shortestSlopeRun = 5.0

    /// The steepest grade treated as terrain. The steepest street in the city is
    /// about 32%, so anything past this is noise in the elevation data.
    static let steepestBelievableGrade = 0.50
}
