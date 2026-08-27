//  RouteOptions.swift
//
//  Produces the handful of routes shown to the walker.
//
//  A dozen independent searches run at different settings, each one proving the
//  cheapest route for a different idea of what a hill is worth. Most of what
//  comes back is not worth showing: many settings agree, some produce routes
//  that are worse in every way than another, and some wander further than the
//  walker said they were willing to go. What survives is a frontier of genuine
//  trades, and up to three well-separated points on it become the cards.
//
//  The filter that matters is domination. A route is worth offering only if
//  nothing else on the list beats it on both counts at once — if it is slower
//  than another route and climbs more than that route, there is no walker who
//  would pick it, whatever their taste. Anything left is optimal for somebody.
//
//  That is a stronger statement than the rule it replaced, which asked each
//  option to save a fixed amount of climb per extra minute. That rule was an
//  approximation of this one, tuned by hand against a dozen trips; domination
//  needs no tuning and cannot throw away a route that was genuinely the best
//  answer for some walker.
//
//  Domination does not catch everything, though, which is why the overlap check
//  survives alongside it. Two routes a block apart for one stretch of an
//  otherwise identical walk can both be non-dominated and still not be a choice
//  — they are the same corridor described twice, and offering both is clutter
//  rather than an option.

import Foundation

/// One route on offer, measured and named.
struct RouteOption: Identifiable {
    /// Position in the offered list, quickest first.
    ///
    /// The routes come off a frontier rather than from a fixed set of settings,
    /// so there is no longer a dial to identify one by. Position is what stays
    /// meaningful across a replan: the first card is the most direct way on
    /// offer and the last is the flattest, both before and after the recompute,
    /// so a walker's selection survives it.
    let id: Int

    /// What the card calls this route. Read off what the route measures against
    /// the others being offered, not off the settings that found it.
    let name: String

    /// Node indices from start to destination, for drawing and for navigation.
    let nodes: [Int]

    /// The edges between those nodes. Carried rather than re-derived because
    /// both the measuring and the overlap test need them.
    let edges: [Int]

    let metrics: RouteMetrics

    /// What this walker thought a hill was worth — the settings the search that
    /// found this route ran on.
    ///
    /// Deliberately not shown to anyone. The cards are named for what they
    /// measure against each other rather than for the dial that produced them,
    /// and nothing here changes that. It is carried because a route can be
    /// re-planned after it is offered — sent through a point the walker pressed
    /// on the map — and the leg that comes back has to be the same kind of walk
    /// as the one they chose. Re-planning the flattest option at a neutral
    /// setting would hand back the direct route under the flat route's name.
    let cost: WalkingCost
}

/// How far out of the way a flat route may go, as a multiple of the quickest
/// route's walking time.
///
/// The walker's own permission, and it genuinely varies. Fetching something two
/// blocks away and setting out to cross the city without climbing anything are
/// not the same errand, and a bound that suits one is wrong for the other, so
/// this is a control rather than a constant.
enum DetourTolerance: Double, CaseIterable, Identifiable, Hashable {
    case slight = 1.25
    case moderate = 1.5
    case generous = 1.75

    /// What the walk is allowed to cost, as a multiple of the quickest option.
    var multiple: Double { rawValue }

    var id: Double { rawValue }

    /// Written as the extra time it permits rather than as a multiplier, which
    /// is the question actually being asked: how much longer are you willing to
    /// walk to climb less.
    var label: String {
        switch self {
        case .slight: "+25%"
        case .moderate: "+50%"
        case .generous: "+75%"
        }
    }

    /// Halfway up the range. Enough room for the flat way round a hill on most
    /// city trips without licensing the twenty-minute circuit that the widest
    /// setting allows.
    static let `default` = DetourTolerance.moderate
}

