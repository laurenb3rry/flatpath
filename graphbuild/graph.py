"""Turns parsed ways and node elevations into a directed graph of measured edges.

Every walkable segment becomes two edges, one per direction. This is not
optional: slope is signed, so uphill and downhill over the same ground cost
different amounts, and collapsing them into one symmetric edge would quietly
produce wrong routes -- the router would find a way up Filbert Street priced as
though it were the walk down.

Segments join adjacent nodes rather than junction to junction. The intermediate
points cost a little file size and buy two things the app needs: route polylines
that follow the actual bend of a street, and elevation change measured where it
happens instead of averaged across a whole block.

Each edge stores its length, its elevation change, its honest walking time, and
whether it is part of a street crossing. Those are measurements, and they are all
that is baked: the routing cost built out of them is computed on the phone, so
the dials that decide how much a hill is minded can be retuned without rebuilding
this file's output and reshipping it.

Edges come out sorted by origin node, with an index of where each node's edges
begin. That ordering is what lets the app walk a node's neighbors as a
contiguous slice instead of searching or hashing.
"""

import math

import numpy as np

from config import (
    MAX_ABS_SLOPE,
    MIN_SLOPE_LENGTH_M,
)
from cost import tobler_time_s

_EARTH_RADIUS_M = 6_371_008.8


def _haversine_m(lat1, lon1, lat2, lon2):
    """Great-circle distance in meters between two coordinate arrays."""
    phi1 = np.radians(lat1)
    phi2 = np.radians(lat2)
    dphi = phi2 - phi1
    dlambda = np.radians(lon2 - lon1)

    a = np.sin(dphi / 2.0) ** 2 + np.cos(phi1) * np.cos(phi2) * np.sin(dlambda / 2.0) ** 2
    return 2.0 * _EARTH_RADIUS_M * np.arcsin(np.sqrt(np.clip(a, 0.0, 1.0)))


def largest_connected_component(lats, lons, ways):
    """Keep only the part of the network everything else can reach on foot.

    An OSM extract of any city breaks into a large mesh plus a long tail of
    fragments: paths clipped by the bounding box, sidewalk runs whose crossings
    were never mapped, and places genuinely unreachable on foot such as an island
    served only by a freeway bridge. None of it can be routed to or from, since
    no path exists between it and anywhere else.

    Dropping it is what makes a destination there resolve to the nearest node a
    walker can actually get to, instead of a search that expands the whole
    fragment and reports no route.

    Returns (lats, lons, ways) renumbered densely, plus how many nodes were cut.
    """
    node_count = len(lats)
    neighbors = [[] for _ in range(node_count)]
    for indices, _name, _crossing in ways:
        for a, b in zip(indices, indices[1:]):
            if a == b:
                continue
            neighbors[a].append(b)
            neighbors[b].append(a)

    component = np.full(node_count, -1, dtype=np.int64)
    sizes = []
    for seed in range(node_count):
        if component[seed] != -1:
            continue
        label = len(sizes)
        size = 0
        stack = [seed]
        while stack:
            node = stack.pop()
            if component[node] != -1:
                continue
            component[node] = label
            size += 1
            stack.extend(n for n in neighbors[node] if component[n] == -1)
        sizes.append(size)

    keep_label = int(np.argmax(sizes))
    keep = component == keep_label

    renumbered = np.full(node_count, -1, dtype=np.int64)
    renumbered[keep] = np.arange(int(keep.sum()))

    kept_ways = []
    for indices, name, crossing in ways:
        if keep[indices[0]]:
            kept_ways.append(([int(renumbered[i]) for i in indices], name, crossing))

    kept_lats = [lat for lat, k in zip(lats, keep) if k]
    kept_lons = [lon for lon, k in zip(lons, keep) if k]

    return kept_lats, kept_lons, kept_ways, node_count - int(keep.sum()), len(sizes)


def _segment_pairs(ways):
    """Every adjacent node pair across all ways, with the street name carrying.

    Pairs are deduplicated: two ways sharing a stretch of geometry, or a way that
    doubles back on itself, would otherwise produce parallel edges that cost the
    router time to expand and can never be better than each other.

    Each segment also carries its share of a crossing, which the router later
    multiplies by what it thinks a crossing costs. A crossing way mapped as one
    segment carries all of it; one broken in two by a traffic island carries half
    in each piece, so a walker pays for crossing the street once however finely
    the crossing happens to be drawn. Everything that is not a crossing carries
    zero.

    A share rather than a flag, because the cost of waiting at a light is charged
    per crossing and not per segment, and only the build can tell how many
    segments one crossing was drawn as.
    """
    seen = set()
    from_nodes = []
    to_nodes = []
    names = []
    crossing_shares = []

    for indices, name, is_crossing in ways:
        segments = max(1, len(indices) - 1)
        share = 1.0 / segments if is_crossing else 0.0

        for a, b in zip(indices, indices[1:]):
            if a == b:
                continue
            key = (a, b) if a < b else (b, a)
            if key in seen:
                continue
            seen.add(key)
            from_nodes.append(a)
            to_nodes.append(b)
            names.append(name)
            crossing_shares.append(share)

    return from_nodes, to_nodes, names, crossing_shares


