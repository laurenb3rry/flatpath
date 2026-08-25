"""Entry point for the graph build. Run this to produce FlatPathGraph.bin.

Runs the pipeline end to end: read the OSM extract, sample elevations, build
directed edges with baked costs, serialize, and copy the result into the app so
the next Xcode build picks it up. Intended to be run on a Mac once, and re-run
only when the underlying OSM or elevation data is refreshed.

The build prints its own vital signs -- node and edge counts, how many nodes
found no elevation data, the grade distribution, and the known-good reference
costs recomputed through the same path that baked the real ones. A graph can
serialize perfectly and still be wrong, and these are the numbers that show it.
"""

import shutil
import sys
import time

import config
import elevation
import graph
import osm_parse
import serialize


def _log(message):
    print(message, flush=True)


def _require_inputs():
    """Fail early and specifically if the inputs are not where they should be."""
    problems = []

    if not config.OSM_EXTRACT.exists():
        problems.append(f"OSM extract not found: {config.OSM_EXTRACT}")

    dem_paths = sorted(config.DATA_DIR.glob(config.DEM_TILE_GLOB))
    if not dem_paths:
        problems.append(
            f"no elevation rasters matching {config.DEM_TILE_GLOB} in {config.DATA_DIR}"
        )

    if problems:
        for problem in problems:
            print(f"error: {problem}", file=sys.stderr)
        print(
            "\nBoth inputs are large and gitignored; see the README for where to "
            "download them.",
            file=sys.stderr,
        )
        raise SystemExit(1)

    return dem_paths


def main():
    started = time.monotonic()
    dem_paths = _require_inputs()

    _log(f"reading {config.OSM_EXTRACT.name} over bbox {config.SF_BBOX}")
    lats, lons, ways = osm_parse.parse(config.OSM_EXTRACT, config.SF_BBOX)
    _log(f"  {len(lats):,} nodes, {len(ways):,} walkable way segments")

    lats, lons, ways, dropped, components = graph.largest_connected_component(lats, lons, ways)
    _log(
        f"  network splits into {components:,} components; kept the largest, "
        f"dropping {dropped:,} unroutable nodes"
    )
    _log(f"  {len(lats):,} nodes remain")

    _log(f"sampling elevation from {len(dem_paths)} raster(s)")
    elevations, missing = elevation.sample(lats, lons, dem_paths)
    _log(
        f"  {len(elevations) - missing:,} nodes sampled, "
        f"{missing:,} with no raster data ({missing / max(len(elevations), 1):.2%})"
    )
    if missing:
        elevations, filled, stranded = elevation.fill_gaps(elevations, ways)
        _log(f"  {filled:,} filled from neighbors, {stranded:,} left at sea level")
    _log(f"  elevation range {elevations.min():.1f}m to {elevations.max():.1f}m")

    _log("building directed edges")
    edges, names = graph.build(lats, lons, elevations, ways)
    stats = graph.summarize(edges)
    _log(f"  {stats['edge_count']:,} directed edges, {len(names):,} distinct street names")
    _log(f"  {stats['total_length_km']:,.0f} km of walkable network")
    _log(f"  median segment {stats['median_length_m']:.1f}m, steepest grade {stats['max_grade']:.1%}")
    _log(f"  {stats['steep_edge_share']:.1%} of edges steeper than 10%")

    _log("verifying baked costs against known-good values")
    for label, cost in graph.reference_costs():
        _log(f"  {label:>13}: {cost:8.1f}s")

    _log(f"writing {config.GRAPH_OUTPUT.name}")
    config.GRAPH_OUTPUT.parent.mkdir(parents=True, exist_ok=True)
    size = serialize.write(config.GRAPH_OUTPUT, lats, lons, elevations, edges, names)
    header = serialize.read_header(config.GRAPH_OUTPUT)
    _log(f"  {size / 1e6:.1f} MB, header reports {header['node_count']:,} nodes "
         f"and {header['edge_count']:,} edges")

    config.APP_RESOURCES_DIR.mkdir(parents=True, exist_ok=True)
    destination = config.APP_RESOURCES_DIR / config.GRAPH_FILENAME
    shutil.copy2(config.GRAPH_OUTPUT, destination)
    _log(f"  copied to {destination}")

    _log(f"done in {time.monotonic() - started:.1f}s")


if __name__ == "__main__":
    main()