enum RouteOptions {
    /// The settings the router sweeps, from the walker who barely minds hills to
    /// the one who will do almost anything to avoid them.
    ///
    /// Two dials move together down the list. `uphillSuffering` buys gentler
    /// blocks; `ascentWeight` buys less total climbing, in seconds paid per
    /// meter gained. Both are needed, because they fail differently: grade
    /// aversion alone will accept a long steady rise as long as no block is
    /// steep, and a climb charge alone will accept a wall if it is short.
    ///
    /// The far end of the range looks absurd priced against a short walk — a
    /// minute of walking traded for a meter of climb — and that is fine. Those
    /// rows exist so that the genuinely level way across the city is found at
    /// all when one exists; on a trip where it does not, they return something
    /// dominated or something too long, and the filtering drops them unread.
    ///
    /// The first run is neutral: it anchors the detour budget to a direct route
    /// and gives the hill-aware runs something meaningful to improve upon.
    static let sweep: [WalkingCost] = [
        // The direct baseline anchors the detour budget and gives every flatter
        // candidate an honest route to trade time against.
        WalkingCost(uphillSuffering: 0, ascentWeight: 0),
        WalkingCost(uphillSuffering: 0.3, ascentWeight: 2),
        WalkingCost(uphillSuffering: 0.5, ascentWeight: 4),
        WalkingCost(uphillSuffering: 1.0, ascentWeight: 6),
        WalkingCost(uphillSuffering: 1.5, ascentWeight: 8),
        WalkingCost(uphillSuffering: 2.0, ascentWeight: 12),
        WalkingCost(uphillSuffering: 3.0, ascentWeight: 16),
        WalkingCost(uphillSuffering: 4.0, ascentWeight: 22),
        WalkingCost(uphillSuffering: 6.0, ascentWeight: 30),
        WalkingCost(uphillSuffering: 8.0, ascentWeight: 45),
        WalkingCost(uphillSuffering: 12.0, ascentWeight: 60),
    ]

    /// Two more runs that refuse steep blocks outright instead of pricing them.
    ///
    /// Qualitatively different from the sweep above, not simply further along
    /// it. A penalty can always be outweighed: make the detour long enough and
    /// the expensive block wins anyway, so no setting in the sweep can promise a
    /// route free of hard climbs. A ceiling promises exactly that, and is the
    /// only thing that finds the level corridor through a city whose grid does
    /// not otherwise offer one.
    ///
    /// Paired with a middling price on grade and a walker's own exchange rate
    /// for climb, since the ceiling is doing the steering and the dials only
    /// have to choose sensibly among what it leaves.
    ///
    /// Either run can find nothing, which is not a failure and is not reported:
    /// it means this city offers no such way between these two points, and the
    /// penalty-based results are the answer.
    static let gradeCeilings: [WalkingCost] = [
        WalkingCost(uphillSuffering: 1.0, ascentWeight: 6, steepestClimb: 0.08),
        WalkingCost(uphillSuffering: 1.0, ascentWeight: 6, steepestClimb: 0.06),
    ]

    /// How much of a candidate's mileage may retrace an already-accepted route
    /// before the two are the same road to a walker looking at a phone.
    ///
    /// Lowering this returns fewer, more clearly distinct options; raising it
    /// starts offering near-copies.
    static let duplicateOverlap = 0.85  // TUNE

    /// The most cards worth putting in front of anyone. Past three the walker is
    /// comparing rather than choosing.
    static let maximumOptions = 3

    /// The least difference in climb that reads as a different walk, in meters.
    ///
    /// Cards state climb to the nearest five feet, so anything under a couple of
    /// meters is the same number twice. This is set well above that: two options
    /// have to differ by something the walker can feel on the way up, not just
    /// by something the display can render.
    static let minimumClimbSeparation = 5.0  // TUNE

    /// The same threshold as a share of the most-climbing option, for trips
    /// where the absolute figure is meaningless.
    ///
    /// Fifteen feet apart is a real choice on a walk that climbs forty; on one
    /// that climbs four hundred it is noise, and the two cards would differ by
    /// less than the elevation data's own error.
    static let minimumClimbSeparationShare = 0.15  // TUNE

    /// The routes worth offering between two nodes: at most three, sometimes
    /// one, and none at all if nothing connects them.
    ///
    /// Every candidate is a full independent search rather than a variation on
    /// the last. A dozen searches over a city-sized graph are still a small
    /// fraction of a second, and a route separately proved optimal for a
    /// particular tolerance of hills is a genuinely different answer — not the
    /// first route nudged sideways until it looked different enough.
    static func between(
        start: Int,
        destination: Int,
        in graph: WalkingGraph,
        tolerance: DetourTolerance = .default
    ) -> [RouteOption] {
        let frontier = paretoFrontier(candidates(start: start, destination: destination, in: graph))

        // The quickest survivor sets the bar and always clears it, so this can
        // never empty a non-empty list.
        guard let quickest = frontier.map(\.metrics.time).min() else { return [] }
        let withinReach = frontier.filter { $0.metrics.time <= quickest * tolerance.multiple }

        return named(spread(distinct(withinReach)))
    }

