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
//
//  This screen is not the only place the walk shows up, and it is not the one
//  that matters most. A walker pockets the phone between corners, so the same
//  state is published to a Live Activity -- the Lock Screen and the Dynamic
//  Island -- and tracking is held open while the app is off screen. What is on
//  this screen and what is on the Lock Screen are built from one value, so the
//  two cannot drift apart.

import CoreLocation
import MapKit
import SwiftUI

struct NavigationView: View {
    let route: RouteOption

    /// The walker's position, shared with the map screen behind this one so that
    /// both read the same filtered fix rather than each running their own.
    let location: LocationManager
    let destinationCoordinate: CLLocationCoordinate2D?

    /// Where the walk ends, as the walker named it. Shown outside the app,
    /// where "Flattest" alone would not say which trip is in progress.
    let destination: String

    /// Leave navigation and go back to the routes.
    let onEnd: () -> Void

    @Environment(\.displayScale) private var displayScale

    private let coordinates: [CLLocationCoordinate2D]

    @State private var follower: ManeuverFollower
    @State private var camera: MapCameraPosition = .automatic
    @State private var live = LiveNavigation()

    /// Whether the whole list of directions is pulled down over the map.
    @State private var showsAllSteps = false
    @State private var groundScale = 0.5
    @State private var followsLocation = true
    @State private var directionsHeight: CGFloat = 0
    @State private var arrivalTask: Task<Void, Never>?

    init(
        route: RouteOption,
        graph: WalkingGraph,
        location: LocationManager,
        destinationCoordinate: CLLocationCoordinate2D?,
        destination: String,
        onEnd: @escaping () -> Void
    ) {
        self.route = route
        self.location = location
        self.destinationCoordinate = destinationCoordinate
        self.destination = destination
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
            .overlay(alignment: .top) { banner.safeAreaPadding(.top) }
            .safeAreaInset(edge: .bottom, spacing: 0) { footer }
            .task {
                // Tracking carries on with the app off screen for as long as
                // this screen is up, and both it and the Live Activity are
                // handed back when it comes down -- including when the walker
                // ends the walk early.
                location.startNavigating()
                live.begin(routeName: route.name, destination: destination, state: published)
                follow(fix)
            }
            .onDisappear {
                arrivalTask?.cancel()
                location.stopNavigating()
                live.end()
            }
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

        withAnimation(Theme.Motion.instruction) { follower.advance(to: fix.coordinate) }
        live.update(published)

        if follower.hasArrived, arrivalTask == nil {
            arrivalTask = Task { @MainActor in
                try? await Task.sleep(for: .seconds(3))
                guard !Task.isCancelled else { return }
                onEnd()
            }
        }

        // Turned to the heading of the stretch being walked, so that what is
        // ahead on the screen is what is ahead of the walker. Before the first
        // maneuver there is no stretch behind them, so the route's opening
        // heading stands in.
        if followsLocation { centerOnLocation() }
    }

    private func centerOnLocation() {
        guard let fix else { return }
        followsLocation = true
        let heading = follower.underfoot?.bearing ?? follower.pending?.bearing ?? 0
        withAnimation(Theme.Motion.camera) {
            camera = .camera(
                MapCamera(
                    centerCoordinate: snappedToRoute(fix.coordinate),
                    distance: Self.followDistance,
                    heading: heading
                )
            )
        }
    }

    // MARK: Map

    private var map: some View {
        MapReader { proxy in
            Map(position: $camera) {
                MapPolyline(coordinates: displayCoordinates)
                    .stroke(Theme.accent, style: Theme.Line.stroke(routeLineWidth))

                if let destination = destinationCoordinate {
                Annotation(self.destination, coordinate: destination, anchor: .bottom) {
                        DestinationMarker()
                    }
                }

                if let fix {
                    Annotation("You", coordinate: snappedToRoute(fix.coordinate)) {
                        WalkerMarker(diameter: routeLineWidth + 5)
                    }
                    .annotationTitles(.hidden)
                }
            }
            .mapStyle(Theme.mapStyle)
            .mapControls { MapCompass() }
            .onMapCameraChange(frequency: .continuous) { context in
                measureGround(of: context.region, using: proxy)
            }
            .simultaneousGesture(
                DragGesture(minimumDistance: 2).onChanged { _ in followsLocation = false }
            )
            .simultaneousGesture(
                MagnifyGesture().onChanged { _ in followsLocation = false }
            )
        }
    }

