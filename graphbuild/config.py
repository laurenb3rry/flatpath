"""Tunable constants for the graph build: cost-function shape, the area to cover,
and where the input and output files live.

The graph ships the ingredients of a cost rather than a cost. Length, elevation
change and honest walking time are measured here, once; the router multiplies
them into a routing cost on the phone, every time it expands an edge. So the
constants below fall into two kinds, and only one kind lives in this file.

What is baked -- geometry, elevation, walking time -- depends on the constants
here, and changing any of them means rebuilding the graph and replacing the
binary the app carries. What is not baked -- how much a grade is minded, what a
meter of climb is worth, what a crossing costs -- is decided on the phone and
lives with the router, where it can be changed without a rebuild.

The misery constants sit here anyway, because the cost function they belong to is
stated in cost.py and pinned by its tests. The router carries the same numbers.
The two must be changed together.
"""

from pathlib import Path

# --- Cost function ---

# Grade above which climbing starts to feel like suffering rather than walking.
# Below it a hill costs only the extra time it takes; above it, misery compounds.
#
# San Francisco is full of 3-5% blocks. Set at 5% they were all free, and a route
# could climb a couple of hundred feet at a steady 4% without the router pricing
# any of it -- flat, by the cost function, and a real climb to the walker. 3% is
# the point below which a grade genuinely reads as level ground here.
UPHILL_MISERY_GRADE = 0.03

# Grade above which descending starts to punish the knees. Much higher than the
# uphill threshold: gentle descents are free, only genuinely steep ones hurt.
DOWNHILL_MISERY_GRADE = 0.20  # TUNE: validate against SF's steep descents

# How strongly to penalize excess downhill grade. Lower than any uphill value:
# steep descents are unpleasant, but never as costly as the equivalent climb.
DOWNHILL_SUFFERING = 0.15

# Fastest a walker can move on any edge, in m/s (Tobler's 6 km/h peak, hit at a
# slight downhill). The router's heuristic divides straight-line distance by this
# to get a lower bound on remaining time, so it must not be exceeded by any real
# edge speed or the search can return a suboptimal route.
MAX_SPEED_MS = 1.667


# Route cards report pure walking time, so nothing that steers a route -- not the
# hill penalty, not the wait at a crossing -- is allowed into the time this file
# bakes. Both are costs, not durations, and both are applied by the router.


# --- Coverage ---

# The area the graph covers, as (west, south, east, north) in degrees. Roughly
# the SF peninsula: Ocean Beach to the Bay, Daly City line to the Golden Gate.
# The app can only route between points inside this box, so destination search
# must be restricted to the same area.
SF_BBOX = (-122.5150, 37.7080, -122.3570, 37.8330)  # TUNE


# --- Geometry guards ---

# Edges shorter than this are treated as this long when computing slope. Two OSM
# nodes can sit centimeters apart; dividing a real elevation change by that
# distance yields a nonsense grade and an enormous cost. Length is only clamped
# for the slope calculation -- the true length is still what gets reported as
# distance.
MIN_SLOPE_LENGTH_M = 5.0

# Ceiling on absolute grade. The steepest street in SF is about 32%, so anything
# past this is elevation-data noise rather than terrain -- typically a node that
# landed on a building edge or a retaining wall in the raster. Left uncapped,
# a handful of these would become impassable walls the router steers around.
MAX_ABS_SLOPE = 0.50  # TUNE


# --- Files ---

DATA_DIR = Path(__file__).resolve().parent / "data"

# OSM extract to read. Any .osm.pbf covering the bbox works; the pipeline clips
# to SF itself, so a regional extract is fine and avoids a statewide download.
OSM_EXTRACT = DATA_DIR / "norcal-latest.osm.pbf"

# Elevation rasters. Every .tif in the data directory is treated as a DEM tile
# and consulted when sampling, so adding coverage means dropping in more files.
DEM_TILE_GLOB = "*.tif"

GRAPH_FILENAME = "FlatPathGraph.bin"
GRAPH_OUTPUT = DATA_DIR / GRAPH_FILENAME

# The app loads the graph from its bundle, so the build copies its output here.
APP_RESOURCES_DIR = Path(__file__).resolve().parent.parent / "FlatPath" / "Resources"