    /// Every route the sweep and the ceiling runs find, measured, unfiltered.
    ///
    /// Separate from `between` so that what the filtering does can be seen and
    /// checked against what it was given. Expect duplicates: on a short walk
    /// every setting finds the same route, which is the correct answer and not a
    /// sign of anything wrong.
    static func candidates(start: Int, destination: Int, in graph: WalkingGraph) -> [Candidate] {
        let costs = sweep + gradeCeilings
        var found = costs.compactMap {
            candidate(start: start, destination: destination, in: graph, cost: $0)
        }

        // Scalar cost sweeps can all settle on one corridor even when the street
        // graph contains useful alternatives. Re-run representative preferences
        // while making the direct corridor temporarily expensive. The surcharge
        // is search-only: cards still report the route's honest time and climb.
        if let directEdges = found.first?.edges, !directEdges.isEmpty {
            let corridor = Set(directEdges)
            for cost in diversificationCosts {
                if let alternative = candidate(
                    start: start,
                    destination: destination,
                    in: graph,
                    cost: cost,
                    penalizedEdges: corridor
                ) {
                    found.append(alternative)
                }
            }
        }

        return found
    }

    /// Preferences sampled for explicit corridor alternatives. Four extra A*
    /// runs are enough to cover direct, moderate, strong, and extreme hill
    /// avoidance without doubling the complete sweep.
    private static var diversificationCosts: [WalkingCost] {
        [sweep[0], sweep[3], sweep[6], sweep[sweep.count - 1]]
    }

    private static func candidate(
        start: Int,
        destination: Int,
        in graph: WalkingGraph,
        cost: WalkingCost,
        penalizedEdges: Set<Int> = []
    ) -> Candidate? {
        guard let route = AStar.route(
            from: start,
            to: destination,
            in: graph,
            cost: cost,
            penalizedEdges: penalizedEdges,
            edgePenaltyMultiplier: 2.5
        ) else { return nil }

        let edges = graph.edges(along: route.nodes)
        return Candidate(
            nodes: route.nodes,
            edges: edges,
            metrics: RouteMetrics(edges: edges, in: graph),
            cost: cost
        )
    }

    /// A route found by one run, before anything has decided whether it is worth
    /// showing. It has no name and no place in the list yet, because both of
    /// those are read off the other survivors.
    struct Candidate {
        let nodes: [Int]
        let edges: [Int]
        let metrics: RouteMetrics

        /// The settings this run used. Carried through the filtering so that
        /// whichever candidates become cards can still say what kind of walker
        /// they were found for.
        let cost: WalkingCost
    }

    // MARK: - Filtering

    /// Whether every walker would prefer `winner` to `loser`.
    ///
    /// True when the winner is no worse on either count and better on at least
    /// one. Time and climb are the two counts, and distance deliberately is not:
    /// a longer way round that climbs less is exactly the trade this app exists
    /// to offer, so counting distance against it would drop the routes worth
    /// having.
    static func dominates(_ winner: RouteMetrics, _ loser: RouteMetrics) -> Bool {
        let noWorse = winner.time <= loser.time && winner.elevationGain <= loser.elevationGain
        let better = winner.time < loser.time || winner.elevationGain < loser.elevationGain
        return noWorse && better
    }

    /// The candidates nothing else beats outright, quickest first.
    ///
    /// What is left is the set of honest trades: every one of them is the right
    /// answer for some walker's exchange rate between minutes and meters
    /// climbed, and every one dropped is the wrong answer for all of them.
    static func paretoFrontier(_ candidates: [Candidate]) -> [Candidate] {
        candidates
            .filter { candidate in
                !candidates.contains { dominates($0.metrics, candidate.metrics) }
            }
            .sorted { $0.metrics.time < $1.metrics.time }
    }

