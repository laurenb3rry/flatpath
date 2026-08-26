//  RouteOptions.swift
//
//  Produces the handful of routes shown to the walker.
//
//  Runs the search once per hill-aversion setting, then filters the results:
//  candidates that overlap an already-kept route too heavily are dropped, so are
//  ones that detour far beyond the quickest survivor, and so are ones that ask
//  the walker to pay more and get less. Short trips legitimately collapse to a
//  single option -- offering one honest route beats padding the list with
//  near-duplicates.
//
//  The last of those filters is what keeps the names truthful. The router prices
//  steepness rather than total climb: the misery multiplier grows with how far a
//  block exceeds a comfortable grade, so a high hill-aversion setting will
//  happily accept a few more meters of cumulative climb to keep every block
//  gentle. That is the right thing to optimize -- a 12% block is what hurts, not
//  the arithmetic sum of every rise on the way -- but it is not what the card
//  says. The card leads with total gain, so a route offered beside a quicker one
//  has to beat it on total gain, or it is not a trade the walker can see.

import Foundation

/// One route on offer, measured and named.
struct RouteOption: Identifiable {
    /// The hill-aversion setting the route was found at. It doubles as identity
    /// because the sweep yields at most one route per setting, and it is stable
    /// across replans, so a selection survives the route being recomputed.
    let id: Int

    /// What the card calls this route.
    let name: String

    /// Node indices from start to destination, for drawing and for navigation.
    let nodes: [Int]

    /// The edges between those nodes. Carried rather than re-derived because
    /// both the measuring and the overlap test need them.
    let edges: [Int]

    let metrics: RouteMetrics
}

enum RouteOptions {
    /// How much of a candidate's mileage may retrace an already-accepted route
    /// before the two are the same road to a walker looking at a phone.
    ///
    /// Two lines a block apart for one stretch of an otherwise identical route
    /// are not a choice, they are clutter. Lowering this returns fewer, more
    /// clearly distinct options; raising it starts offering near-copies.
    static let duplicateOverlap = 0.85  // TUNE

    /// How much climb a slower option has to save, in meters, for every extra
    /// minute it asks for.
    ///
    /// Roughly ten feet of climb per minute, which is where the alternatives
    /// this city actually produces separate into two kinds.
    ///
    /// Measured rather than reasoned: across a dozen SF trips, the alternatives
    /// worth having came in at four to six meters of climb saved per extra
    /// minute, and the ones that were not worth having came in at one or less.
    /// Nothing landed in between. The line sits in that gap, so a real
    /// alternative survives and three cards reading 315, 310 and 305 feet — the
    /// same walk described three times — do not.
    ///
    /// Raising this offers fewer and more sharply different routes; lowering it
    /// starts padding the list with distinctions the walker cannot act on.
    static let worthwhileClimbPerMinute = 3.0  // TUNE

    /// How much longer than the quickest surviving route another one may take.
    ///
    /// The flattest way between two points can be absurd — around a hill rather
    /// than over it, twenty minutes for the sake of a hundred feet of climb.
    /// This is the point past which avoiding the hill is no longer a trade the
    /// walker would plausibly make.
    static let detourAllowance = 1.4  // TUNE

    /// Route names, in the order the graph bakes its hill-aversion settings:
    /// least hill-averse first, so the last is the one that will go furthest to
    /// stay level.
    ///
    /// The mildest setting is deliberately not neutral. Pricing hills at zero
    /// reproduces exactly the route every other maps app already gives, which
    /// is the thing this app exists to offer an alternative to.
    static let names = ["Flatter", "Balanced", "Flattest"]

    /// The routes worth offering between two nodes, at most one per setting and
    /// possibly none at all if nothing connects them.
    ///
    /// Each candidate is a full independent search rather than a variation on
    /// the last one. Three searches over a city-sized graph are still a fraction
    /// of a second, and a route that was separately proved optimal for how much
    /// its walker minds hills is a genuinely different answer -- not the first
    /// route nudged sideways until it looked different enough.
    static func between(start: Int, destination: Int, in graph: WalkingGraph) -> [RouteOption] {
        let settings = 0 ..< min(graph.costSettingCount, names.count)

        var kept: [RouteOption] = []
        var keptEdges: [Set<Int>] = []

        for setting in settings {
            guard let route = AStar.route(from: start, to: destination, in: graph, setting: setting) else {
                continue
            }

            let edges = graph.edges(along: route.nodes)
            let candidate = Set(edges)
            guard !keptEdges.contains(where: { overlap(of: candidate, with: $0) > duplicateOverlap }) else {
                continue
            }

            kept.append(
                RouteOption(
                    id: setting,
                    name: names[setting],
                    nodes: route.nodes,
                    edges: edges,
                    metrics: RouteMetrics(edges: edges, in: graph)
                )
            )
            keptEdges.append(candidate)
        }

        // The quickest survivor sets the bar and always clears it, so this can
        // never empty a non-empty list.
        guard let quickest = kept.map(\.metrics.time).min() else { return [] }
        let withinReach = kept.filter { $0.metrics.time <= quickest * detourAllowance }

        return worthOffering(withinReach)
    }

    /// The routes that are actually a choice, quickest first.
    ///
    /// Every card after the first costs the walker time, so it has to give
    /// something back: enough less climbing to be worth the minutes, measured
    /// against the flattest route kept so far rather than against the one beside
    /// it. That single rule covers both ways the list goes wrong. A route that
    /// is slower *and* climbs more gives back nothing at all and is dropped, and
    /// so is one whose saving is too slight to act on.
    ///
    /// Time and climb are the axes, and distance deliberately is not: a longer
    /// way round that climbs less is exactly the trade this app exists to offer.
    private static func worthOffering(_ routes: [RouteOption]) -> [RouteOption] {
        var offered: [RouteOption] = []

        for candidate in routes.sorted(by: { $0.metrics.time < $1.metrics.time }) {
            guard let flattestSoFar = offered.last else {
                // The quickest route is always worth showing: it is the one the
                // walker is being offered alternatives to.
                offered.append(candidate)
                continue
            }

            let minutesCost = (candidate.metrics.time - flattestSoFar.metrics.time) / 60
            let climbSaved = flattestSoFar.metrics.elevationGain - candidate.metrics.elevationGain

            if climbSaved >= minutesCost * worthwhileClimbPerMinute {
                offered.append(candidate)
            }
        }

        return offered
    }

    /// The share of a candidate's edges that an already-kept route also uses.
    ///
    /// Measured against the candidate rather than against the pair, so that a
    /// route which follows a kept one and then breaks away for a long stretch of
    /// its own reads as distinct — it is the new ground that makes it worth
    /// offering, and there is more of that here than the shared prefix suggests.
    ///
    /// Edges are directed, and every candidate runs start to destination, so two
    /// routes down the same street always agree on the edge that represents it.
    private static func overlap(of candidate: Set<Int>, with kept: Set<Int>) -> Double {
        // A route with no edges is the degenerate case of a destination on top
        // of the start. There is nothing to distinguish a second one by, so the
        // first stands and the rest are duplicates of it.
        guard !candidate.isEmpty else { return 1 }
        return Double(candidate.intersection(kept).count) / Double(candidate.count)
    }
}