    private var routeLineWidth: CGFloat { Theme.Line.streetWidth(at: groundScale) }

    private var displayCoordinates: [CLLocationCoordinate2D] {
        guard let destinationCoordinate else { return coordinates }
        return RouteDisplayGeometry.endingBeforeDestination(
            coordinates,
            destination: destinationCoordinate,
            clearance: 8
        )
    }

    private func measureGround(of region: MKCoordinateRegion, using proxy: MapProxy) {
        let degrees = region.span.latitudeDelta / 4
        guard degrees > 0 else { return }
        let center = region.center
        let north = CLLocationCoordinate2D(
            latitude: center.latitude + degrees, longitude: center.longitude)
        guard let from = proxy.convert(center, to: .local),
            let to = proxy.convert(north, to: .local)
        else { return }
        let points = hypot(to.x - from.x, to.y - from.y)
        guard points > 0 else { return }
        groundScale = degrees * 111_320 / Double(points)
    }

    private func snappedToRoute(_ point: CLLocationCoordinate2D) -> CLLocationCoordinate2D {
        var result = coordinates.first ?? point
        var nearest = Double.greatestFiniteMagnitude
        for (start, end) in zip(coordinates, coordinates.dropFirst()) {
            let latitudeScale = 111_320.0
            let longitudeScale = latitudeScale * cos(start.latitude * .pi / 180)
            let px = (point.longitude - start.longitude) * longitudeScale
            let py = (point.latitude - start.latitude) * latitudeScale
            let sx = (end.longitude - start.longitude) * longitudeScale
            let sy = (end.latitude - start.latitude) * latitudeScale
            let lengthSquared = sx * sx + sy * sy
            let fraction =
                lengthSquared > 0
                ? min(1, max(0, (px * sx + py * sy) / lengthSquared))
                : 0
            let dx = px - sx * fraction
            let dy = py - sy * fraction
            let offset = dx * dx + dy * dy
            if offset < nearest {
                nearest = offset
                result = CLLocationCoordinate2D(
                    latitude: start.latitude + (end.latitude - start.latitude) * fraction,
                    longitude: start.longitude + (end.longitude - start.longitude) * fraction
                )
            }
        }
        return result
    }

    // MARK: Instruction

    private var hasArrived: Bool { follower.hasArrived }

    private var banner: some View {
        VStack(spacing: 0) {
            Button {
                withAnimation(Theme.Motion.selection) { showsAllSteps.toggle() }
            } label: {
                instruction
            }
            .buttonStyle(.plain)

            if showsAllSteps {
                hairline
                allSteps
            }
        }
        .floatingSurface()
        .padding(.horizontal, Theme.Inset.sheet)
        .padding(.top, Theme.Inset.sheet)
    }

