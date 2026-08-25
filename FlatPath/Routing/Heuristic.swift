//  Heuristic.swift
//
//  Lower bound on the walking time remaining from a node to the destination:
//  straight-line distance divided by the fastest speed any edge can be walked.
//
//  Both the running total and this estimate are in seconds, and the estimate
//  must never exceed the true remaining time. Dividing by peak walking speed
//  guarantees that, which is what keeps the returned route optimal.
//
//  Not yet implemented.
