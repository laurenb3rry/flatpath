//  HillDetour.swift
//
//  Sending a route around a hill the walker pointed at.
//
//  The route options are the app's answer to "how much climbing will you do at
//  all". This is the answer to a narrower question, asked about one hill on one
//  route: not this one. The walker can see the marked stretch on the map and
//  knows something the router does not — that the block is under scaffolding,
//  that they are carrying something, that they have walked it before and would
//  rather not again.
//
//  So the search here is deliberately local. A fresh plan of the whole trip
//  would be the easy thing to run, and it would answer the wrong question: the
//  route would rearrange itself from end to end, and the walker who objected to
//  one block would be handed a different walk to re-read. Instead a short
//  stretch of route on either side of the hill is re-planned in place and the
//  rest is left exactly where it was drawn.
//
//  Avoidances are kept as a list against the route they were asked of, and the
//  displayed route is rebuilt from the original every time that list changes.
//  That is what makes them independently undoable: dropping one from the list
//  and rebuilding restores the ground it replaced without disturbing the others,
//  which a stack of edits applied in place could not do.

import Foundation

/// A hill the walker has asked one route to go around.
struct AvoidedHill: Identifiable, Hashable {
    /// Unique within the route it was asked of. It identifies the detour the
    /// hill produced as well as the hill itself, which is what lets a tap on
    /// the new stretch of road find the avoidance to undo.
    let id: Int

    /// The hill as a chain of nodes, from the foot of the marked stretch to the
    /// top of it.
    ///
    /// Nodes rather than edges, because the way round has to refuse the street
    /// in both directions and an edge index alone does not say where it starts.
    /// The graph stores one edge per ordered pair, so a chain of nodes recovers
    /// the climb and its downhill twin equally well.
    let nodes: [Int]

    /// The band the marked stretch fell in. It sets what the way round is
    /// allowed to climb: a walker refusing a steep block has not agreed to
    /// another one, and the detour is searched with that band ruled out.
    let grade: Grade
}

/// A route with the walker's avoidances spliced into it.
struct DetouredRoute {
    let nodes: [Int]
    let edges: [Int]

    /// The avoidance that put each edge here, `nil` for ground the route
    /// covered before anything was asked of it. Parallel to `edges`.
    ///
    /// This is what the map draws the new stretches from and what a tap on one
    /// of them resolves to, so it records only genuinely new ground: where a
    /// detour rejoins the street it replaced for a block, those edges are
    /// original again and tapping them does nothing.
    let detouredBy: [Int?]

    /// The avoidances that changed the route. One the city could not honour is
    /// missing from here, which is how the caller knows to say so.
    let applied: Set<AvoidedHill.ID>
}

enum HillDetour {
    /// How much route on each side of the hill the detour may re-plan, in
    /// meters.
    ///
    /// The hill's own two ends are the tightest possible anchors and they are
    /// too tight: every path between them gains the same height, so pinning the
    /// detour there can only find a gentler way up, never a way that skirts the
    /// rise altogether. A couple of blocks of slack is what lets the search
    /// leave before the climb starts and come back after it, which on a city
    /// grid is usually where the flat way round is.
    ///
    /// Wider would find more, and would stop being local: at four or five
    /// blocks the walker who objected to one hill gets a different trip back.
    static let approachReach = 150.0

    /// How much longer the way round may take than the stretch it replaces, as
    /// a multiple.
    ///
    /// Generous, because the stretch being replaced is short — three times a
    /// two-minute climb is six minutes, not an afternoon — and because a walker
    /// who has just pointed at a hill and said no has stated their willingness
    /// to walk further in the clearest terms the app offers.
    static let longestDetour = 3.0

    /// Seconds of slack on top of that multiple.
    ///
    /// A hill can be one short brutal block. Three times forty seconds is two
    /// minutes, which is not enough road to get around anything, and without
    /// this floor the steepest stretches in the city would be the ones the app
    /// refused to route around.
    static let detourAllowance = 120.0

    /// What the way round prices hills at.
    ///
    /// Deliberately hill-averse rather than neutral: the walker has just said
    /// what they think of this ground, and a detour found at the direct setting
    /// would answer them with the next steep block over. The middle of the
    /// route sweep, which is roughly "will walk a long way round a real hill,
    /// will not walk around every rise".
    private static let avoidance = WalkingCost(uphillSuffering: 2.0, ascentWeight: 12)

    /// The route as the walker has asked for it: the original, with a local way
    /// round every hill they have refused.
    ///
    /// Avoidances are applied in the order they were asked for, and each one is
    /// found against the route the ones before it produced. An avoidance whose
    /// hill is no longer on the route — an earlier detour having already left
    /// that ground — is skipped rather than dropped, so that undoing the
    /// earlier one brings it back into effect.
    static func apply(
        _ hills: [AvoidedHill],
        to base: RouteOption,
        in graph: WalkingGraph
    ) -> DetouredRoute {
        var nodes = base.nodes
        var edges = base.edges
        var detouredBy = [Int?](repeating: nil, count: edges.count)
        var applied: Set<AvoidedHill.ID> = []

        for hill in hills {
            let climb = graph.edges(along: hill.nodes)
            guard let window = window(around: climb, in: edges, graph: graph) else { continue }

            let replaced = Array(edges[window.edges])
            guard let way = wayAround(
                hill,
                climb: climb,
                from: nodes[window.nodes.lowerBound],
                to: nodes[window.nodes.upperBound],
                replacing: replaced,
                in: graph
            ) else { continue }

            // Ground the detour shares with the stretch it replaced is not new
            // ground, whatever the search did to arrive at it. Marking it as the
            // detour's would put a tap target on a block the walker never asked
            // to change and never saw change.
            let kept = Set(replaced)

            nodes.replaceSubrange(window.nodes, with: way.nodes)
            edges.replaceSubrange(window.edges, with: way.edges)
            detouredBy.replaceSubrange(
                window.edges,
                with: way.edges.map { kept.contains($0) ? nil : hill.id }
            )
            applied.insert(hill.id)
        }

        return DetouredRoute(nodes: nodes, edges: edges, detouredBy: detouredBy, applied: applied)
    }

