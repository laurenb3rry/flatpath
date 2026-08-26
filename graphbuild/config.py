"""Tunable constants for the graph build: cost-function parameters, the area to
cover, and where the input and output files live.

The cost constants below are tuned. Changing them changes every baked edge cost,
so the graph must be rebuilt and the app's bundled binary replaced.
"""

from pathlib import Path

# --- Cost function ---

# Grade above which climbing starts to feel like suffering rather than walking.
# Below 5%, a hill costs only the extra time it takes; above it, misery compounds.
UPHILL_MISERY_GRADE = 0.05

# Grade above which descending starts to punish the knees. Much higher than the
# uphill threshold: gentle descents are free, only genuinely steep ones hurt.
DOWNHILL_MISERY_GRADE = 0.20  # TUNE: validate against SF's steep descents

# How strongly to penalize excess uphill grade. One cost is baked per value, in
# this order, giving three routes of increasing hill-aversion: the app runs the
# router once per index and offers the distinct survivors as route options.
#
# Never add 0.0 to this list. At zero the router degenerates into a pure
# shortest-time search -- the same route Google Maps gives, straight over the
# hill -- which is the thing this app exists to avoid. 0.15 is the floor.
UPHILL_SUFFERING = [0.15, 0.5, 1.5]

# How strongly to penalize excess downhill grade. Lower than any uphill value:
# steep descents are unpleasant, but never as costly as the equivalent climb.
DOWNHILL_SUFFERING = 0.15

# Fastest a walker can move on any edge, in m/s (Tobler's 6 km/h peak, hit at a
# slight downhill). The router's heuristic divides straight-line distance by this
# to get a lower bound on remaining time, so it must not be exceeded by any real
# edge speed or the search can return a suboptimal route.
MAX_SPEED_MS = 1.667


# Seconds added to the routing cost of crossing a street.
#
# Both sides of most SF streets are mapped as their own sidewalks, joined by
# marked crossings. Priced at nothing, a crossing is free, so the router will
# hop the street to save a couple of meters and hop back at the next corner --
# technically optimal, and useless to a walker who has to wait at two lights to
# collect the saving. This is what a crossing actually costs: the wait at the
# signal and the interruption, rather than the seconds spent walking it.
#
# Sized between the two mistakes. Well above the few seconds a pointless
# side-swap saves, so those stop happening; well below the ~70 seconds it takes
# to walk a block, so the router still crosses when crossing is genuinely the
# way there instead of walking around the long side of a block to avoid it.
#
# Charged once per crossing rather than once per segment: a crossing broken in
# two by a traffic island is still one crossing, and would otherwise cost double
# for being mapped in more detail.
CROSSING_PENALTY_S = 25.0  # TUNE: walk a few real crossings and see

# Route cards keep reporting pure walking time. This is a cost, not a duration --
# the same treatment the hill penalty gets, and for the same reason: it steers
# the route without misreporting how long the walk takes.


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
