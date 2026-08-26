"""Writes the finished graph to FlatPathGraph.bin.

Flat arrays of nodes and directed edges, little-endian, with node IDs remapped to
dense 0..n-1 indices. Dense indices are the point: the app can load the file
straight into contiguous arrays and address nodes by offset, with no hash map in
the routing hot path.

The layout below is the contract with the app's loader. Changing one side without
the other produces garbage or a crash at load, which is what the magic number and
version guard against -- an app running against a stale format should refuse to
start rather than route on nonsense.

    header
        magic        4 bytes, "FPG1"
        version      uint32
        node_count   uint32
        edge_count   uint32
        name_count   uint32

    nodes            node_count records, index order
        lat          float64
        lon          float64
        elevation    float32   meters

    edge_start       node_count + 1 x uint32
        Offset into the edge table where each node's outgoing edges begin. The
        edges of node i are the half-open range [edge_start[i], edge_start[i+1]).

    edges            edge_count records, sorted by origin node
        from_node     uint32
        to_node       uint32
        length_m      float32
        delta_elev_m  float32   signed, positive uphill
        time_s        float32   honest walking time, no hill penalty
        crossing_share float32  this segment's share of one street crossing
        name_index    uint32    into the name table

    names            name_count records
        length       uint16    bytes, not characters
        text         UTF-8

Every record is fixed size, so the reader can compute any offset arithmetically
instead of parsing forward. The one variable-length section, the name table, sits
last for that reason.

Two design choices differ from the obvious approach and are deliberate. Street
names are interned into a table and referenced by index rather than written
inline, because inline names repeat across thousands of edges and would both
dominate the file size and make edge records variable-width. And what an edge
carries are the ingredients of a routing cost rather than a cost: length, rise,
walking time, and whether it crosses a street. The app multiplies those into a
cost as it expands each edge, which costs a few arithmetic operations per edge
and buys the ability to retune how hills are priced without rebuilding and
reshipping this file.
"""

import struct

import numpy as np

MAGIC = b"FPG1"

# Bumped when the layout below changes. Version 1 carried a routing cost per
# hill-aversion setting on every edge; version 2 carries the measurements those
# costs were computed from instead, and leaves the computing to the app.
FORMAT_VERSION = 2

_HEADER = struct.Struct("<4sIIII")
_NAME_LENGTH = struct.Struct("<H")

# Records are written through packed numpy dtypes rather than a per-record pack
# call. At several hundred thousand edges the difference is a slow build versus
# an instant one. `align=False` is what keeps the layout packed: any padding
# numpy inserted for alignment would silently desynchronize the app's reader.
_NODE_DTYPE = np.dtype([("lat", "<f8"), ("lon", "<f8"), ("elevation", "<f4")], align=False)


_EDGE_DTYPE = np.dtype([
    ("from_node", "<u4"),
    ("to_node", "<u4"),
    ("length_m", "<f4"),
    ("delta_elev_m", "<f4"),
    ("time_s", "<f4"),
    ("crossing_share", "<f4"),
    ("name_index", "<u4"),
], align=False)

_EDGE_FIELDS = _EDGE_DTYPE.names


def write(path, lats, lons, elevations, edges, names):
    """Serialize the graph to `path`.

    Returns the number of bytes written.
    """
    node_count = len(lats)
    edge_count = int(edges["from_node"].size)

    edge_start = edges["edge_start"]
    if len(edge_start) != node_count + 1:
        raise ValueError(
            f"edge_start has {len(edge_start)} entries, expected {node_count + 1}"
        )

    node_records = np.empty(node_count, dtype=_NODE_DTYPE)
    node_records["lat"] = lats
    node_records["lon"] = lons
    node_records["elevation"] = elevations

    edge_records = np.empty(edge_count, dtype=_EDGE_DTYPE)
    for field in _EDGE_FIELDS:
        edge_records[field] = edges[field]

    with open(path, "wb") as out:
        out.write(_HEADER.pack(MAGIC, FORMAT_VERSION, node_count, edge_count, len(names)))
        out.write(node_records.tobytes())
        out.write(edge_start.astype("<u4").tobytes())
        out.write(edge_records.tobytes())

        for name in names:
            encoded = name.encode("utf-8")
            # A street name longer than this is a data error, not a name. Cutting
            # on a byte boundary would split a multi-byte character, so back off
            # to one that decodes cleanly.
            if len(encoded) > 0xFFFF:
                encoded = encoded[:0xFFFF]
                while encoded and (encoded[-1] & 0xC0) == 0x80:
                    encoded = encoded[:-1]
            out.write(_NAME_LENGTH.pack(len(encoded)))
            out.write(encoded)

    return path.stat().st_size


def read_header(path):
    """Parse just the header, for verifying a written file."""
    with open(path, "rb") as source:
        magic, version, node_count, edge_count, name_count = _HEADER.unpack(
            source.read(_HEADER.size)
        )
    if magic != MAGIC:
        raise ValueError(f"not a FlatPath graph: magic was {magic!r}")
    return {
        "version": version,
        "node_count": node_count,
        "edge_count": edge_count,
        "name_count": name_count,
    }
