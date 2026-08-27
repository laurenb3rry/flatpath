//  MapMarkers.swift
//
//  The two ends of a trip, as they are drawn on the map.
//
//  Both are marks on a line rather than pins stuck through the map beside it.
//  MapKit's own `Marker` draws a balloon — a shape sized to hold a symbol, with
//  a point hanging off the bottom of it — which is the right thing for a place
//  the walker might tap and the wrong thing for the ends of a route they are
//  reading. A balloon is bigger than the line it terminates and sits above the
//  ground it refers to, so on a route drawn seven points wide the two loudest
//  objects on screen were the two least interesting.
//
//  Kept together here because the app draws them twice: once while the walker
//  is choosing between routes, once while they are walking one. Two definitions
//  would let the same trip end in two different marks depending on which screen
//  it was being read on.

import SwiftUI

/// Where the walk begins.
///
/// A square barely wider than the route line, so it reads as a cap on the end
/// of the line rather than as something laid on top of it. It marks a start the
/// walker named; the emerald dot that marks where they actually are is a
/// different thing and is drawn differently.
struct StartMarker: View {
    var body: some View {
        Rectangle()
            .fill(Theme.accent)
            .frame(width: Self.side, height: Self.side)
            .shadow(color: .black.opacity(0.6), radius: 3)
    }

    /// Three points wider than the route, which is enough to be found and not
    /// enough to become a shape of its own. Written against the line width so
    /// that changing how heavy the route is drawn cannot leave the mark on
    /// either side of it looking like a mistake.
    private static let side = Theme.Line.selected + 3
}

/// Where the walk ends.
///
/// An x, which is the mark that means *here* on something being read rather
/// than the mark that means *a place*. A flag was the second reading: it stood
/// up off the map, carried its own outline, and looked like somewhere to go
/// next rather than the end of the line already drawn.
struct DestinationMarker: View {
    var body: some View {
        Image(systemName: "xmark")
            .font(.system(size: Self.size, weight: .bold))
            .foregroundStyle(Theme.accent)
            .shadow(color: .black.opacity(0.6), radius: 3)
    }

    /// Drawn to about the same weight as the start's square. The two ends of
    /// one trip should read as a pair.
    private static let size = Theme.Line.selected + 6
}