    /// The instruction in hand, and the handle for the rest of them.
    private var instruction: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(alignment: .top, spacing: 14) {
                // The instruction in hand is the active thing on this screen,
                // which is what the accent is for.
                Image(
                    systemName: hasArrived
                        ? "mappin.and.ellipse" : (follower.pending?.symbol ?? "figure.walk")
                )
                .font(.system(size: 32, weight: .semibold))
                .foregroundStyle(Theme.accent)
                .frame(width: 44)
                .contentTransition(.symbolEffect(.replace))

                VStack(alignment: .leading, spacing: 3) {
                if let distance = distanceToManeuver, !hasArrived {
                    Text(distance)
                        .font(.system(size: 32, weight: .semibold, design: .monospaced))
                        .foregroundStyle(Theme.primaryText)
                        .contentTransition(.numericText())
                    }

                    Text(
                        hasArrived ? "You have arrived" : (follower.pending?.instruction ?? "Follow the route")
                    )
                    .font(Theme.label(.title3, weight: .medium))
                    .foregroundStyle(Theme.primaryText)
                    .fixedSize(horizontal: false, vertical: true)
                }

                Spacer(minLength: 0)

                // The only affordance for the list below. Rotating rather than
                // swapping glyphs so the tap reads as the same control moving.
                Image(systemName: "chevron.down")
                    .font(Theme.label(.footnote, weight: .semibold))
                    .foregroundStyle(Theme.secondaryText)
                    .rotationEffect(.degrees(showsAllSteps ? 180 : 0))
                    .padding(.top, 6)
            }

            if !hasArrived {
                climbWarning
            }


            if let notice {
                hairline
                Text(notice)
                    .font(Theme.label(.footnote))
                    .foregroundStyle(Theme.secondaryText)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 14)
        .frame(maxWidth: .infinity, alignment: .leading)
        .contentShape(.rect)
    }

    private var hairline: some View {
        Rectangle()
            .fill(Theme.hairline)
            .frame(height: 1 / displayScale)
    }

    /// The steepest climbing grade in the walk immediately around the walker:
    /// the stretch underfoot and the one about to be turned onto.
    ///
    /// Read once and used twice — for the warning on this screen and for the one
    /// published to the Lock Screen — so the two cannot disagree about the hill
    /// the walker is standing on.
    private var steepest: Double {
        [follower.underfoot, follower.pending]
            .compactMap { $0?.steepest }
            .max() ?? 0
    }

    /// A warning for the steep ground immediately around the walker, when there
    /// is any.
    ///
    /// This is the app's own argument made at the moment it matters: someone who
    /// chose a route to avoid climbing is owed the grade of the block they are
    /// on, not only the total once it is behind them.
    ///
    /// The stretch underfoot and the one about to be turned onto are both
    /// considered, and the steeper wins. Warning only about what is ahead would
    /// take the mark off the screen at the moment the walker started up the very
    /// block it was warning them about.
    @ViewBuilder
    private var climbWarning: some View {
        if Theme.warning(for: Grade(slope: steepest)) != nil {
            HStack(spacing: 6) {
                Image(systemName: "arrow.up.forward")
                    .font(Theme.label(.caption, weight: .bold))
                Text(WalkingFigures.grade(steepest))
                    .font(Theme.figure(.caption, weight: .semibold))
                Text("climb")
                    .font(Theme.label(.caption))
            }
            .foregroundStyle(Theme.primaryText)
            .frame(maxWidth: .infinity, alignment: .trailing)
        }
    }

    /// Every direction on the route, from the first to the destination.
    ///
    /// The whole list rather than only what is left. A walker opening this is
    /// usually checking the shape of the trip -- how many turns, which streets,
    /// how far in -- and that question needs the part already walked as much as
    /// the part ahead. What has been done is dimmed rather than dropped, so the
    /// list reads as a position in a route instead of a shrinking to-do list.
    private var allSteps: some View {
        ScrollViewReader { scroller in
            ScrollView {
                VStack(spacing: 0) {
                    ForEach(follower.steps) { step in
                        StepRow(
                            step: step,
                            state: state(of: step),
                            isLast: step.id == follower.steps.last?.id
                        )
                        .id(step.id)
                    }
                }
                .onGeometryChange(for: CGFloat.self) { $0.size.height } action: {
                    directionsHeight = $0
                }
            }
            // Tall enough to hold a handful of turns, short enough that the map
            // and the walker's position on it are never entirely covered.
            .frame(height: min(320, directionsHeight))
            .onAppear {
                // Open at the instruction in hand rather than at the start of a
                // walk that may be an hour behind them.
                scroller.scrollTo(follower.index, anchor: .center)
            }
        }
    }

    private func state(of step: ManeuverStep) -> StepRow.State {
        if step.id < follower.index {
            .walked
        } else if step.id == follower.index {
            .current
        } else {
            .ahead
        }
    }

    /// Meters to the corner ahead, in the same units as the cards. Shown only
    /// once there is a position to measure from — a distance guessed at while
    /// the fix is still arriving would be a number the walker could not act on.
    private var distanceToManeuver: String? {
        follower.distanceToPending.map { WalkingFigures.distance(meters: $0) }
    }

    /// Why the instruction is not advancing, when that needs saying.
    /// The smallest comfortable target for a finger, and the size the way out
    /// is given whatever the word in it measures.
    private static let endTapTarget: CGFloat = 44

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
        // Centered rather than baseline-aligned. Aligning baselines matched the
        // way out to the *last* line of the figures beside it -- the small one
        // -- which left it sitting against the bottom of the panel instead of
        // on it.
        VStack(spacing: 8) {
            if !followsLocation {
                Button("- back to loc -", action: centerOnLocation)
                    .font(Theme.label(.footnote))
                    .foregroundStyle(Theme.accent)
                    .frame(maxWidth: .infinity)
                    .accessibilityLabel("Back to current location")
            }

            HStack(spacing: 12) {
                VStack(alignment: .leading, spacing: 3) {
                // A duration is never rounded down to nothing, so standing at
                // the destination would otherwise be reported as a minute away.
                Text(hasArrived ? "Arrived" : WalkingFigures.duration(seconds: follower.timeRemaining))
                    .font(Theme.figure(.title3, weight: .semibold))
                    .foregroundStyle(Theme.primaryText)
                    .contentTransition(.numericText())

                HStack(spacing: 6) {
                    Text(WalkingFigures.distance(meters: follower.distanceRemaining))
                    Text("·").foregroundStyle(Theme.tertiaryText)
                    Text(WalkingFigures.climb(meters: follower.climbRemaining))
                    Text("·").foregroundStyle(Theme.tertiaryText)
                    Text(route.name)
                        .font(Theme.label(.footnote))
                }
                .font(Theme.figure(.footnote))
                .foregroundStyle(Theme.secondaryText)
                .lineLimit(1)
                .minimumScaleFactor(0.8)
            }

            Spacer(minLength: 0)

            // Leaving is not the active state, so it is drawn as a way out
            // rather than as something to press. Drawn as one, though, and not
            // sized as one: the label is three characters, and a hit area that
            // stopped at the glyphs would be a target the walker has to be
            // accurate about while walking. The frame is what is tappable, not
            // the word.
            Button(action: onEnd) {
                Text("End")
                    .font(Theme.label(.subheadline, weight: .medium))
                    .foregroundStyle(Theme.secondaryText)
                    .frame(minWidth: Self.endTapTarget, minHeight: Self.endTapTarget)
                    .contentShape(.rect)
            }
            .buttonStyle(.plain)
            .accessibilityLabel("End the walk")
        }
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .floatingSurface()
        .padding(.horizontal, Theme.Inset.sheet)
        .padding(.bottom, Theme.Inset.sheet)
    }
}

