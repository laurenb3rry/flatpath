//  NavigationView.swift
//
//  Turn-by-turn screen: the instruction ahead, what follows it, and how much
//  walk is left.
//
//  The screen is read at a glance, one-handed, while walking. So the maneuver
//  ahead gets the top of the display at a size readable at arm's length, the
//  instruction after it gets one quiet line, and everything else -- the map, the
//  figures at the foot -- is there to be looked at when the walker chooses to
//  stop and look, not to compete with the sentence they need.
//
//  Steps advance off CoreLocation and nothing else. There is no simulated
//  progress and no timer: if the walker stops, the instruction stops with them,
//  and the corner it names stays named until they actually reach it.

import CoreLocation
import MapKit
import SwiftUI

struct NavigationView: View {
    let route: RouteOption

    /// The walker's position, shared with the map screen behind this one so that
    /// both read the same filtered fix rather than each running their own.
    let location: LocationManager

    /// Leave navigation and go back to the routes.
    let onEnd: () -> Void

    private let coordinates: [CLLocationCoordinate2D]

    @State private var follower: ManeuverFollower
    @State private var camera: MapCameraPosition = .automatic

    init(route: RouteOption, graph: WalkingGraph, location: LocationManager, onEnd: @escaping () -> Void) {
        self.route = route
        self.location = location
        self.onEnd = onEnd
        coordinates = route.nodes.map {
            CLLocationCoordinate2D(latitude: graph.latitudes[$0], longitude: graph.longitudes[$0])
        }
        // Derived once, when the screen is presented for a given route. The
        // instructions are a function of the route alone, so recomputing them as
        // the walker moves would be work done to reach the same answer.
        _follower = State(
            initialValue: ManeuverFollower(
                steps: Maneuvers.steps(for: route, in: graph),
                coordinates: coordinates
            )
        )
    }

    /// How far above the walker the camera sits, in meters. Close enough that the
    /// next corner is identifiable, far enough that the one after it is on screen.
    private static let followDistance: CLLocationDistance = 420

    var body: some View {
        map
            .safeAreaInset(edge: .top, spacing: 0) { banner }
            .safeAreaInset(edge: .bottom, spacing: 0) { footer }
            .task { follow(fix) }
            .onChange(of: fix) { _, moved in follow(moved) }
    }

    // MARK: Position

    /// The current fix in a form `onChange` can compare. `CLLocationCoordinate2D`
    /// is not equatable, and the screen has to react to movement rather than to
    /// every republication of the same position.
    private struct Fix: Equatable {
        let latitude: Double
        let longitude: Double

        init(_ coordinate: CLLocationCoordinate2D) {
            latitude = coordinate.latitude
            longitude = coordinate.longitude
        }

        var coordinate: CLLocationCoordinate2D {
            CLLocationCoordinate2D(latitude: latitude, longitude: longitude)
        }
    }

    private var fix: Fix? { location.coordinate.map(Fix.init) }

    /// Take the walker's new position: move the instruction on if they have
    /// reached the corner it names, and bring the camera with them.
    private func follow(_ fix: Fix?) {
        guard let fix else { return }

        follower.advance(to: fix.coordinate)

        // Turned to the heading of the stretch being walked, so that what is
        // ahead on the screen is what is ahead of the walker. Before the first
        // maneuver there is no stretch behind them, so the route's opening
        // heading stands in.
        let heading = follower.underfoot?.bearing ?? follower.pending?.bearing ?? 0
        withAnimation(.easeInOut(duration: 0.4)) {
            camera = .camera(
                MapCamera(
                    centerCoordinate: fix.coordinate,
                    distance: Self.followDistance,
                    heading: heading
                )
            )
        }
    }

    // MARK: Map

    private var map: some View {
        Map(position: $camera) {
            MapPolyline(coordinates: coordinates)
                .stroke(.tint, style: StrokeStyle(lineWidth: 7, lineCap: .round, lineJoin: .round))

            // The corner the instruction is talking about, marked so that the
            // sentence and the map are pointing at the same place. Not on the
            // last step, where the flag below is already marking it.
            if let pending = follower.pending, !follower.isFinishing {
                Annotation("Next turn", coordinate: pending.coordinate) {
                    ManeuverMarker(symbol: pending.symbol)
                }
                .annotationTitles(.hidden)
            }

            if let destination = coordinates.last {
                Marker("Destination", systemImage: "flag.fill", coordinate: destination)
            }

            if let fix {
                Annotation("You", coordinate: fix.coordinate) {
                    WalkerMarker()
                }
                .annotationTitles(.hidden)
            }
        }
        .mapControls { MapCompass() }
    }

