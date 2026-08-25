"""Reads an OSM extract and keeps only what a pedestrian can walk on.

Filters ways down to walkable highway types, then splits each one into segments
at every node shared with another way, so the result is a node-to-node graph
rather than a collection of long polylines. Street names are carried through
because turn-by-turn instructions need them later.

Not yet implemented.
"""