// MARK: - Publishing

extension NavigationView {
    /// The walk as the Lock Screen and the Dynamic Island show it.
    ///
    /// Every figure is formatted here rather than in the extension, and every
    /// one of them is the same value this screen is displaying — the walker
    /// glancing at a locked phone is reading the same instruction they would
    /// see by unlocking it.
    fileprivate var published: NavigationAttributes.ContentState {
        NavigationAttributes.ContentState(
            instruction: hasArrived
                ? "You have arrived"
                : (follower.pending?.instruction ?? "Follow the route"),
            distanceToManeuver: hasArrived ? nil : distanceToManeuver,
            symbol: hasArrived ? "mappin.and.ellipse" : (follower.pending?.symbol ?? "figure.walk"),
            following: nil,
            timeRemaining: WalkingFigures.duration(seconds: follower.timeRemaining),
            distanceRemaining: WalkingFigures.distance(meters: follower.distanceRemaining),
            climbRemaining: WalkingFigures.climb(meters: follower.climbRemaining),
            climb: publishedClimb,
            hasArrived: hasArrived
        )
    }

    fileprivate var publishedClimb: NavigationAttributes.Climb? {
        let grade = Grade(slope: steepest)
        guard grade.isWorthWarningAbout else { return nil }
        return NavigationAttributes.Climb(grade: grade, percentage: WalkingFigures.grade(steepest))
    }
}

