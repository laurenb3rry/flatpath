//  AStar.swift
//
//  Shortest-path search over the directed walking graph, minimizing edge cost in
//  seconds. Each run carries one walker's idea of what a hill is worth; running
//  it several times at different settings is what produces the route options.
//
//  Costs are computed here, edge by edge, rather than read from a column baked
//  into the graph. That is what lets a run be parameterized by anything at all
//  instead of by an index into a fixed handful of settings.
//
//  A node is final only when it is popped from the queue, not when it is first
//  discovered, and the search stops when the destination itself is popped. A
//  cheaper path to an already-discovered node can still turn up before that.

import Foundation

/// A route the search proved cheapest, at the settings it ran on.
struct Route {
    /// Node indices from start to destination, both included. Two consecutive
    /// entries are always joined by an edge, which is what lets the map draw
    /// this as a polyline and the maneuver derivation walk it as turns.
    let nodes: [Int]

    /// Total routing cost in seconds — walking time with the hill penalties
    /// folded in, not the honest walking time the route cards show. The two
    /// diverge sharply on hilly routes, which is the entire point of the
    /// penalties, so this number is for comparing routes found at the same
    /// settings and nothing else. Two runs at different settings produce costs
    /// on different scales and comparing them across runs is meaningless.
    let cost: Double
}

enum AStar {
    /// Cheapest route from `start` to `goal`, or `nil` if no path between them
    /// survives `cost`.
    ///
    /// Two ways that can come back empty, and they mean different things. The
    /// graph may genuinely not connect the two points; or `cost` may refuse
    /// enough edges — a grade ceiling does exactly that — to disconnect them for
    /// this walker while a route still exists for a less particular one. The
    /// caller decides which of those is worth reporting.
    static func route(
        from start: Int,
        to goal: Int,
        in graph: WalkingGraph,
        cost: WalkingCost
    ) -> Route? {
        precondition(
            (0 ..< graph.nodeCount).contains(start) && (0 ..< graph.nodeCount).contains(goal),
            "route endpoints must be nodes of the graph"
        )

        let estimate = RemainingTimeEstimate(goal: goal, in: graph)

        // Per-node state is three flat arrays indexed by node rather than
        // dictionaries keyed by node. Allocating the full width of the graph up
        // front costs less than the hashing a dictionary would do on the way in,
        // and the search reads these arrays once per edge it relaxes.
        var costToReach = [Double](repeating: .infinity, count: graph.nodeCount)
        var arrivedFrom = [Int32](repeating: noPredecessor, count: graph.nodeCount)
        var finalized = [Bool](repeating: false, count: graph.nodeCount)
        var frontier = SearchQueue()

        costToReach[start] = 0
        frontier.push(node: Int32(start), priority: estimate.seconds(from: start, in: graph))

        while let popped = frontier.pop() {
            let current = Int(popped)

            // The queue holds one entry per discovery, so a node that was found
            // by several routes appears several times. The first pop is the
            // cheapest of them; the rest are stale and skipped here.
            if finalized[current] { continue }

            // Popping the destination — not discovering it — is what ends the
            // search. Anything still queued costs at least as much as this
            // route, so nothing left to explore could beat it.
            if current == goal {
                return Route(
                    nodes: reconstructPath(to: goal, arrivedFrom: arrivedFrom),
                    cost: costToReach[goal]
                )
            }

            finalized[current] = true

            for edge in graph.outgoingEdges(of: current) {
                let neighbor = Int(graph.edgeTo[edge])
                if finalized[neighbor] { continue }

                // A refused edge is not expensive, it is absent. Skipping it
                // rather than pricing it high is what makes a grade ceiling
                // mean never — no detour long enough can outweigh it — and it
                // leaves the heuristic a lower bound on what remains, since
                // removing edges can only make a route dearer.
                guard let step = cost.seconds(of: edge, in: graph) else { continue }

                let throughCurrent = costToReach[current] + step

                // Strictly cheaper, not merely equal: on a street grid many
                // routes tie exactly, and rewriting the predecessor on a tie
                // would swap the answer for an equal one at random without
                // improving it.
                if throughCurrent < costToReach[neighbor] {
                    arrivedFrom[neighbor] = Int32(current)
                    costToReach[neighbor] = throughCurrent
                    frontier.push(
                        node: Int32(neighbor),
                        priority: throughCurrent + estimate.seconds(from: neighbor, in: graph)
                    )
                }
            }
        }

        return nil
    }

    /// Sentinel for a node nothing has reached yet. The start node keeps it for
    /// the whole search, which is what terminates the walk back.
    private static let noPredecessor: Int32 = -1

    private static func reconstructPath(to goal: Int, arrivedFrom: [Int32]) -> [Int] {
        var reversed = [goal]
        var node = goal
        while arrivedFrom[node] != noPredecessor {
            node = Int(arrivedFrom[node])
            reversed.append(node)
        }
        return reversed.reversed()
    }
}

/// Cheapest-first queue of discovered nodes, as a binary heap.
///
/// The search never lowers the priority of something already queued: when it
/// finds a cheaper way to a node it queues that node again and lets the older,
/// dearer entry fall out later. That is the reason this can stay a bare heap —
/// supporting decrease-key would mean tracking where every node currently sits
/// in the array and repairing those positions on each swap, which costs more
/// than the handful of duplicate entries it would save.
///
/// Ties in priority are broken by node index. Ties are the normal case on a
/// street grid rather than a rare accident, and without a rule for them the
/// route returned for a trip would shift between runs — the same search on the
/// same graph would draw a different line on the map each time.
private struct SearchQueue {
    private struct Entry {
        let priority: Double
        let node: Int32
    }

    private var entries: [Entry] = []

    mutating func push(node: Int32, priority: Double) {
        entries.append(Entry(priority: priority, node: node))
        siftUp(from: entries.count - 1)
    }

    mutating func pop() -> Int32? {
        guard let cheapest = entries.first else { return nil }

        let last = entries.removeLast()
        if !entries.isEmpty {
            entries[0] = last
            siftDown(from: 0)
        }
        return cheapest.node
    }

    private static func precedes(_ lhs: Entry, _ rhs: Entry) -> Bool {
        lhs.priority == rhs.priority ? lhs.node < rhs.node : lhs.priority < rhs.priority
    }

    private mutating func siftUp(from index: Int) {
        var child = index
        while child > 0 {
            let parent = (child - 1) / 2
            guard Self.precedes(entries[child], entries[parent]) else { return }
            entries.swapAt(child, parent)
            child = parent
        }
    }

    private mutating func siftDown(from index: Int) {
        var parent = index
        while true {
            let left = parent * 2 + 1
            let right = left + 1
            var cheapest = parent

            if left < entries.count, Self.precedes(entries[left], entries[cheapest]) {
                cheapest = left
            }
            if right < entries.count, Self.precedes(entries[right], entries[cheapest]) {
                cheapest = right
            }
            guard cheapest != parent else { return }

            entries.swapAt(parent, cheapest)
            parent = cheapest
        }
    }
}
