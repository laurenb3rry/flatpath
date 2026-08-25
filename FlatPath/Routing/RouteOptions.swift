//  RouteOptions.swift
//
//  Produces the handful of routes shown to the walker.
//
//  Runs the search once per hill-aversion setting, then filters the results:
//  candidates that overlap an already-kept route too heavily are dropped, and so
//  are ones that detour far beyond the quickest survivor. Short trips legitimately
//  collapse to a single option -- offering one honest route beats padding the
//  list with near-duplicates.
//
//  Not yet implemented.
