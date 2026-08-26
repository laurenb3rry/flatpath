//  RouteOptions.swift
//
//  Produces the handful of routes shown to the walker.
//
//  Runs the search once per hill-aversion setting, then filters the results:
//  candidates that overlap an already-kept route too heavily are dropped, and so
//  are ones that detour far beyond the quickest survivor. Short trips legitimately
//  collapse to a single option -- offering one honest route beats padding the
//  list with near-duplicates.

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
        return kept.filter { $0.metrics.time <= quickest * detourAllowance }
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