    /// The stretch of route a detour is allowed to replace: the hill, plus the
    /// approach on either side of it.
    ///
    /// Edge `i` of a route joins its nodes `i` and `i + 1`, so a run of edges
    /// `first ..< last` is bounded by the nodes `first` and `last`. Both are
    /// carried because the splice needs to replace the nodes and the edges
    /// together, and deriving one from the other at the call site is where an
    /// off-by-one would put a gap in the drawn line.
    private struct Window {
        let nodes: ClosedRange<Int>
        let edges: Range<Int>
    }

    private static func window(
        around climb: [Int],
        in edges: [Int],
        graph: WalkingGraph
    ) -> Window? {
        let hill = Set(climb)
        let positions = edges.indices.filter { hill.contains(edges[$0]) }
        guard let first = positions.first, let last = positions.last else { return nil }

        var before = first
        var approach = 0.0
        while before > 0, approach < approachReach {
            before -= 1
            approach += Double(graph.edgeLength[edges[before]])
        }

        var after = last + 1
        approach = 0
        while after < edges.count, approach < approachReach {
            approach += Double(graph.edgeLength[edges[after]])
            after += 1
        }

        return Window(nodes: before ... after, edges: before ..< after)
    }

    /// A local path between the two anchors that is not the hill, or `nil` if
    /// the city has nothing to offer between them.
    ///
    /// Two attempts, and they differ in kind. The first rules out the hill's
    /// whole steepness band, which is the walker's request read literally and
    /// is the only thing that can promise the way round is not another climb of
    /// the same sort. It finds nothing on a hillside with no level way across
    /// it, which is common enough in this city to need an answer — so the
    /// second attempt merely refuses this hill and prices the rest, and is
    /// accepted only if what it found is measurably easier ground.
    private static func wayAround(
        _ hill: AvoidedHill,
        climb: [Int],
        from start: Int,
        to goal: Int,
        replacing original: [Int],
        in graph: WalkingGraph
    ) -> (nodes: [Int], edges: [Int])? {
        let refused = bothDirections(of: hill.nodes, in: graph)
        let replaced = RouteMetrics(edges: original, in: graph)
        let budget = replaced.time * longestDetour + detourAllowance
        let steepestReplaced = steepestClimb(along: original, in: graph)

        let attempts = [
            WalkingCost(
                uphillSuffering: avoidance.uphillSuffering,
                ascentWeight: avoidance.ascentWeight,
                steepestClimb: ceiling(for: hill.grade)
            ),
            avoidance,
        ]

        for cost in attempts {
            guard let route = AStar.route(
                from: start,
                to: goal,
                in: graph,
                cost: cost,
                forbiddenEdges: refused
            ) else { continue }

            let edges = graph.edges(along: route.nodes)
            let metrics = RouteMetrics(edges: edges, in: graph)
            guard metrics.time <= budget else { continue }

            // Easier ground, by one of the two measures a walker could have
            // meant. The first attempt clears this by construction; the second
            // has to earn it, and a way round that is neither gentler nor less
            // climbing is not a way round at all.
            let gentler = steepestClimb(along: edges, in: graph) < steepestReplaced
            guard gentler || metrics.elevationGain < replaced.elevationGain else { continue }

            return (route.nodes, edges)
        }

        return nil
    }

    /// The grade the way round must stay under, read off the band that marked
    /// the hill in the first place. The walker refused what the map drew as
    /// steep, so the detour is searched with steep ruled out.
    private static func ceiling(for grade: Grade) -> Double {
        switch grade {
        case .steep: Grade.steepSlope
        case .moderate, .gentle: Grade.moderateSlope
        }
    }

    /// The hill's edges and their downhill twins.
    ///
    /// Both directions, because a detour that climbs the same street from the
    /// other end has not avoided anything, and because a way round that dips
    /// onto the hill to come straight back off it is the search finding a
    /// loophole rather than a route.
    private static func bothDirections(of nodes: [Int], in graph: WalkingGraph) -> Set<Int> {
        var refused: Set<Int> = []
        for (from, to) in zip(nodes, nodes.dropFirst()) {
            if let uphill = graph.edge(from: from, to: to) { refused.insert(uphill) }
            if let downhill = graph.edge(from: to, to: from) { refused.insert(downhill) }
        }
        return refused
    }

    /// The steepest climb along a stretch, as a signed grade. Descents count as
    /// zero: what is being compared is how hard the way up is.
    private static func steepestClimb(along edges: [Int], in graph: WalkingGraph) -> Double {
        edges.reduce(0.0) { steepest, edge in
            max(steepest, WalkingCost.slope(
                rise: Double(graph.edgeDeltaElevation[edge]),
                over: Double(graph.edgeLength[edge])
            ))
        }
    }
}
