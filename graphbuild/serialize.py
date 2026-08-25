"""Writes the finished graph to FlatPathGraph.bin.

Flat arrays of nodes and directed edges, little-endian, with node IDs remapped to
dense 0..n-1 indices. Dense indices are the point: the app can load the file
straight into contiguous arrays and address nodes by offset, with no hash map in
the routing hot path.

The layout written here is the contract with GraphLoader.swift on the app side.
Changing one without the other produces garbage or a crash at load, so the format
is documented in full alongside the writer.

Not yet implemented.
"""
