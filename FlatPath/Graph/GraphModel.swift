//  GraphModel.swift
//
//  Node and edge value types, plus the adjacency structure the router walks.
//
//  Nodes are addressed by dense integer index rather than by identity, and
//  adjacency is stored as flat arrays. This is deliberate: it lets the router
//  keep its per-node state in contiguous memory instead of dictionaries, which
//  is where nearly all of the routing speed comes from.

import Foundation

/// A node's position and height, assembled on demand from the flat arrays.
///
/// Nothing in the routing hot path uses this — A* works on indices and the raw
/// arrays. It exists for the code that has to hand a real coordinate to MapKit
/// or show a number on screen.
struct GraphNode {
    let index: Int
    let latitude: Double
    let longitude: Double
    /// Meters above sea level.
    let elevation: Double
}

/// One directed edge, assembled on demand. Same rationale as `GraphNode`.
struct GraphEdge {
    let index: Int
    let from: Int
    let to: Int
    /// Meters.
    let length: Double
    /// Signed meters of climb, positive uphill. Summing the positive part over
    /// a path gives the elevation gain the route cards lead with.
    let deltaElevation: Double
    /// Seconds of honest walking time, with no hill penalty applied. This is
    /// what the cards report; the routing costs are a different number.
    let time: Double
    /// Street name, or the empty string for unnamed ways.
    let name: String
}

/// The whole walking network, as parallel arrays indexed by node or edge.
///
/// Every per-node and per-edge attribute lives in its own contiguous array
/// rather than in an array of structs. A* touches `edgeStart`, `edgeTo` and one
/// cost array and nothing else, so keeping those three dense means a traversal
/// pulls in only the bytes it actually reads.
///
/// Adjacency is a compressed-row layout: edges are sorted by origin node, and
/// `edgeStart` records where each node's run begins. The outgoing edges of node
/// `i` are the half-open range `edgeStart[i] ..< edgeStart[i + 1]`, which is why
/// `edgeStart` carries one extra trailing entry.
struct WalkingGraph {
    // MARK: Nodes

    let latitudes: [Double]
    let longitudes: [Double]
    /// Meters above sea level, sampled offline from the elevation raster.
    let elevations: [Float]

    // MARK: Adjacency

    /// `nodeCount + 1` offsets into the edge arrays.
    let edgeStart: [UInt32]

    // MARK: Edges, sorted by origin node

    let edgeTo: [UInt32]
    /// Meters.
    let edgeLength: [Float]
    /// Signed meters, positive uphill.
    let edgeDeltaElevation: [Float]
    /// Seconds, hill penalty excluded.
    let edgeTime: [Float]
    /// One array per hill-aversion setting, in increasing order of aversion.
    /// Routing picks an array up front and reads only that one for the whole run.
    let edgeCosts: [[Float]]
    let edgeNameIndex: [UInt32]

    /// Street names, interned. Thousands of edges share a handful of names, so
    /// they are stored once and referenced by index.
    let streetNames: [String]

    var nodeCount: Int { latitudes.count }
    var edgeCount: Int { edgeTo.count }
    /// How many hill-aversion settings the graph was baked with. Routing sweeps
    /// all of them to produce its route options.
    var costSettingCount: Int { edgeCosts.count }

    /// Indices of the edges leaving `node`.
    @inline(__always)
    func outgoingEdges(of node: Int) -> Range<Int> {
        Int(edgeStart[node]) ..< Int(edgeStart[node + 1])
    }

    /// Routing cost in seconds for `edge` at hill-aversion `setting`.
    @inline(__always)
    func cost(of edge: Int, setting: Int) -> Float {
        edgeCosts[setting][edge]
    }

    func node(at index: Int) -> GraphNode {
        GraphNode(
            index: index,
            latitude: latitudes[index],
            longitude: longitudes[index],
            elevation: Double(elevations[index])
        )
    }

    func edge(at index: Int, from origin: Int) -> GraphEdge {
        GraphEdge(
            index: index,
            from: origin,
            to: Int(edgeTo[index]),
            length: Double(edgeLength[index]),
            deltaElevation: Double(edgeDeltaElevation[index]),
            time: Double(edgeTime[index]),
            name: name(of: index)
        )
    }

    func name(of edge: Int) -> String {
        streetNames[Int(edgeNameIndex[edge])]
    }
}

// MARK: - Lookups

// Two questions the graph gets asked from outside the search: which node a point
// on the map corresponds to, and which edge joins two nodes of a finished path.
// Both are graph queries rather than routing ones, and both are asked a handful
// of times per trip rather than per expansion, so neither carries an index.
extension WalkingGraph {
    /// Degrees of latitude to meters. Constant everywhere; the same figure for
    /// longitude has to be shrunk by the latitude it is measured at.
    private static let metersPerDegree: Double = 111_320

    /// How far from a point the network may be before the point is treated as
    /// unroutable. Roughly two city blocks — far enough to forgive a GPS fix
    /// drifting off the street it was taken on, close enough that a press in the
    /// middle of the bay or inside a park with no paths is refused rather than
    /// silently snapped to a shoreline street a quarter mile away.
    static let snappingLimit: Double = 250

    /// The node nearest a coordinate, or `nil` when the network does not reach
    /// within `limit` meters of it.
    ///
    /// A flat scan of every node. That sounds wasteful against a spatial index,
    /// but it is a few hundred thousand multiply-adds over arrays already in
    /// cache — under the noise of the search that follows it — and it means no
    /// second structure to build at launch and keep consistent with the graph.
    ///
    /// Distances come from an equirectangular approximation rather than the
    /// haversine the router uses. Over the few hundred meters that can win, the
    /// two disagree by centimeters, and the winner is all that is asked for.
    func nearestNode(
        toLatitude latitude: Double,
        longitude: Double,
        within limit: Double = snappingLimit
    ) -> Int? {
        let metersPerDegreeLatitude = Self.metersPerDegree
        let metersPerDegreeLongitude = Self.metersPerDegree * cos(latitude * .pi / 180)

        // Seeding the best distance with the limit is what enforces the limit:
        // a node further away than this can never displace it.
        var nearest = -1
        var nearestDistanceSquared = limit * limit

        for node in 0 ..< nodeCount {
            let northing = (latitudes[node] - latitude) * metersPerDegreeLatitude
            let easting = (longitudes[node] - longitude) * metersPerDegreeLongitude
            let distanceSquared = northing * northing + easting * easting

            if distanceSquared < nearestDistanceSquared {
                nearestDistanceSquared = distanceSquared
                nearest = node
            }
        }

        return nearest < 0 ? nil : nearest
    }

    /// The edge running from one node to another, or `nil` if they are not
    /// neighbours. The build emits at most one edge per ordered pair, so the
    /// first match is the only one.
    func edge(from origin: Int, to destination: Int) -> Int? {
        outgoingEdges(of: origin).first { edgeTo[$0] == UInt32(destination) }
    }

    /// The edges joining each consecutive pair of nodes along a path.
    ///
    /// Every route the search returns is a chain of neighbours, so this recovers
    /// the edges it walked without the search having to carry them. Per-edge
    /// figures — the walking time and elevation change the cards are built from —
    /// hang off the edges rather than the nodes, so a path of node indices alone
    /// cannot be measured.
    func edges(along path: [Int]) -> [Int] {
        zip(path, path.dropFirst()).compactMap { edge(from: $0, to: $1) }
    }
}