    /// Drops candidates that retrace one already kept.
    ///
    /// Domination handles a route that is worse; this handles one that is barely
    /// different. Kept in quickest-first order, so the survivor of a group of
    /// near-identical routes is the one that takes the least time — including,
    /// always, the quickest route overall, which is the anchor every other card
    /// is a trade against.
    static func distinct(_ candidates: [Candidate]) -> [Candidate] {
        var kept: [Candidate] = []
        var keptEdges: [Set<Int>] = []

        for candidate in candidates.sorted(by: { $0.metrics.time < $1.metrics.time }) {
            let edges = Set(candidate.edges)
            guard !keptEdges.contains(where: { overlap(of: edges, with: $0) > duplicateOverlap }) else {
                continue
            }
            kept.append(candidate)
            keptEdges.append(edges)
        }

        return kept
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

    // MARK: - Choosing what to show

    /// Up to three points spread across the frontier by how much they climb.
    ///
    /// Spread by climb, not by position in the list. The frontier can hold eight
    /// routes whose climb figures differ by a few feet and one that differs by
    /// three hundred, and picking every third entry would hand the walker three
    /// versions of the same walk while dropping the one that was the point.
    ///
    /// The two ends are the trade at its widest: the most direct way on offer
    /// and the flattest. The middle card is whichever route sits furthest from
    /// both — the one that most nearly halves the choice rather than restating
    /// one of its ends.
    ///
    /// A card that is not far enough from the ones already chosen is not shown
    /// at all. If a trip supports only one honest answer, one is what it gets:
    /// three cards reading 315, 310 and 305 feet are the same walk described
    /// three times, and the padding costs the walker the ability to see that
    /// there was never a choice to make.
    static func spread(_ frontier: [Candidate]) -> [Candidate] {
        let byTime = frontier.sorted { $0.metrics.time < $1.metrics.time }
        guard let quickest = byTime.first, let flattest = byTime.last else { return [] }
        guard byTime.count > 1, separated(quickest, flattest) else {
            return [quickest]
        }

        var chosen = [quickest, flattest]

        // The middle card has to stand apart from both ends, so it is chosen by
        // whichever candidate's nearest end is furthest away.
        let middle = byTime.dropFirst().dropLast().max { left, right in
            climbGap(left, from: chosen) < climbGap(right, from: chosen)
        }
        if let middle, chosen.allSatisfy({ separated($0, middle) }) {
            chosen.append(middle)
        }

        return chosen.sorted { $0.metrics.time < $1.metrics.time }
    }

    /// Whether two routes differ in climb by enough to be different walks.
    private static func separated(_ one: Candidate, _ other: Candidate) -> Bool {
        let climbs = [one.metrics.elevationGain, other.metrics.elevationGain]
        let threshold = max(minimumClimbSeparation, (climbs.max() ?? 0) * minimumClimbSeparationShare)
        return abs(climbs[0] - climbs[1]) >= threshold
    }

    /// How far a candidate's climb sits from the nearest already-chosen one.
    private static func climbGap(_ candidate: Candidate, from chosen: [Candidate]) -> Double {
        chosen
            .map { abs($0.metrics.elevationGain - candidate.metrics.elevationGain) }
            .min() ?? 0
    }

    /// Turns the chosen routes into cards, named for what they are relative to
    /// each other.
    ///
    /// The names describe the measured trade rather than the settings that
    /// produced it, because the settings no longer map to anything a walker
    /// could be told. A route found at the harshest setting in the sweep is not
    /// necessarily the flattest one offered, and calling it "Flattest" because
    /// of where it came from would be a claim about the dial rather than about
    /// the walk.
    ///
    /// "Direct" rather than "Quickest": it is the most direct of the routes
    /// offered, and none of them is the quickest way there. The quickest way is
    /// straight over the hill, which this app declines to look for.
    ///
    /// A single option carries the flat name. Nothing flatter was worth
    /// offering — either the city has nothing flatter to offer between these two
    /// points, or what it has lies further out of the way than the walker said
    /// they would go — so within what was asked for, this is the flattest walk
    /// there is.
    private static func named(_ chosen: [Candidate]) -> [RouteOption] {
        let names: [String]
        switch chosen.count {
        case 0, 1: names = ["Flattest"]
        case 2: names = ["Direct", "Flattest"]
        default: names = ["Direct", "Flatter", "Flattest"]
        }

        return chosen.prefix(maximumOptions).enumerated().map { position, candidate in
            RouteOption(
                id: position,
                name: names[position],
                nodes: candidate.nodes,
                edges: candidate.edges,
                metrics: candidate.metrics,
                cost: candidate.cost
            )
        }
    }
}
