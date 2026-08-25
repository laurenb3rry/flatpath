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
