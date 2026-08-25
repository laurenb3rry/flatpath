//  GraphModel.swift
//
//  Node and edge value types, plus the adjacency structure the router walks.
//
//  Nodes are addressed by dense integer index rather than by identity, and
//  adjacency is stored as flat arrays. This is deliberate: it lets the router
//  keep its per-node state in contiguous memory instead of dictionaries, which
//  is where nearly all of the routing speed comes from.
//
//  Not yet implemented.
