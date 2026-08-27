//  RouteVia.swift
//
//  Sending a route through points the walker pressed on the map.
//
//  The route cards answer "how much climbing will you do". This answers a
//  different question, and it is one the app cannot work out on its own: which
//  way round. A walker heading home may want to pass the shop, or walk the side
//  of the park with the trees on it, or simply go a way they know. None of that
//  is in the graph, and none of it is a complaint about hills — so it arrives as
//  a point on the map rather than as a setting.
//
//  What comes back is still a flat route. Each leg between two stops is planned
//  with the same settings that produced the card the walker chose, so steering
//  the flattest option through a point returns the flattest way through that
//  point, not the direct one. Re-planning at a neutral setting instead would
//  hand back the direct route under the flat route's name, which is the one
//  thing this app must not do.
//
//  Stops are held in the order the route reaches them rather than the order they
//  were dropped. A pin placed near the end of a walk and then one near the
//  beginning is a walker refining a line, not asking to double back across the
//  city and return; ordering them along the route is what makes a second pin
//  refine the first instead of undoing it.

import Foundation

/// A route bent through the walker's own stops.
struct ViaRoute {
    let nodes: [Int]
    let edges: [Int]

    /// The stops the route actually reaches, in the order it reaches them.
    ///
    /// A stop the city cannot route through is missing from here rather than
    /// silently dropped, which is how the caller knows to say so instead of
    /// accepting the press and changing nothing.
    let reached: [Int]
}

enum RouteVia {
    /// `base`, re-planned to pass through every stop, or `base` unchanged when
    /// there are none.
    ///
    /// The two ends are fixed. Whatever the walker does with the middle of a
    /// walk, they are still walking from where they are to where they said they
    /// were going, and a stop is a point the route is made to touch rather than
    /// a new destination.
    static func route(
        _ base: RouteOption,
        through stops: [Int],
        in graph: WalkingGraph
    ) -> ViaRoute {
        let unchanged = ViaRoute(nodes: base.nodes, edges: base.edges, reached: [])
        guard !stops.isEmpty, let start = base.nodes.first, let goal = base.nodes.last else {
            return unchanged
        }

        var nodes = [start]
        var reached: [Int] = []
        var current = start

        for (position, stop) in (stops + [goal]).enumerated() {
            let isGoal = position == stops.count

            // A stop that lands on the node the route has already reached costs
            // nothing to honour: the walk goes through it by standing on it.
            guard stop != current else {
                if !isGoal { reached.append(stop) }
                continue
            }

            guard let leg = leg(from: current, to: stop, at: base.cost, in: graph) else {
                // A stop with no way through is skipped and reported. The last
                // leg is the destination itself, and if that cannot be reached
                // from where the stops have led, the whole attempt is abandoned
                // rather than handed back as a walk that stops short.
                if isGoal { return unchanged }
                continue
            }

            nodes.append(contentsOf: leg.dropFirst())
            current = stop
            if !isGoal { reached.append(stop) }
        }

        // Every leg is a chain of neighbours and each is joined to the last at a
        // shared node, so the edges should recover exactly. If they do not, the
        // path is not something the rest of the app can draw or measure — the
        // hill marks and the detours are both indexed by edge position — and the
        // planned route is a better answer than a broken one.
        let edges = graph.edges(along: nodes)
        guard edges.count == nodes.count - 1 else { return unchanged }

        return ViaRoute(nodes: nodes, edges: edges, reached: reached)
    }

    /// One leg, planned the way the chosen route was planned.
    ///
    /// A route found under a grade ceiling can fail here where the whole trip
    /// did not: the ceiling promises a level way from end to end, and there is
    /// no reason the walker's own point sits on one. Rather than refuse the
    /// press, the leg is re-planned with the ceiling lifted and the walker's
    /// aversion to hills left at full strength — still the flattest way through
    /// their point, just no longer able to promise nothing steep on the way.
    private static func leg(
        from: Int,
        to goal: Int,
        at cost: WalkingCost,
        in graph: WalkingGraph
    ) -> [Int]? {
        if let route = AStar.route(from: from, to: goal, in: graph, cost: cost) {
            return route.nodes
        }
        guard cost.steepestClimb != nil else { return nil }

        let lifted = WalkingCost(
            uphillSuffering: cost.uphillSuffering,
            ascentWeight: cost.ascentWeight
        )
        return AStar.route(from: from, to: goal, in: graph, cost: lifted)?.nodes
    }

    /// Where a new stop belongs among the ones a route already has.
    ///
    /// Placed by where the route currently runs nearest to it, not by when it
    /// was dropped. A walker adjusting a line drops points wherever the line is
    /// wrong, in whatever order they notice; taking that as travel order would
    /// turn the second pin into an instruction to walk back across everything
    /// the first one arranged.
    static func insert(
        _ stop: Int,
        into stops: [Int],
        along path: [Int],
        in graph: WalkingGraph
    ) -> [Int] {
        /// How far along the route a node sits. A stop the route no longer
        /// reaches — a refused hill can take the ground it stood on away —
        /// sorts to the end rather than to the front.
        func position(of node: Int) -> Int {
            path.firstIndex(of: node) ?? path.count
        }

        let arrival = position(of: nearestNode(to: stop, along: path, in: graph))
        let slot = stops.firstIndex { position(of: $0) > arrival } ?? stops.count

        var ordered = stops
        ordered.insert(stop, at: slot)
        return ordered
    }

    /// The node of `path` lying nearest to `stop`.
    ///
    /// Compared in degrees with the longitude axis scaled for the latitude,
    /// which is the same equirectangular approximation the graph snaps
    /// coordinates with. Only the winner is wanted, and over a few blocks it
    /// agrees with a proper distance to well within a node's spacing.
    private static func nearestNode(
        to stop: Int,
        along path: [Int],
        in graph: WalkingGraph
    ) -> Int {
        guard let first = path.first else { return stop }

        let latitude = graph.latitudes[stop]
        let longitude = graph.longitudes[stop]
        let shrink = cos(latitude * .pi / 180)

        var nearest = first
        var nearestDistance = Double.infinity

        for node in path {
            let northing = graph.latitudes[node] - latitude
            let easting = (graph.longitudes[node] - longitude) * shrink
            let distance = northing * northing + easting * easting

            if distance < nearestDistance {
                nearestDistance = distance
                nearest = node
            }
        }

        return nearest
    }
}
