//  AStar.swift
//
//  Shortest-path search over the directed walking graph, minimizing baked edge
//  cost in seconds. Each run picks one hill-aversion setting by index; running
//  it several times at different settings is what produces the route options.
//
//  A node is final only when it is popped from the queue, not when it is first
//  discovered, and the search stops when the destination itself is popped. A
//  cheaper path to an already-discovered node can still turn up before that.
//
//  Not yet implemented.
