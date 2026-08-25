//  RouteMetrics.swift
//
//  The three numbers on a route card: time, elevation gain, and distance.
//
//  Time is honest walking time accumulated along the path, not the router's
//  internal cost -- the router inflates steep edges to steer away from them, and
//  showing that inflated figure would misreport how long the walk actually takes.
//  Elevation gain counts only the climbs, since descents do not undo them.
//
//  Not yet implemented.
