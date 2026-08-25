//  AStarConformanceTests.swift
//
//  Pins the router to a hand-traced result on a small grid whose edge costs are
//  known exactly: one steep block sits on the otherwise-cheapest path, and the
//  correct answer routes around it.
//
//  Both the total cost and the exact sequence of nodes are asserted. Total alone
//  is not enough -- an equal-cost detour would pass while still proving the
//  search is not reproducing the intended path.
//
//  Not yet implemented.
