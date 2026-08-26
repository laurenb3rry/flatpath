"""Reads an OSM extract and keeps only what a pedestrian can walk on.

Two passes over the file, in this order for a reason. Ways reference their nodes
by ID and carry no coordinates of their own, so there is no way to tell whether a
way falls inside the bounding box until its nodes are known. Reading nodes first
and discarding everything outside the box up front bounds memory to the study
area, instead of holding a coordinate index for the whole extract.

Ways that cross the boundary are not thrown away -- they are trimmed to the runs
of consecutive nodes that fall inside, so a street clipped at the county line
still contributes the part of itself that is in range.

Output is a node table and a list of ways referring to it by index. Ways keep
their full node sequence rather than just their endpoints: the intermediate
points are the shape of the street, and the map draws routes with them.
"""

import osmium

# Way types a pedestrian may use. Includes ordinary streets, since SF sidewalks
# are largely implicit -- mapped as part of the road rather than as separate
# footways -- so dropping roads would disconnect most of the city. Motorways and
# trunk roads are absent deliberately: they are the ones you genuinely cannot walk.
WALKABLE_HIGHWAYS = frozenset({
    "footway",
    "path",
    "pedestrian",
    "steps",
    "residential",
    "living_street",
    "service",
    "tertiary",
    "secondary",
    "primary",
    # Link roads carry the same walkability as the roads they join.
    "tertiary_link",
    "secondary_link",
    "primary_link",
    "unclassified",
    "track",
})

# Way types that carry a walker across traffic rather than alongside it. These
# are priced separately when edges are built, because what a crossing costs is
# mostly the wait to use it, which has nothing to do with its length.
CROSSING_FOOTWAYS = frozenset({"crossing"})

# Tag values that revoke walking access on a way that would otherwise qualify.
_FOOT_DENIED = frozenset({"no", "private"})
_ACCESS_DENIED = frozenset({"no", "private"})


def _is_walkable(tags):
    """Whether a pedestrian may use this way.

    A road tagged with a sidewalk counts even if its highway type is not on the
    list, since the sidewalk is the thing being walked on. An explicit foot tag
    settles the question either way: foot=yes overrides a general access
    restriction, which is how alleys and gated service roads with public
    footpaths are mapped.
    """
    foot = tags.get("foot")
    if foot in _FOOT_DENIED:
        return False

    highway = tags.get("highway")
    sidewalk = tags.get("sidewalk")
    qualifies = (
        highway in WALKABLE_HIGHWAYS
        or (sidewalk is not None and sidewalk not in ("no", "none", "separate"))
    )
    if not qualifies:
        return False

    if foot in ("yes", "designated", "permissive"):
        return True

    return tags.get("access") not in _ACCESS_DENIED


def _collect_nodes(pbf_path, bbox):
    """Coordinates of every node inside the bounding box, keyed by OSM node ID."""
    west, south, east, north = bbox
    nodes = {}

    for node in osmium.FileProcessor(pbf_path, osmium.osm.NODE):
        location = node.location
        if not location.valid():
            continue
        lon = location.lon
        lat = location.lat
        if west <= lon <= east and south <= lat <= north:
            nodes[node.id] = (lat, lon)

    return nodes


def _collect_ways(pbf_path, nodes):
    """Walkable ways, trimmed to the parts whose nodes are in `nodes`.

    Returns (osm_node_id_sequence, street_name, is_crossing) triples. A way that
    leaves the box and comes back contributes each inside run separately, because
    the router must not be able to travel along a stretch whose geometry is
    missing.
    """
    ways = []
    way_filter = osmium.filter.KeyFilter("highway", "sidewalk")

    for way in osmium.FileProcessor(pbf_path, osmium.osm.WAY).with_filter(way_filter):
        tags = way.tags
        if not _is_walkable(tags):
            continue

        name = tags.get("name")
        crossing = tags.get("footway") in CROSSING_FOOTWAYS

        run = []
        for node_ref in way.nodes:
            node_id = node_ref.ref
            if node_id in nodes:
                run.append(node_id)
            else:
                if len(run) >= 2:
                    ways.append((run, name, crossing))
                run = []
        if len(run) >= 2:
            ways.append((run, name, crossing))

    return ways


def parse(pbf_path, bbox):
    """Extract the walkable network inside `bbox` from an OSM extract.

    Returns (lats, lons, ways) where lats and lons are parallel lists indexed by
    dense node index, and each way is (node_index_sequence, street_name,
    is_crossing).

    Nodes that no surviving way touches are dropped and the rest are renumbered,
    so the returned indices are contiguous from zero. Everything downstream --
    the elevation sampler, the serializer, the app's arrays -- addresses nodes by
    that index, and it must have no gaps.
    """
    osm_nodes = _collect_nodes(str(pbf_path), bbox)
    osm_ways = _collect_ways(str(pbf_path), osm_nodes)

    index_of = {}
    lats = []
    lons = []
    ways = []

    for node_ids, name, crossing in osm_ways:
        indices = []
        for node_id in node_ids:
            index = index_of.get(node_id)
            if index is None:
                index = len(lats)
                index_of[node_id] = index
                lat, lon = osm_nodes[node_id]
                lats.append(lat)
                lons.append(lon)
            indices.append(index)
        ways.append((indices, name, crossing))

    return lats, lons, ways