def build(lats, lons, elevations, ways):
    """Build the directed edge table.

    Returns a dict of parallel arrays: `from_node`, `to_node`, `length_m`,
    `delta_elev_m`, `time_s`, `crossing_share`, and `name_index` into the
    returned `names` list, plus `edge_start`, the offset where each node's
    outgoing edges begin.
    """
    lats = np.asarray(lats, dtype=np.float64)
    lons = np.asarray(lons, dtype=np.float64)
    elevations = np.asarray(elevations, dtype=np.float64)

    a_nodes, b_nodes, segment_names, crossing_shares = _segment_pairs(ways)
    a_nodes = np.asarray(a_nodes, dtype=np.int64)
    b_nodes = np.asarray(b_nodes, dtype=np.int64)
    crossing_shares = np.asarray(crossing_shares, dtype=np.float64)

    lengths = _haversine_m(lats[a_nodes], lons[a_nodes], lats[b_nodes], lons[b_nodes])

    # Coincident nodes carry no geometry and would divide by zero below.
    keeps = lengths > 0.0
    a_nodes = a_nodes[keeps]
    b_nodes = b_nodes[keeps]
    lengths = lengths[keeps]
    segment_names = [n for n, keep in zip(segment_names, keeps) if keep]
    crossing_shares = crossing_shares[keeps]

    rises = elevations[b_nodes] - elevations[a_nodes]

    # Both directions, in one pass: the forward half then the reverse half, with
    # the sign of the rise flipped. Everything else about the two is identical.
    from_node = np.concatenate([a_nodes, b_nodes])
    to_node = np.concatenate([b_nodes, a_nodes])
    length_m = np.concatenate([lengths, lengths])
    delta_elev_m = np.concatenate([rises, -rises])
    # A crossing costs the same whichever way it is walked.
    crossing_share = np.concatenate([crossing_shares, crossing_shares])

    # Slope gets a floor on length and a ceiling on magnitude; distance and
    # elevation change are reported unmodified. Guarding the ratio rather than
    # the inputs keeps the numbers on the route cards honest while stopping a
    # noisy centimeter-long segment from pricing itself like a cliff.
    slope_length = np.maximum(length_m, MIN_SLOPE_LENGTH_M)
    slope = np.clip(delta_elev_m / slope_length, -MAX_ABS_SLOPE, MAX_ABS_SLOPE)
    effective_rise = slope * slope_length

    time_s = np.array([
        tobler_time_s(float(l), float(d))
        for l, d in zip(slope_length, effective_rise)
    ])

    # Walking time must reflect the real distance even where slope was clamped,
    # otherwise a long flat edge and a short one would report the same duration.
    time_scale = length_m / slope_length
    time_s = time_s * time_scale

    name_index, names = _intern_names(segment_names * 2)

    order = np.argsort(from_node, kind="stable")

    edges = {
        "from_node": from_node[order].astype(np.uint32),
        "to_node": to_node[order].astype(np.uint32),
        "length_m": length_m[order].astype(np.float32),
        "delta_elev_m": delta_elev_m[order].astype(np.float32),
        "time_s": time_s[order].astype(np.float32),
        "crossing_share": crossing_share[order].astype(np.float32),
        "name_index": np.asarray(name_index, dtype=np.uint32)[order],
    }
    edges["edge_start"] = _edge_offsets(edges["from_node"], len(lats))

    return edges, names


def _intern_names(segment_names):
    """Map each edge to a shared name, so a street is stored once, not per edge.

    Street names repeat across thousands of edges. Storing the text inline would
    dominate the file and force the app to parse variable-length records; an
    index into a table keeps every edge the same size.
    """
    names = []
    index_of = {}
    indices = []

    for name in segment_names:
        text = name or ""
        position = index_of.get(text)
        if position is None:
            position = len(names)
            index_of[text] = position
            names.append(text)
        indices.append(position)

    return indices, names


def _edge_offsets(from_node, node_count):
    """Where each node's outgoing edges start, given edges sorted by origin.

    Length is node_count + 1, so a node's edges are the half-open range between
    consecutive entries and nodes with no edges need no special case.
    """
    counts = np.bincount(from_node.astype(np.int64), minlength=node_count)
    offsets = np.zeros(node_count + 1, dtype=np.uint32)
    offsets[1:] = np.cumsum(counts)
    return offsets


def reference_times():
    """Recompute known-good walking times using this module's baking path.

    A build can produce a well-formed file full of wrong numbers. Running the
    same clamps and the same call the pipeline uses against edges whose answers
    are known is the cheapest way to catch that before the graph ships.

    Walking time is the only figure derived from a curve rather than measured, so
    it is the only one that can be wrong in a way the file itself would not show.
    """
    checks = []
    for label, rise in (("flat", 0.0), ("normal climb", 6.0), ("steep climb", 18.0)):
        length = 100.0
        slope = max(-MAX_ABS_SLOPE, min(MAX_ABS_SLOPE, rise / max(length, MIN_SLOPE_LENGTH_M)))
        checks.append((label, tobler_time_s(length, slope * length)))
    return checks


def summarize(edges):
    """Descriptive stats for the build log."""
    grades = np.abs(edges["delta_elev_m"]) / np.maximum(edges["length_m"], 1e-6)
    return {
        "edge_count": int(edges["from_node"].size),
        "total_length_km": float(edges["length_m"].sum() / 2.0 / 1000.0),
        "median_length_m": float(np.median(edges["length_m"])),
        "steep_edge_share": float((grades > 0.10).mean()),
        "max_grade": float(grades.max()),
    }