/// One direction in the list.
private struct StepRow: View {
    enum State {
        case walked
        case current
        case ahead
    }

    let step: ManeuverStep
    let state: State
    let isLast: Bool

    @Environment(\.displayScale) private var displayScale

    var body: some View {
        HStack(alignment: .top, spacing: 12) {
            Image(systemName: step.symbol)
                .font(Theme.label(.subheadline, weight: .semibold))
                .foregroundStyle(symbolColor)
                .frame(width: 22)

            VStack(alignment: .leading, spacing: 2) {
                Text(step.instruction)
                    .font(Theme.label(.subheadline, weight: state == .current ? .semibold : .regular))
                    .foregroundStyle(textColor)
                    .fixedSize(horizontal: false, vertical: true)

                if !isLast {
                    HStack(spacing: 6) {
                        Text(WalkingFigures.distance(meters: step.distance))
                    if Theme.warning(for: step.grade) != nil {
                            Text("·").foregroundStyle(Theme.tertiaryText)
                    Text("\(WalkingFigures.grade(step.steepest)) climb")
                        .foregroundStyle(state == .walked ? Theme.tertiaryText : Theme.secondaryText)
                        }
                    }
                    .font(Theme.figure(.caption))
                    .foregroundStyle(state == .walked ? Theme.tertiaryText : Theme.secondaryText)
                }
            }

            Spacer(minLength: 0)
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 10)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(state == .current ? Theme.accentWash : .clear)
        .overlay(alignment: .bottom) {
            if !isLast {
                Rectangle()
                    .fill(Theme.hairline)
                    .frame(height: 1 / displayScale)
                    .padding(.leading, 50)
            }
        }
    }

    /// The accent marks the instruction in hand — the same thing it means on the
    /// map, on the cards, and on the Lock Screen.
    private var symbolColor: Color {
        switch state {
        case .walked: Theme.tertiaryText
        case .current: Theme.accent
        case .ahead: Theme.secondaryText
        }
    }

    private var textColor: Color {
        switch state {
        case .walked: Theme.tertiaryText
        case .current, .ahead: Theme.primaryText
        }
    }
}

// MARK: - Markers

/// The corner the current instruction names.
private struct ManeuverMarker: View {
    let symbol: String

    var body: some View {
        Image(systemName: symbol)
            .font(Theme.label(.caption, weight: .bold))
            .foregroundStyle(Theme.background)
            .frame(width: 26, height: 26)
            .background(Circle().fill(Theme.accent))
            .overlay(Circle().stroke(Theme.background, lineWidth: 2))
            .shadow(color: .black.opacity(0.5), radius: 3)
    }
}

/// The walker, drawn the same way the map screen draws the start of a trip so
/// that the dot means the same thing on both screens.
private struct WalkerMarker: View {
    let diameter: CGFloat

    var body: some View {
        Circle()
            .fill(Color.white)
            .frame(width: diameter, height: diameter)
            .overlay(Circle().stroke(Theme.background.opacity(0.75), lineWidth: 2))
            .shadow(color: .black.opacity(0.5), radius: 3)
    }
}

// MARK: - Phrasing

extension String {
    /// The instruction as the tail of a longer sentence: "then turn left onto
    /// Powell Street". Every instruction opens with its verb, so lowercasing the
    /// first character is all that joining one to a "then" takes.
    fileprivate var sentenceContinuation: String {
        guard let first else { return self }
        return first.lowercased() + dropFirst()
    }
}
