//  GraphLoader.swift
//
//  Reads the bundled FlatPathGraph.bin into flat arrays of nodes and directed
//  edges. The binary layout it parses is written by the Python pipeline's
//  serializer; the two must be changed together or loading yields garbage.
//
//  The file is a header followed by four fixed-stride sections and one
//  variable-length one:
//
//      header       magic "FPG1" | version | nodeCount | edgeCount | nameCount
//      nodes        nodeCount x { lat: f64, lon: f64, elevation: f32 }
//      edgeStart    (nodeCount + 1) x u32, where each node's outgoing edges begin
//      edges        edgeCount x { from: u32, to: u32, length: f32,
//                                 deltaElevation: f32, time: f32,
//                                 crossingShare: f32, nameIndex: u32 }
//      names        nameCount x { byteLength: u16, utf8 }
//
//  Everything is little-endian and packed with no padding, so the sections are
//  found by arithmetic rather than by parsing forward. That is also why the one
//  variable-length section sits last.
//
//  Two properties of the format matter to the reader. Records are packed, so
//  most multi-byte fields land on offsets that are not naturally aligned — every
//  read here is an explicit unaligned load, and switching to a plain `load` would
//  trap. And node IDs are already dense 0..<nodeCount indices, so the arrays go
//  straight into memory with no remapping and no hash map anywhere.

import Foundation

enum GraphLoaderError: Error, CustomStringConvertible {
    case resourceMissing(String)
    case notAGraphFile(magic: String)
    case unsupportedVersion(UInt32)
    case truncated(expectedAtLeast: Int, actual: Int)
    case inconsistentAdjacency(String)

    var description: String {
        switch self {
        case .resourceMissing(let name):
            return "\(name) is not in the app bundle"
        case .notAGraphFile(let magic):
            return "not a FlatPath graph: magic was \(magic)"
        case .unsupportedVersion(let version):
            return "graph format version \(version) is not the \(GraphLoader.supportedVersion) this build reads"
        case .truncated(let expected, let actual):
            return "graph file is truncated: expected at least \(expected) bytes, got \(actual)"
        case .inconsistentAdjacency(let detail):
            return "graph adjacency is inconsistent: \(detail)"
        }
    }
}

enum GraphLoader {
    static let resourceName = "FlatPathGraph"
    static let resourceExtension = "bin"

    /// The format this build reads. Exact rather than at-most: an older file
    /// carried a routing cost per hill-aversion setting where this one carries
    /// the measurements a cost is computed from, and the two are different
    /// enough that reading one as the other yields plausible garbage. Every
    /// section offset comes from the header, so a layout change would not fail
    /// loudly on its own — the version check is the only thing that catches it.
    static let supportedVersion: UInt32 = 2

    private static let magic: [UInt8] = Array("FPG1".utf8)
    private static let headerSize = 20
    private static let nodeStride = 20
    private static let edgeStride = 28

    /// Load the graph bundled with the app.
    static func loadBundledGraph(from bundle: Bundle = .main) throws -> WalkingGraph {
        guard let url = bundle.url(forResource: resourceName, withExtension: resourceExtension) else {
            throw GraphLoaderError.resourceMissing("\(resourceName).\(resourceExtension)")
        }
        return try load(contentsOf: url)
    }

    static func load(contentsOf url: URL) throws -> WalkingGraph {
        // Mapped rather than read: the file is tens of megabytes and every byte
        // of it is copied into the arrays below anyway, so there is no reason to
        // hold a second full copy in memory while that happens.
        let data = try Data(contentsOf: url, options: .mappedIfSafe)
        return try load(from: data)
    }

    static func load(from data: Data) throws -> WalkingGraph {
        try data.withUnsafeBytes { bytes in
            try parse(bytes)
        }
    }