    // MARK: Instruction

    private var hasArrived: Bool { follower.hasArrived }

    private var banner: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(alignment: .top, spacing: 14) {
                Image(systemName: hasArrived ? "mappin.and.ellipse" : (follower.pending?.symbol ?? "figure.walk"))
                    .font(.system(size: 32, weight: .semibold))
                    .foregroundStyle(.tint)
                    .frame(width: 44)

                VStack(alignment: .leading, spacing: 3) {
                    if let distance = distanceToManeuver, !hasArrived {
                        Text(distance)
                            .font(.system(.title2, design: .monospaced).weight(.semibold))
                    }

                    Text(hasArrived ? "You have arrived" : (follower.pending?.instruction ?? "Follow the route"))
                        .font(.title3.weight(.medium))
                        .fixedSize(horizontal: false, vertical: true)
                }

                Spacer(minLength: 0)
            }

            if let next = follower.following, !hasArrived {
                Divider()
                Text("then \(next.instruction.sentenceContinuation)")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }

            if let notice {
                Divider()
                Text(notice)
                    .font(.footnote)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 14)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(.regularMaterial)
    }

    /// Meters to the corner ahead, in the same units as the cards. Shown only
    /// once there is a position to measure from — a distance guessed at while
    /// the fix is still arriving would be a number the walker could not act on.
    private var distanceToManeuver: String? {
        follower.distanceToPending.map { WalkingFigures.distance(meters: $0) }
    }

    /// Why the instruction is not advancing, when that needs saying.
    private var notice: String? {
        if let failure = location.failure { return failure }
        guard fix == nil else { return nil }
        return "Waiting for your location. The route is drawn below; steps advance once a fix arrives."
    }

    // MARK: Remaining

    /// What is left of the walk, and the way out.
    ///
    /// The same three figures the route was chosen by, counted down rather than
    /// restated: the walker picked this route over a quicker one to save the
    /// climb, so the climb still to come is the number that tells them whether
    /// the trade is working out.
    private var footer: some View {
        HStack(alignment: .lastTextBaseline, spacing: 12) {
            VStack(alignment: .leading, spacing: 3) {
                // A duration is never rounded down to nothing, so standing at
                // the destination would otherwise be reported as a minute away.
                Text(hasArrived ? "Arrived" : WalkingFigures.duration(seconds: follower.timeRemaining))
                    .font(.system(.title3, design: .monospaced).weight(.semibold))

                HStack(spacing: 6) {
                    Text(WalkingFigures.distance(meters: follower.distanceRemaining))
                    Text("·").foregroundStyle(.tertiary)
                    Text(WalkingFigures.climb(meters: follower.climbRemaining))
                    Text("·").foregroundStyle(.tertiary)
                    Text(route.name)
                }
                .font(.system(.footnote, design: .monospaced))
                .foregroundStyle(.secondary)
                .lineLimit(1)
                .minimumScaleFactor(0.8)
            }

            Spacer(minLength: 0)

            Button("End", role: .cancel, action: onEnd)
                .buttonStyle(.bordered)
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(.regularMaterial)
    }
}

// MARK: - Markers

/// The corner the current instruction names.
private struct ManeuverMarker: View {
    let symbol: String

    var body: some View {
        Image(systemName: symbol)
            .font(.caption.weight(.bold))
            .foregroundStyle(.background)
            .frame(width: 26, height: 26)
            .background(Circle().fill(.tint))
            .overlay(Circle().stroke(.background, lineWidth: 2))
            .shadow(radius: 2)
    }
}

/// The walker, drawn the same way the map screen draws the start of a trip so
/// that the dot means the same thing on both screens.
private struct WalkerMarker: View {
    var body: some View {
        Circle()
            .fill(.tint)
            .overlay(Circle().stroke(.background, lineWidth: 3))
            .frame(width: 18, height: 18)
            .shadow(radius: 2)
    }
}

// MARK: - Phrasing

private extension String {
    /// The instruction as the tail of a longer sentence: "then turn left onto
    /// Powell Street". Every instruction opens with its verb, so lowercasing the
    /// first character is all that joining one to a "then" takes.
    var sentenceContinuation: String {
        guard let first else { return self }
        return first.lowercased() + dropFirst()
    }
}
