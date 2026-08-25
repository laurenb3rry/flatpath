"""Turns parsed ways and node elevations into a directed graph with baked costs.

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
one cost per hill-aversion setting. Baking every cost here means the app picks a
route flavor by array index and never evaluates the cost function at all.

Edges come out sorted by origin node, with an index of where each node's edges
begin. That ordering is what lets the app walk a node's neighbors as a
contiguous slice instead of searching or hashing.
"""

import math

import numpy as np

from config import MAX_ABS_SLOPE, MIN_SLOPE_LENGTH_M, UPHILL_SUFFERING
from cost import edge_cost, tobler_time_s

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
    for indices, _name in ways:
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
    for indices, name in ways:
        if keep[indices[0]]:
            kept_ways.append(([int(renumbered[i]) for i in indices], name))

    kept_lats = [lat for lat, k in zip(lats, keep) if k]
    kept_lons = [lon for lon, k in zip(lons, keep) if k]

    return kept_lats, kept_lons, kept_ways, node_count - int(keep.sum()), len(sizes)


def _segment_pairs(ways):
    """Every adjacent node pair across all ways, with the street name carrying.

    Pairs are deduplicated: two ways sharing a stretch of geometry, or a way that
    doubles back on itself, would otherwise produce parallel edges that cost the
    router time to expand and can never be better than each other.
    """
    seen = set()
    from_nodes = []
    to_nodes = []
    names = []

    for indices, name in ways:
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

    return from_nodes, to_nodes, names


def build(lats, lons, elevations, ways):
    """Build the directed edge table.

    Returns a dict of parallel arrays: `from_node`, `to_node`, `length_m`,
    `delta_elev_m`, `time_s`, `costs` (one row per hill-aversion setting), and
    `name_index` into the returned `names` list, plus `edge_start`, the offset
    where each node's outgoing edges begin.
    """
    lats = np.asarray(lats, dtype=np.float64)
    lons = np.asarray(lons, dtype=np.float64)
    elevations = np.asarray(elevations, dtype=np.float64)

    a_nodes, b_nodes, segment_names = _segment_pairs(ways)
    a_nodes = np.asarray(a_nodes, dtype=np.int64)
    b_nodes = np.asarray(b_nodes, dtype=np.int64)

    lengths = _haversine_m(lats[a_nodes], lons[a_nodes], lats[b_nodes], lons[b_nodes])

    # Coincident nodes carry no geometry and would divide by zero below.
    keeps = lengths > 0.0
    a_nodes = a_nodes[keeps]
    b_nodes = b_nodes[keeps]
    lengths = lengths[keeps]
    segment_names = [n for n, keep in zip(segment_names, keeps) if keep]

    rises = elevations[b_nodes] - elevations[a_nodes]

    # Both directions, in one pass: the forward half then the reverse half, with
    # the sign of the rise flipped. Everything else about the two is identical.
    from_node = np.concatenate([a_nodes, b_nodes])
    to_node = np.concatenate([b_nodes, a_nodes])
    length_m = np.concatenate([lengths, lengths])
    delta_elev_m = np.concatenate([rises, -rises])

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

    costs = np.array([
        [
            edge_cost(float(l), float(d), suffering)
            for l, d in zip(slope_length, effective_rise)
        ]
        for suffering in UPHILL_SUFFERING
    ])

    # Walking time must reflect the real distance even where slope was clamped,
    # otherwise a long flat edge and a short one would report the same duration.
    time_scale = length_m / slope_length
    time_s = time_s * time_scale
    costs = costs * time_scale

    name_index, names = _intern_names(segment_names * 2)

    order = np.argsort(from_node, kind="stable")

    edges = {
        "from_node": from_node[order].astype(np.uint32),
        "to_node": to_node[order].astype(np.uint32),
        "length_m": length_m[order].astype(np.float32),
        "delta_elev_m": delta_elev_m[order].astype(np.float32),
        "time_s": time_s[order].astype(np.float32),
        "costs": costs[:, order].astype(np.float32),
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


def reference_costs():
    """Recompute the known-good edge costs using this module's baking path.

    A build can produce a well-formed file full of wrong numbers. Running the
    same clamps and cost calls the pipeline uses against edges whose answers are
    known is the cheapest way to catch that before the graph ships.
    """
    suffering = 0.5
    checks = []
    for label, rise in (("flat", 0.0), ("normal climb", 6.0), ("steep climb", 18.0)):
        length = 100.0
        slope = max(-MAX_ABS_SLOPE, min(MAX_ABS_SLOPE, rise / max(length, MIN_SLOPE_LENGTH_M)))
        checks.append((label, edge_cost(length, slope * length, suffering)))
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
