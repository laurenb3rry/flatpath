"""Entry point for the graph build. Run this to produce FlatPathGraph.bin.

Runs the pipeline end to end: parse the OSM extract, sample elevations, build
directed edges with baked costs, serialize. Intended to be run on a Mac once,
and re-run only when the underlying OSM or elevation data is refreshed.

Not yet implemented.
"""