    private static func parse(_ bytes: UnsafeRawBufferPointer) throws -> WalkingGraph {
        guard bytes.count >= headerSize else {
            throw GraphLoaderError.truncated(expectedAtLeast: headerSize, actual: bytes.count)
        }

        guard Array(bytes[0..<4]) == magic else {
            let found = String(decoding: bytes[0..<4], as: UTF8.self)
            throw GraphLoaderError.notAGraphFile(magic: found)
        }

        let version = bytes.u32(at: 4)
        guard version == supportedVersion else {
            throw GraphLoaderError.unsupportedVersion(version)
        }

        let nodeCount = Int(bytes.u32(at: 8))
        let edgeCount = Int(bytes.u32(at: 12))
        let nameCount = Int(bytes.u32(at: 16))

        // Everything but the name table is fixed-stride, so its total size is
        // known before a single record is read. Checking it once here is what
        // lets the per-record reads below skip bounds checks entirely.
        let nodesOffset = headerSize
        let edgeStartOffset = nodesOffset + nodeCount * nodeStride
        let edgesOffset = edgeStartOffset + (nodeCount + 1) * 4
        let namesOffset = edgesOffset + edgeCount * edgeStride
        guard bytes.count >= namesOffset else {
            throw GraphLoaderError.truncated(expectedAtLeast: namesOffset, actual: bytes.count)
        }

        var latitudes = [Double](repeating: 0, count: nodeCount)
        var longitudes = [Double](repeating: 0, count: nodeCount)
        var elevations = [Float](repeating: 0, count: nodeCount)
        for node in 0 ..< nodeCount {
            let base = nodesOffset + node * nodeStride
            latitudes[node] = bytes.f64(at: base)
            longitudes[node] = bytes.f64(at: base + 8)
            elevations[node] = bytes.f32(at: base + 16)
        }

        var edgeStart = [UInt32](repeating: 0, count: nodeCount + 1)
        for node in 0 ... nodeCount {
            edgeStart[node] = bytes.u32(at: edgeStartOffset + node * 4)
        }
        try validate(edgeStart: edgeStart, edgeCount: edgeCount)

        var edgeTo = [UInt32](repeating: 0, count: edgeCount)
        var edgeLength = [Float](repeating: 0, count: edgeCount)
        var edgeDeltaElevation = [Float](repeating: 0, count: edgeCount)
        var edgeTime = [Float](repeating: 0, count: edgeCount)
        var edgeCrossingShare = [Float](repeating: 0, count: edgeCount)
        var edgeNameIndex = [UInt32](repeating: 0, count: edgeCount)
        for edge in 0 ..< edgeCount {
            // The origin node opens each record but is not kept: the compressed-row
            // `edgeStart` already says which node an edge leaves, and half a
            // million redundant u32s is memory the router would never read.
            let base = edgesOffset + edge * edgeStride
            edgeTo[edge] = bytes.u32(at: base + 4)
            edgeLength[edge] = bytes.f32(at: base + 8)
            edgeDeltaElevation[edge] = bytes.f32(at: base + 12)
            edgeTime[edge] = bytes.f32(at: base + 16)
            edgeCrossingShare[edge] = bytes.f32(at: base + 20)
            edgeNameIndex[edge] = bytes.u32(at: base + 24)
        }

        let streetNames = try readNames(bytes, at: namesOffset, count: nameCount)

        return WalkingGraph(
            latitudes: latitudes,
            longitudes: longitudes,
            elevations: elevations,
            edgeStart: edgeStart,
            edgeTo: edgeTo,
            edgeLength: edgeLength,
            edgeDeltaElevation: edgeDeltaElevation,
            edgeTime: edgeTime,
            edgeCrossingShare: edgeCrossingShare,
            edgeNameIndex: edgeNameIndex,
            streetNames: streetNames
        )
    }

    /// The adjacency ranges have to be non-decreasing and end exactly at the
    /// edge count. If they are not, `outgoingEdges(of:)` would hand the router
    /// an out-of-bounds or backwards range on some node it may not reach for
    /// thousands of trips — far better to refuse the file at launch.
    private static func validate(edgeStart: [UInt32], edgeCount: Int) throws {
        guard edgeStart.first == 0 else {
            throw GraphLoaderError.inconsistentAdjacency(
                "first offset is \(edgeStart.first ?? 0), expected 0"
            )
        }
        guard edgeStart.last == UInt32(edgeCount) else {
            throw GraphLoaderError.inconsistentAdjacency(
                "last offset is \(edgeStart.last ?? 0), expected \(edgeCount)"
            )
        }
        for node in 1 ..< edgeStart.count where edgeStart[node] < edgeStart[node - 1] {
            throw GraphLoaderError.inconsistentAdjacency("offsets decrease at node \(node)")
        }
    }

    private static func readNames(
        _ bytes: UnsafeRawBufferPointer,
        at offset: Int,
        count: Int
    ) throws -> [String] {
        var names = [String]()
        names.reserveCapacity(count)

        var cursor = offset
        for _ in 0 ..< count {
            guard cursor + 2 <= bytes.count else {
                throw GraphLoaderError.truncated(expectedAtLeast: cursor + 2, actual: bytes.count)
            }
            let length = Int(bytes.u16(at: cursor))
            cursor += 2

            guard cursor + length <= bytes.count else {
                throw GraphLoaderError.truncated(
                    expectedAtLeast: cursor + length, actual: bytes.count
                )
            }
            names.append(String(decoding: bytes[cursor ..< cursor + length], as: UTF8.self))
            cursor += length
        }

        return names
    }
}

// Little-endian unaligned reads. The file's records are packed, so a field can
// start at any byte offset; `loadUnaligned` is the only safe way to read them.
// Converting through the integer bit pattern rather than loading a `Float`
// directly is what makes the byte order explicit instead of assumed.
private extension UnsafeRawBufferPointer {
    @inline(__always)
    func u16(at offset: Int) -> UInt16 {
        UInt16(littleEndian: loadUnaligned(fromByteOffset: offset, as: UInt16.self))
    }

    @inline(__always)
    func u32(at offset: Int) -> UInt32 {
        UInt32(littleEndian: loadUnaligned(fromByteOffset: offset, as: UInt32.self))
    }

    @inline(__always)
    func f32(at offset: Int) -> Float {
        Float(bitPattern: u32(at: offset))
    }

    @inline(__always)
    func f64(at offset: Int) -> Double {
        Double(bitPattern: UInt64(littleEndian: loadUnaligned(fromByteOffset: offset, as: UInt64.self)))
    }
}
