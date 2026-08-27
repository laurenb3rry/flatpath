//  MapContainerView.swift
//
//  The map surface: basemap, start and destination markers, and one polyline per
//  route option, with the selected route drawn distinctly from the rest.
//
//  This is where a trip is assembled. A trip needs two ends, and the two arrive
//  by different means: the start is handed over by CoreLocation without being
//  asked for, while the destination is something the walker states, either by
//  searching for it or by pressing a point on the map. Both ends are held here,
//  because neither is meaningful alone and the camera has to frame whichever of
//  them exist.
//
//  Everything the walker can set is checked against the routable area before it
//  is accepted. A point outside it looks perfectly ordinary on Apple's basemap,
//  which covers the world, but there is no graph underneath it — so the refusal
//  has to happen here at the point of entry, while there is still a gesture to
//  attach the explanation to.
//
//  Once both ends exist the routes are found here too, off the main actor: a
//  dozen searches across a city-sized graph are tens of milliseconds of work,
//  but they are milliseconds spent between two frames, and the map is being
//  panned while they run.

import CoreLocation
import MapKit
import SwiftUI

struct MapContainerView: View {
    /// The walking network every route is found in. Handed over already loaded,
    /// because there is no version of this screen that works without it.
    let graph: WalkingGraph

    @Environment(\.displayScale) private var displayScale

    @State private var location = LocationManager()
    @State private var search = DestinationSearch()

    @State private var query = ""

    /// Which field, if any, currently holds the keyboard. Keyed by endpoint
    /// rather than a bare flag so that moving between the two fields is a change
    /// of focus rather than a drop and a re-acquire, which would dismiss the
    /// keyboard and raise it again between taps.
    @FocusState private var focused: Endpoint?

    /// The end of the trip being searched for, or `nil` when the map has the
    /// screen.
    ///
    /// One at a time, and never both: the results list means something different
    /// depending on which end it is filling, and a walker looking at a list of
    /// places has to know which of the two they are about to set.
    @State private var searching: Endpoint?

    /// Where the walk begins, or `nil` to begin wherever the walker is.
    ///
    /// Nil is the ordinary case and is deliberately not filled in with the
    /// current fix: a trip planned from where you are stays anchored to where
    /// you are as you move, and only becomes a fixed place when someone says so.
    @State private var origin: Destination?

    @State private var destination: Destination?

    /// Which end of the trip the next search result or long press sets.
    @State private var editing: Endpoint = .destination

    @State private var rejectedPin: String?

    @State private var routes: [PlannedRoute] = []
    @State private var selectedRoute: RouteOption.ID?
    @State private var isRouting = false

    /// How far out of the way the flat options may go.
    ///
    /// Deliberately something the walker sets rather than a constant, and
    /// deliberately not remembered between trips: it is a statement about this
    /// walk, and the answer for a quick errand is not the answer for a
    /// deliberate flat walk across town an hour later.
    @State private var detour: DetourTolerance = .default

    /// Why there are no routes, when the reason is worth showing.
    @State private var routingProblem: String?

    /// Why the change the walker just asked for is not on their route: a hill
    /// with no way round it, or a point with no way through it.
    @State private var steeringProblem: String?

    /// The identity the next refused hill gets.
    ///
    /// Monotonic and never reused. A hill undone and refused again is a new
    /// avoidance rather than the old one returning, which keeps the detours the
    /// map is drawing from disagreeing with the list they were built from.
    @State private var nextAvoidance = 0

    /// How much ground one point of screen currently covers, in meters.
    ///
    /// The hill waves are sized from this so that they stay the same size to
    /// look at whether the map is showing four blocks or the whole city. It is
    /// held coarsely — see `measureGround(using:)` — so that panning does not
    /// redraw them at a slightly different size every frame.
    @State private var groundScale = 1.0

    /// The reroute a tapped hill set off, if one is still being worked out.
    @State private var rerouting: Task<Void, Never>?

    /// Whether that reroute is still running, which is what makes a second tap
    /// wait rather than build on a route the first has not finished changing.
    @State private var isRerouting = false

    /// Ties the detour control's moving fill to whichever segment holds it, so
    /// the selection slides between them instead of blinking from one to the next.
    @Namespace private var detourTrack

    /// How tall the matches want to be, so the card can close under the last of
    /// them rather than around a fixed hole.

    /// The route being walked, once the walker has started on one. Holding the
    /// route rather than a flag keeps navigation on the option that was chosen:
    /// a replan behind the covered screen cannot swap the instructions out from
    /// under someone already following them.
    @State private var navigating: PlannedRoute?

    /// Opens on the whole service area, so the first frame shows the walker
    /// exactly how much ground the app covers before it asks for their location.
    @State private var camera: MapCameraPosition = .region(ServiceArea.region)

    /// Where a route would begin: the place the walker chose, or failing that
    /// the current fix, in either case only once it falls inside the routable
    /// area.
    private var start: CLLocationCoordinate2D? {
        if let origin {
            return ServiceArea.contains(origin.coordinate) ? origin.coordinate : nil
        }
        guard let coordinate = location.coordinate, ServiceArea.contains(coordinate) else {
            return nil
        }
        return coordinate
    }

    var body: some View {
        ZStack(alignment: .bottom) {
            mapLayer
                .ignoresSafeArea()

            if searching == nil {
                tripPanel
            }

            searchLayer
        }
        .background(Theme.background)
        .fullScreenCover(item: $navigating) { walk in
            NavigationView(
                route: walk.option,
                graph: graph,
                location: location,
                destination: destination?.name ?? "your destination"
            ) {
                navigating = nil
            }
        }
        .task {
            location.start()
            // Nothing is being walked at this point, so any Live Activity still
            // standing is left over from a run that was swiped away rather than
            // ended.
            LiveNavigation.endOrphans()
        }
        .task(id: query) { await search.search(matching: query) }
        .task(id: planRequest) { await planRoutes() }
        .onChange(of: searching) { _, end in
            // Focus only when search mode changes. A focus task attached to the
            // field itself is recreated as typing changes the field's contents.
            guard let end else {
                focused = nil
                return
            }
            Task { @MainActor in
                await Task.yield()
                guard searching == end else { return }
                focused = end
            }
        }
        .onChange(of: selectedRoute) { _, _ in
            // The notice was about the route that was showing when the walker
            // asked, and this is a different one — with its own hills, and its
            // own ground under the point they pressed.
            steeringProblem = nil
        }
        .onChange(of: location.hasFix) { _, hasFix in
            // Frame the arrival of a fix, not every update after it. Re-framing
            // on each new position would wrestle the map back from a walker who
            // had panned away from themselves to look at where they are going.
            guard hasFix, origin == nil, destination == nil, let start else { return }
            frame(coordinates: [start])
        }
    }

    private var mapLayer: some View {
        MapReader { proxy in
            Map(position: $camera) {
                // Unselected first, then the selected one, then the markers.
                // Order is depth here, and where two routes share a block the
                // one the walker chose has to be the line on top of the pile.
                ForEach(routes) { route in
                    if route.id != selectedRoute {
                        MapPolyline(coordinates: route.coordinates)
                            .stroke(Theme.routeAlternative, style: Theme.Line.stroke(Theme.Line.alternative))
                    }
                }

                if let selected = routes.first(where: { $0.id == selectedRoute }) {
                    // Under the line rather than over it: a detour is route,
                    // and the glow only has to say which stretch of it the
                    // walker put there and can take back.
                    ForEach(selected.detours) { detour in
                        MapPolyline(coordinates: detour.coordinates)
                            .stroke(Theme.detourGlow, style: Theme.Line.stroke(Theme.Line.detour))
                    }

                    ForEach(selected.shades) { shade in
                        MapPolyline(coordinates: shade.coordinates)
                            .stroke(shade.color, style: Theme.Line.stroke(Theme.Line.selected))
                    }

                    // Only the chosen route is marked for steepness. Marking
                    // every line at once would say nothing about the choice
                    // between them, and the walker is comparing routes here --
                    // what they need to see is which parts of *this* one climb.
                    //
                    // Drawn in the line's own color, as a wave rather than as a
                    // warning: the hills are the part of the route the walker
                    // can argue with, and one is refused by tapping the wave.
                    ForEach(selected.climbs) { climb in
                        MapPolyline(coordinates: Zigzag.along(
                            climb.coordinates,
                            amplitude: Double(Theme.Line.hillAmplitude) * groundScale,
                            wavelength: Double(Theme.Line.hillWave) * groundScale
                        ))
                        .stroke(
                            Theme.routeShade(at: climb.along),
                            style: Theme.Line.stroke(Theme.Line.hill)
                        )
                    }

                    // Last, and on top of everything the route is drawn from:
                    // a stop is the walker's own hand on the line and has to be
                    // findable to be taken back off it.
                    ForEach(selected.stops) { stop in
                        Annotation("", coordinate: stop.coordinate) {
                            StopMarker()
                        }
                        .annotationTitles(.hidden)
                    }
                }

                // The walker's own position, wherever the trip is starting
                // from. It is the one thing on the map that is not a choice.
                if let here = location.coordinate, ServiceArea.contains(here) {
                    Annotation("You", coordinate: here) {
                        WalkerMarker()
                    }
                    .annotationTitles(.hidden)
                }

                if let origin {
                    Marker(origin.name, systemImage: "smallcircle.filled.circle", coordinate: origin.coordinate)
                        .tint(Theme.destination)
                }

                if let destination {
                    Marker(destination.name, systemImage: "flag.fill", coordinate: destination.coordinate)
                        .tint(Theme.destination)
                }
            }
            .mapStyle(Theme.mapStyle)
            .mapControls {
                MapCompass()
                MapScaleView()
            }
            .onMapCameraChange(frequency: .continuous) { context in
                measureGround(of: context.region, using: proxy)
            }
            // Before the long press, so that the shorter gesture is the one a
            // quick touch on a hill resolves to.
            .onTapGesture { point in
                answer(tapAt: point, using: proxy)
            }
            .gesture(dropPin(using: proxy))
        }
    }

    // MARK: Destination capture

    /// Press and hold to place a destination.
    ///
    /// A long press rather than a tap: the map is something the walker pans and
    /// zooms constantly while reading it, and a tap-to-drop would leave a pin
    /// behind every time they touched the screen to steady it. The drag stage is
    /// what makes the touch point available — the press alone reports only that
    /// it happened, not where.
    private func dropPin(using proxy: MapProxy) -> some Gesture {
        LongPressGesture(minimumDuration: 0.35)
            .sequenced(before: DragGesture(minimumDistance: 0, coordinateSpace: .local))
            .onEnded { value in
                guard case .second(_, let drag?) = value,
                      let coordinate = proxy.convert(drag.location, from: .local)
                else { return }
                dropPin(at: coordinate)
            }
    }

    /// Take a press on the map.
    ///
    /// What it means depends on whether there is a walk on screen yet. With no
    /// routes showing there is no trip, and the press states one end of it. With
    /// routes showing there is, and a press is the walker saying which way round
    /// they want to go — the trip keeps both its ends and the chosen line is
    /// bent through the point.
    ///
    /// A press used to replace the destination in both cases, which made the
    /// map's one gesture useless for the thing a walker most often wants from a
    /// route in front of them: not somewhere else to go, a different way there.
    private func dropPin(at coordinate: CLLocationCoordinate2D) {
        guard ServiceArea.contains(coordinate) else {
            rejectedPin = "FlatPath only routes inside San Francisco."
            return
        }

        rejectedPin = nil

        if let selected = routes.first(where: { $0.id == selectedRoute }) {
            steer(selected, through: coordinate)
            return
        }

        select(
            Destination(
                name: "Dropped pin",
                address: Self.coordinateLabel.string(from: coordinate),
                coordinate: coordinate,
                isNamed: false
            ),
            as: editing
        )
    }

    /// Bend one route through a point on the map.
    ///
    /// The point is snapped to the network before anything is planned, the same
    /// way both ends of a trip are. A press in the middle of the bay looks
    /// perfectly ordinary on Apple's basemap and has no street under it to route
    /// through, and the refusal has to happen here while there is still a
    /// gesture to attach it to.
    private func steer(_ route: PlannedRoute, through coordinate: CLLocationCoordinate2D) {
        guard let stop = graph.nearestNode(
            toLatitude: coordinate.latitude,
            longitude: coordinate.longitude
        ) else {
            steeringProblem = "There is no walkable street near there."
            return
        }

        // Pressing a point the route already runs through would add a stop that
        // changes nothing and then sits on the line asking to be tapped off
        // again.
        guard !route.waypoints.contains(stop) else { return }

        rebuild(
            route,
            through: RouteVia.insert(stop, into: route.waypoints, along: route.option.nodes, in: graph),
            refusing: route.avoidances
        )
    }

    // MARK: Refusing a hill

    /// Note how much ground the map is currently showing, coarsely.
    ///
    /// Measured through the proxy rather than from the camera's own figures,
    /// which are stated in a distance from the ground whose relationship to
    /// points on the screen depends on the device: converting two coordinates a
    /// known distance apart and measuring the gap between them asks the map
    /// directly and cannot drift from what it draws.
    ///
    /// Rounded to half-octaves of zoom, and that is the point of it. This runs
    /// on every frame of a pan, and a scale that changed continuously would
    /// re-cut every hill wave on the map as the walker's thumb moved -- a
    /// shimmer along the route that says nothing and costs a redraw. Half an
    /// octave is close enough that the waves never look wrong and coarse enough
    /// that ordinary panning does not move between steps at all.
    private func measureGround(of region: MKCoordinateRegion, using proxy: MapProxy) {
        // Probed across a quarter of what is on screen, so both ends of the
        // measurement are inside the map being measured. A probe of some fixed
        // size on the ground would be far outside the view at street zoom and
        // would be asking the map to extrapolate.
        let degrees = region.span.latitudeDelta / 4
        guard degrees > 0 else { return }

        let here = region.center
        let north = CLLocationCoordinate2D(latitude: here.latitude + degrees, longitude: here.longitude)
        guard let from = proxy.convert(here, to: .local),
              let to = proxy.convert(north, to: .local)
        else { return }

        let points = hypot(to.x - from.x, to.y - from.y)
        guard points > 0 else { return }

        let metersPerPoint = degrees * Self.metersPerDegreeLatitude / Double(points)
        let step = (log2(metersPerPoint) * 2).rounded() / 2
        groundScale = pow(2, step)
    }

    private static let metersPerDegreeLatitude = 111_320.0

    /// Take a tap on the map: refuse the hill under it, or put back the ground
    /// a detour of the walker's own replaced.
    ///
    /// Only the chosen route answers, because it is the only one drawn with
    /// hills on it. A tap that lands on neither is a tap on the map, which is
    /// something the walker does constantly to steady the phone, and it is
    /// deliberately not an act.
    private func answer(tapAt point: CGPoint, using proxy: MapProxy) {
        // A tap arriving while the last one is still being worked out is
        // dropped rather than queued. Both taps read the refusals off the route
        // as it stands, and the second would be built on a list the first has
        // not added to yet -- which would silently undo it.
        guard !isRerouting, let selected = routes.first(where: { $0.id == selectedRoute }) else { return }

        // A stop is a point rather than a stretch, so it is the most
        // deliberate thing on the line to aim at and is answered first. It also
        // sits on top of the route, which means a hill wave is nearly always
        // within reach of it too.
        if let stop = nearest(to: point, among: selected.stops, using: proxy) {
            rebuild(
                selected,
                through: selected.waypoints.filter { $0 != stop.mark.id },
                refusing: selected.avoidances
            )
            return
        }

        let detour = nearest(to: point, among: selected.detours, using: proxy)
        let climb = nearest(to: point, among: selected.climbs, using: proxy)

        // Undoing wins a tie, and ties are the normal case: a detour was found
        // to get around a hill, so the two lie near each other by construction.
        // Between "put this back" and "take away more", the walker who is
        // pointing at both meant the one that returns the route toward what
        // they were first shown.
        if let detour, detour.reach <= (climb?.reach ?? .infinity) {
            rebuild(
                selected,
                through: selected.waypoints,
                refusing: selected.avoidances.filter { $0.id != detour.mark.avoidance }
            )
        } else if let climb {
            let hill = AvoidedHill(id: nextAvoidance, nodes: climb.mark.nodes, grade: climb.mark.grade)
            nextAvoidance += 1
            rebuild(selected, through: selected.waypoints, refusing: selected.avoidances + [hill])
        }
    }

    /// The marked stretch a tap fell nearest to, if it fell near one at all.
    private func nearest<Mark: RouteMark>(
        to point: CGPoint,
        among marks: [Mark],
        using proxy: MapProxy
    ) -> (reach: CGFloat, mark: Mark)? {
        marks
            .compactMap { mark in
                reach(from: point, to: mark.coordinates, using: proxy).map { (reach: $0, mark: mark) }
            }
            .min { $0.reach < $1.reach }
    }

    /// How near a tap fell to a stretch of route, in points, or `nil` if it
    /// fell outside reach of it.
    ///
    /// Measured on the screen rather than on the ground, because the screen is
    /// where the walker aimed. The same twenty meters is a comfortable miss
    /// across the city and a wild one down a block, and a reach stated in
    /// meters would make the hills easy to hit at one zoom and impossible at
    /// another.
    private func reach(
        from point: CGPoint,
        to stretch: [CLLocationCoordinate2D],
        using proxy: MapProxy
    ) -> CGFloat? {
        let drawn = stretch.compactMap { proxy.convert($0, to: .local) }
        guard let first = drawn.first else { return nil }

        // A stop is one point rather than a stretch, and measuring it as a
        // segment of no length would divide by nothing.
        let nearest = drawn.count > 1
            ? zip(drawn, drawn.dropFirst()).map { point.distance(toSegmentFrom: $0, to: $1) }.min() ?? .infinity
            : hypot(point.x - first.x, point.y - first.y)
        return nearest <= Self.tapReach ? nearest : nil
    }

    /// How far from a marked stretch a tap still counts as a tap on it.
    ///
    /// A fingertip covers about this much, and the lines being aimed at are a
    /// few points across. Drawn tighter, the hills would be a target the walker
    /// has to hunt for; drawn wider, walking the map would start rerouting it.
    private static let tapReach: CGFloat = 24

    /// Rebuild one route against a different set of the walker's own changes.
    ///
    /// Both whole lists are handed over rather than the change to them, because
    /// the route is rebuilt from the planned one every time. That is what lets
    /// any single stop or detour be taken back while the rest stand, and it is
    /// why the two kinds of change compose instead of fighting: a press and a
    /// tap both end up here, and the order they are applied in is fixed by the
    /// rebuild rather than by which the walker did first.
    private func rebuild(
        _ route: PlannedRoute,
        through waypoints: [Int],
        refusing hills: [AvoidedHill]
    ) {
        rerouting?.cancel()

        // Off the main actor for the same reason the first plan is: this is a
        // handful of searches, and they are being run against a map the walker
        // still has a finger on.
        let graph = graph
        let base = route.base
        let newStops = Set(waypoints).subtracting(route.waypoints)
        let newRefusals = Set(hills.map(\.id)).subtracting(route.avoidances.map(\.id))

        isRerouting = true
        rerouting = Task { @MainActor in
            defer { isRerouting = false }

            let rebuilt = await Task.detached(priority: .userInitiated) {
                PlannedRoute(base: base, waypoints: waypoints, avoidances: hills, in: graph)
            }.value

            guard !Task.isCancelled, routes.contains(where: { $0.id == rebuilt.id }) else { return }

            // Some points cannot be walked through and some hills have no way
            // round. In both cases the honest answer is to leave the route as
            // it was drawn and say so, rather than to accept the gesture and
            // change nothing visible.
            guard newStops.isSubset(of: Set(rebuilt.reached)) else {
                steeringProblem = "No walking route passes through there."
                return
            }
            guard newRefusals.isSubset(of: rebuilt.applied) else {
                steeringProblem = "There is no easier way around that hill nearby."
                return
            }

            steeringProblem = nil
            withAnimation(Theme.Motion.selection) {
                routes = routes.map { $0.id == rebuilt.id ? rebuilt : $0 }
            }
        }
    }

    /// Take a chosen place as one end of the trip.
    ///
    /// Setting one end always returns the app to setting the other, because a
    /// walker who has just named a start is on their way to naming a
    /// destination, and because a lingering mode is a mode someone has to
    /// remember they are in.
    private func select(_ place: Destination, as end: Endpoint) {
        switch end {
        case .start:
            origin = place
        case .destination:
            destination = place
        }

        editing = .destination
        dismissSearch()
        frame(coordinates: [start, destination?.coordinate].compactMap { $0 })
    }

    /// Hand the keyboard to one end of the trip and raise the search card.
    private func beginSearch(_ end: Endpoint) {
        query = ""
        search.clear()
        editing = end
        searching = end
    }

    private func dismissSearch() {
        query = ""
        search.clear()
        focused = nil
        searching = nil
    }

    // MARK: Camera

    /// Move the camera to hold every given point at a readable scale.
    ///
    /// Route choices cover the lower part of the map. In that state the camera
    /// reserves the same portion of its vertical field, so the route is fitted
    /// to the map that remains visible rather than centered behind the card.
    private func frame(
        coordinates: [CLLocationCoordinate2D],
        reservingRoutePanel: Bool = false
    ) {
        guard var region = MKCoordinateRegion(containing: coordinates) else { return }
        if reservingRoutePanel {
            region = region.reservingBottomFraction(Self.routePanelFraction)
        }
        withAnimation(Theme.Motion.camera) {
            camera = .region(region)
        }
    }

    /// The route chooser occupies roughly the lower two-fifths of a phone. The
    /// map still renders behind it; this value only changes the camera framing.
    private static let routePanelFraction = 0.40

    private static let coordinateLabel: CLLocationCoordinate2DFormatter = .init()
}

// MARK: - Search

private extension MapContainerView {
    /// The search card, and the dimmed map behind it.
    ///
    /// There is no permanent search bar. A field pinned to the top of the map is
    /// a third place to state a destination alongside the two that already say
    /// what they set, and it is the one furthest from the trip it belongs to --
    /// a walker who taps "Destination" at the foot of the screen should not have
    /// to travel to the opposite corner to type into it. So the field is the
    /// row: tapping either end of the trip brings that row up here and turns it
    /// into a search box.
    @ViewBuilder
    var searchLayer: some View {
        if let end = searching {
            ZStack(alignment: .top) {
                Color.clear
                    .ignoresSafeArea()
                    .contentShape(.rect)
                    .onTapGesture { dismissSearch() }

                VStack(spacing: 8) {
                    searchHeader(for: end)
                    searchCard(for: end, resultsLimit: 300)
                }
                .padding(.horizontal, Theme.Inset.card)
                .padding(.top, Theme.Inset.cardTop)
            }
        }
    }

    func searchHeader(for end: Endpoint) -> some View {
        HStack(spacing: 8) {
            Text(end.sheetTitle)
                .font(Theme.label(.footnote, weight: .medium))
                .foregroundStyle(Theme.secondaryText)

            Spacer(minLength: 8)

            // Backing out is not the act this screen is for, so it is drawn as
            // a way out rather than as something to press.
            Button("Cancel") { dismissSearch() }
                .font(Theme.label(.footnote, weight: .medium))
                .buttonStyle(.plain)
                .foregroundStyle(Theme.secondaryText)
        }
        .padding(.horizontal, 6)
    }

    /// Both ends of the trip, with the results list opening directly under
    /// whichever one is being filled.
    ///
    /// The list sits under the active row rather than in a fixed place, so
    /// searching for a start pushes the destination down and searching for a
    /// destination leaves it where it is. In both cases the row being typed into
    /// and the places on offer are adjacent, and the row is never the thing that
    /// moved out from under the walker's finger.
    func searchCard(for end: Endpoint, resultsLimit: CGFloat) -> some View {
        VStack(spacing: 0) {
            endpointField(.start, activeEnd: end)

            hairline

            if end == .start {
                resultSection(for: end, maxHeight: resultsLimit)
                hairline
            }

            endpointField(.destination, activeEnd: end)

            if end == .destination {
                hairline
                resultSection(for: end, maxHeight: resultsLimit)
            }
        }
        .background(Theme.panelBackground, in: .rect(cornerRadius: Theme.Radius.card))
        .overlay {
            RoundedRectangle(cornerRadius: Theme.Radius.card)
                .strokeBorder(Theme.hairline, lineWidth: 1 / displayScale)
        }
        .shadow(color: .black.opacity(0.45), radius: 20, y: 8)
    }

    /// One end of the trip inside the card: a search box while it is the one
    /// being filled, and what it currently holds while it is not.
    @ViewBuilder
    func endpointField(_ end: Endpoint, activeEnd: Endpoint) -> some View {
        let isActive = end == activeEnd

        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 10) {
                Image(systemName: symbol(for: end))
                    .font(Theme.label(.caption))
                    .foregroundStyle(fieldSymbolColor(for: end, isActive: isActive))
                    .frame(width: 16)

                Text(end.title)
                    .font(Theme.label(.caption, weight: .semibold))
                    .foregroundStyle(isActive ? Theme.accent : Theme.secondaryText)

                Spacer(minLength: 8)
            }

            Group {
                if isActive {
                    searchBox(for: end)
                } else {
                    Text(detail(for: end))
                        .font(detailFont(for: end))
                        .foregroundStyle(isSet(end) ? Theme.primaryText : Theme.tertiaryText)
                        .lineLimit(1)
                        .truncationMode(.tail)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
            }
            .padding(.leading, 26)
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .contentShape(.rect)
        .onTapGesture {
            guard !isActive else { return }
            beginSearch(end)
        }
    }

    func searchBox(for end: Endpoint) -> some View {
        HStack(spacing: 8) {
            Image(systemName: "magnifyingglass")
                .font(Theme.label(.footnote, weight: .medium))
                .foregroundStyle(Theme.secondaryText)

            TextField(end.prompt, text: $query)
                .textFieldStyle(.plain)
                .font(Theme.label(.subheadline))
                .foregroundStyle(Theme.primaryText)
                .autocorrectionDisabled()
                .textInputAutocapitalization(.words)
                .submitLabel(.search)
                .focused($focused, equals: end)

            if search.isSearching {
                ProgressView().controlSize(.small)
            } else if !query.isEmpty {
                Button {
                    query = ""
                    search.clear()
                } label: {
                    Image(systemName: "xmark.circle.fill")
                        .font(Theme.label(.footnote))
                        .foregroundStyle(Theme.tertiaryText)
                }
                .buttonStyle(.plain)
                .accessibilityLabel("Clear the search")
            }
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 9)
        .background(Theme.raised, in: .rect(cornerRadius: Theme.Radius.control))
    }

    /// What the card offers under the active field: matches, an explanation for
    /// why there are none, or -- before anything has been typed -- the other way
    /// of answering the question.
    @ViewBuilder
    func resultSection(for end: Endpoint, maxHeight: CGFloat) -> some View {
        if !search.results.isEmpty {
            ScrollView {
                VStack(spacing: 0) {
                    ForEach(search.results) { result in
                        Button {
                            select(result, as: end)
                        } label: {
                            resultRow(result)
                        }
                        .buttonStyle(.plain)

                        if result.id != search.results.last?.id {
                            hairline.padding(.leading, 14)
                        }
                    }
                }
            }
            // Sized to the matches, not to the room available. A scroll view
            // left to itself takes every point it is offered, which would leave
            // one result sitting at the top of a card the height of the screen.
            .frame(maxHeight: maxHeight)
            .scrollBounceBehavior(.basedOnSize)
            .scrollDismissesKeyboard(.never)
        } else {
            Text(searchHint(for: end))
                .font(Theme.label(.footnote))
                .foregroundStyle(Theme.tertiaryText)
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.horizontal, 14)
                .padding(.vertical, 12)
        }
    }

    func resultRow(_ result: Destination) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(result.name)
                .font(Theme.label(.subheadline, weight: .medium))
                .foregroundStyle(Theme.primaryText)
            if let address = result.address {
                Text(address)
                    .font(Theme.label(.footnote))
                    .foregroundStyle(Theme.secondaryText)
                    .lineLimit(1)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.horizontal, 14)
        .padding(.vertical, 10)
        .contentShape(.rect)
    }

    /// Why the list is empty, in the walker's terms.
    ///
    /// Emptiness has four causes and only one of them is a failure: nothing has
    /// been typed, not enough has been typed, the answer is still coming, or
    /// there is genuinely no such place here. Saying "no matches" for the first
    /// three would accuse the walker of a mistake they have not made yet.
    func searchHint(for end: Endpoint) -> String {
        let typed = query.trimmingCharacters(in: .whitespacesAndNewlines)

        if typed.isEmpty {
            return end == .start
                ? "Type a place, or cancel and press and hold the map to set a start."
                : "Type a place, or cancel and press and hold the map to drop a pin."
        }
        if typed.count < DestinationSearch.shortestUsefulQuery {
            return "Keep typing…"
        }
        if search.isSearching {
            return "Searching…"
        }
        return search.message ?? "No matches in San Francisco."
    }

    /// A rule a device pixel thick. The surfaces are separated from the map and
    /// from each other by these alone -- no borders, no shadows on anything
    /// anchored to an edge -- so that the map keeps the screen and the panels
    /// read as edges of it rather than as windows floating over it.
    var hairline: some View {
        Rectangle()
            .fill(Theme.hairline)
            .frame(height: 1 / displayScale)
    }
}

// MARK: - Trip summary

private extension MapContainerView {
    /// The two ends of the trip as they currently stand, and what is missing.
    ///
    /// Both ends are editable and both are addressed the same way. The start
    /// defaults to wherever the walker is, because that is what it is nearly
    /// every time -- but a walk being planned from the sofa for tomorrow starts
    /// somewhere else, and there is no reason the app should only be able to
    /// answer the question from where it is standing.
    ///
    /// Until there are routes to show, this strip is the only evidence that a
    /// press or a search actually landed, so it says what was captured rather
    /// than only prompting for what was not.
    @ViewBuilder
    var tripSummary: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 10) {
                // Leading, where it is under the thumb that just tapped a row
                // and where it lines up with the two symbols it exchanges,
                // rather than stranded on the far edge opposite them.
                swapButton

                VStack(alignment: .leading, spacing: 8) {
                    endpoint(
                        .start,
                        trailing: origin == nil ? nil : "Use my location"
                    )

                    hairline

                    endpoint(
                        .destination,
                        trailing: destination == nil ? nil : "Clear"
                    )
                }
            }

            if let notice = steeringProblem ?? rejectedPin ?? routingProblem {
                Text(notice)
                    .font(Theme.label(.footnote))
                    .foregroundStyle(Theme.secondaryText)
            }
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 12)
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    // MARK: Endpoint state, shared by the panel and the search card

    /// The mark beside an end of the trip. The start changes symbol with its
    /// meaning: a heading arrow while it follows the walker, a fixed dot once
    /// they have named somewhere.
    func symbol(for end: Endpoint) -> String {
        switch end {
        case .start: origin == nil ? "location.fill" : "smallcircle.filled.circle"
        case .destination: "flag.fill"
        }
    }

    /// The walker's own position is the now-marker on the map, and the accent
    /// belongs to it. A start they typed is a place like any other, so it is
    /// drawn like one.
    func tint(for end: Endpoint) -> Color {
        switch end {
        case .start: origin == nil ? Theme.accent : Theme.destination
        case .destination: Theme.destination
        }
    }

    func isSet(_ end: Endpoint) -> Bool {
        switch end {
        case .start: start != nil
        case .destination: destination != nil
        }
    }

    func detail(for end: Endpoint) -> String {
        switch end {
        case .start: startDetail
        case .destination:
            destination.map { $0.address ?? $0.name }
                ?? "Tap to search, or press and hold the map"
        }
    }

    /// The face the line under an endpoint is set in.
    ///
    /// A named place reads as a sentence and a bare position reads as a pair of
    /// numbers, so an address gets the reading face and a latitude and longitude
    /// get the monospaced one. Setting "221 Kearny St, San Francisco" in figures
    /// spaces the words like a table and looks like a rendering fault.
    func detailFont(for end: Endpoint) -> Font {
        let named = switch end {
        case .start: origin?.isNamed ?? false
        case .destination: destination?.isNamed ?? false
        }
        return named || !isSet(end) ? Theme.label(.footnote) : Theme.figure(.footnote)
    }

    func fieldSymbolColor(for end: Endpoint, isActive: Bool) -> Color {
        if isActive { return Theme.accent }
        return isSet(end) ? tint(for: end) : Theme.tertiaryText
    }

    /// Turns the trip around.
    ///
    /// Worth a button of its own because the walk home is the same trip as the
    /// walk there and is not the same route: FlatPath prices climbs, so the
    /// return leg of an uphill trip is a different set of options entirely.
    /// Retyping both ends to see them would be the app asking the walker to do
    /// its work.
    @ViewBuilder
    var swapButton: some View {
        Button {
            withAnimation(Theme.Motion.selection) { swapEndpoints() }
        } label: {
            Image(systemName: "arrow.up.arrow.down")
                .font(Theme.label(.subheadline, weight: .semibold))
                .frame(width: 34, height: 34)
                .contentShape(.rect)
        }
        .buttonStyle(.plain)
        .foregroundStyle(canSwap ? Theme.secondaryText : Theme.tertiaryText)
        .disabled(!canSwap)
        .accessibilityLabel("Swap start and destination")
    }

    /// Swapping needs somewhere for each end to land. With no destination set
    /// and no fix to fall back on there is nothing to exchange.
    var canSwap: Bool {
        destination != nil || origin != nil
    }

    func swapEndpoints() {
        // The start has to be made explicit before it can become a destination:
        // "wherever I am" is a rule for one end of a trip, not a place.
        let newDestination = origin ?? myLocation
        let newOrigin = destination

        origin = newOrigin
        destination = newDestination
        editing = .destination
        rejectedPin = nil
        dismissSearch()
        frame(coordinates: [start, destination?.coordinate].compactMap { $0 })
    }

    /// Where the walker is, as a place that can be named and swapped, or `nil`
    /// when there is no fix worth using.
    var myLocation: Destination? {
        guard let coordinate = location.coordinate, ServiceArea.contains(coordinate) else {
            return nil
        }
        return Destination(
            name: "My location",
            address: Self.coordinateLabel.string(from: coordinate),
            coordinate: coordinate,
            isNamed: false
        )
    }

    var startDetail: String {
        if let origin {
            origin.address ?? origin.name
        } else if let start {
            Self.coordinateLabel.string(from: start)
        } else if let failure = location.failure {
            failure
        } else if location.coordinate != nil {
            "You are outside San Francisco — tap to set a start"
        } else {
            "Waiting for your location…"
        }
    }

    /// One end of the trip: what it is now, and a way to change it.
    ///
    /// The whole row is the control. Tapping it says which end the next search
    /// or long press is for, which is the only state the two ends need between
    /// them -- there is no separate mode to leave, because choosing something
    /// ends it.
    @ViewBuilder
    func endpoint(_ end: Endpoint, trailing: String? = nil) -> some View {
        // Which end a press on the map would set. Worth marking, because the
        // gesture is silent about its target and the walker is owed a way to
        // tell before they use it.
        let isTargeted = editing == end
        let isSet = isSet(end)

        HStack(alignment: .firstTextBaseline, spacing: 10) {
            Image(systemName: symbol(for: end))
                .font(Theme.label(.caption))
                .foregroundStyle(isSet ? tint(for: end) : Theme.tertiaryText)
                .frame(width: 16)

            Button {
                beginSearch(end)
            } label: {
                VStack(alignment: .leading, spacing: 2) {
                    Text(end.title)
                        .font(Theme.label(.caption, weight: .semibold))
                        .foregroundStyle(isTargeted ? Theme.accent : Theme.secondaryText)
                    // A set endpoint is a place or a coordinate, which reads as
                    // a figure; an unset one is a sentence asking for one.
                    Text(detail(for: end))
                        .font(detailFont(for: end))
                        .foregroundStyle(isSet ? Theme.primaryText : Theme.secondaryText)
                        .multilineTextAlignment(.leading)
                        .lineLimit(2)
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .contentShape(.rect)
            }
            .buttonStyle(.plain)

            if let trailing {
                // Not the accent: clearing an end undoes a choice rather than
                // making one, and emerald is spoken for.
                Button(trailing) { clear(end) }
                    .font(Theme.label(.footnote))
                    .buttonStyle(.plain)
                    .foregroundStyle(Theme.secondaryText)
                    .fixedSize()
            }
        }
    }

    func clear(_ end: Endpoint) {
        switch end {
        case .start:
            origin = nil
        case .destination:
            destination = nil
        }
        rejectedPin = nil
        frame(coordinates: [start, destination?.coordinate].compactMap { $0 })
    }
}

// MARK: - Routes

private extension MapContainerView {
    /// The chooser and the trip strip, as one sheet floating over the map.
    ///
    /// The strip stays put once routes arrive rather than being replaced by
    /// them: it holds the only way to clear a destination, and it is where the
    /// reason for an empty list gets explained.
    ///
    /// Floating rather than anchored. A full-width opaque panel butted against
    /// the bottom of the map ends the map at a hard horizontal seam — the basemap
    /// is atmospheric and the panel is flat, so the two read as separate screens
    /// stacked rather than one surface. Inset from all three edges, rounded, and
    /// blurred over the ground it covers, the same content reads as something
    /// laid on the map, which is what it is.
    var tripPanel: some View {
        VStack(spacing: 0) {
            if !routes.isEmpty {
                detourControl
                hairline
                RouteCardsView(routes: routes.map(\.option), selection: $selectedRoute)
                hairline
            }

            // The action slot: the spinner while routes are being found, the
            // button to walk one once they are. Both occupy the same strip, so
            // the wait happens where the walker is already looking for the thing
            // they are waiting for.
            if isRouting || selectedRoute != nil {
                actionRow
                hairline
            }

            tripSummary
        }
        .floatingSurface()
        .padding(.horizontal, Theme.Inset.sheet)
        .padding(.bottom, Theme.Inset.sheet)
        .animation(Theme.Motion.selection, value: isRouting)
    }

    /// How much longer than the most direct option a flatter one may take.
    ///
    /// Sits above the cards because it decides what is on them. Widening it can
    /// turn one option into three -- the flat way round a hill often exists and
    /// is simply further than the walker had so far said they would go -- and
    /// narrowing it collapses them back, which is the clearest way to show that
    /// the choice was there all along and had a price.
    /// Drawn rather than left to `.segmented`, whose track and knob are system
    /// grays that cannot be told to join the palette. At this size the control
    /// is a track, three labels and a moving fill, and drawing it is cheaper
    /// than the one gray rectangle it saves.
    var detourControl: some View {
        HStack(spacing: 12) {
            Text("Detour allowed")
                .font(Theme.label(.footnote))
                .foregroundStyle(Theme.secondaryText)

            Spacer(minLength: 8)

            HStack(spacing: 2) {
                ForEach(DetourTolerance.allCases) { tolerance in
                    let isChosen = tolerance == detour

                    Button {
                        withAnimation(Theme.Motion.selection) { detour = tolerance }
                    } label: {
                        Text(tolerance.label)
                            .font(Theme.figure(.footnote, weight: isChosen ? .semibold : .regular))
                            .foregroundStyle(isChosen ? Theme.primaryText : Theme.secondaryText)
                            .frame(maxWidth: .infinity)
                            .padding(.vertical, 6)
                            .background {
                                // Not the accent. This picks how hard to look
                                // for a flat route, not which route was chosen,
                                // and emerald answers only the second question.
                                if isChosen {
                                    RoundedRectangle(cornerRadius: Theme.Radius.segment)
                                        .fill(Theme.raised)
                                        .matchedGeometryEffect(id: "detour", in: detourTrack)
                                }
                            }
                            .contentShape(.rect)
                    }
                    .buttonStyle(.plain)
                    .accessibilityAddTraits(isChosen ? [.isButton, .isSelected] : .isButton)
                }
            }
            .padding(3)
            // The track itself is not filled. On a panel this light a second
            // opaque tone under the segments would be a box drawn around three
            // words; the hairline says "these three belong together" and the one
            // filled segment says which is chosen.
            .overlay {
                RoundedRectangle(cornerRadius: Theme.Radius.control)
                    .strokeBorder(Theme.hairline, lineWidth: 1 / displayScale)
            }
            .frame(maxWidth: 230)
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 10)
    }

    /// Enters turn-by-turn on the selected route, or waits for one to exist.
    ///
    /// Starting is deliberately a second act rather than something a card tap
    /// does on its own. Tapping between the cards is how the walker compares the
    /// routes -- each tap redraws one in the accent color so it can be looked at
    /// on the map -- and a tap that launched navigation would make the
    /// comparison the app exists for impossible to perform without leaving it
    /// three times.
    ///
    /// The spinner lives here rather than beside the destination it was set off
    /// by. A walker who has named both ends is waiting for one thing, and it is
    /// this: progress belongs in the place the answer will appear, not tucked
    /// into a corner of the field that asked the question.
    @ViewBuilder
    var actionRow: some View {
        if isRouting {
            // The spinner alone. Naming what it is doing would be a caption on
            // a wait of a few hundred milliseconds, and the strip it sits in has
            // already said what is being waited for.
            ProgressView()
                .controlSize(.small)
                .tint(Theme.accent)
                .frame(maxWidth: .infinity, minHeight: Self.actionHeight)
                .transition(.opacity)
                .accessibilityLabel("Finding routes")

        } else if let selected = routes.first(where: { $0.id == selectedRoute }) {
            Button {
                navigating = selected
            } label: {
                Label("Start \(selected.option.name)", systemImage: "figure.walk")
                    .font(Theme.label(.subheadline, weight: .semibold))
                    .frame(maxWidth: .infinity, minHeight: Self.actionHeight)
                    .contentShape(.rect)
            }
            .buttonStyle(.plain)
            // Emerald, as the one action that commits to a route -- the same
            // meaning the accent carries on the line and on the chosen card.
            .foregroundStyle(Theme.accent)
            .transition(.opacity)
        }
    }

    /// One height for both states of the action strip, so the panel does not
    /// change depth when the spinner gives way to the button and the cards above
    /// stay where the walker last read them.
    static var actionHeight: CGFloat { 44 }

    /// What a set of routes is a function of. Planning restarts when this
    /// changes, and only then.
    ///
    /// Deliberately not the start coordinate itself. CoreLocation delivers a new
    /// fix every few meters, and re-planning on each one would replace the
    /// routes under the walker's finger — including, every time, the selection
    /// they had just made. The arrival of the first fix does have to trigger a
    /// plan, though, since a destination can be set before there is anywhere to
    /// route from.
    struct PlanRequest: Equatable {
        let origin: Destination.ID?
        let destination: Destination.ID?
        let hasStart: Bool
        let detour: DetourTolerance
    }

    var planRequest: PlanRequest {
        PlanRequest(
            origin: origin?.id,
            destination: destination?.id,
            hasStart: start != nil,
            detour: detour
        )
    }

    /// Find the routes for the current pair of endpoints, if there is one.
    func planRoutes() async {
        // Whatever a walker refused on the last set of routes was a statement
        // about those routes. A new pair of endpoints is a new walk, and it
        // arrives with nothing refused on it.
        steeringProblem = nil
        rerouting?.cancel()
        isRerouting = false

        guard let destination, let start else {
            discardRoutes()
            routingProblem = nil
            return
        }

        isRouting = true
        defer { isRouting = false }

        // Off the main actor, then back: the search is short but not free, and
        // it is competing with a map the walker is still moving.
        let graph = graph
        let detour = detour
        let plan = await Task.detached(priority: .userInitiated) {
            RoutePlan(from: start, to: destination.coordinate, in: graph, detour: detour)
        }.value

        // A newer request cancelled this one — its own result is the current
        // one, and writing this stale plan over it would win the race by
        // finishing second.
        guard !Task.isCancelled else { return }

        switch plan {
        case .routes(let found):
            withAnimation(Theme.Motion.selection) {
                routes = found
                // The first option is the most direct one offered, the closest
                // thing to what another maps app would have given. Selecting it
                // makes every other card a visible trade against a familiar
                // answer.
                selectedRoute = found.first?.id
            }
            routingProblem = nil
            frame(coordinates: found.flatMap(\.coordinates), reservingRoutePanel: true)

        case .startOffNetwork:
            discardRoutes()
            routingProblem = "There is no walkable street near where you are."

        case .destinationOffNetwork:
            discardRoutes()
            routingProblem = "There is no walkable street near that destination."

        case .unreachable:
            discardRoutes()
            routingProblem = "No walking route connects those two points."
        }
    }

    func discardRoutes() {
        routes = []
        selectedRoute = nil
        steeringProblem = nil
    }

}

/// One end of a trip, for saying which end is being set.
private enum Endpoint: Hashable {
    case start
    case destination

    /// What the row is called, in the panel and in the search card alike.
    var title: String {
        switch self {
        case .start: "Start"
        case .destination: "Destination"
        }
    }

    /// What the search field asks for while this end is the one being filled.
    var prompt: String {
        switch self {
        case .start: "Search for a starting point"
        case .destination: "Search San Francisco"
        }
    }

    /// Said above the card, so that a list of places is never ambiguous about
    /// which end of the trip choosing one would set.
    var sheetTitle: String {
        switch self {
        case .start: "Where are you starting?"
        case .destination: "Where are you going?"
        }
    }
}

/// Something drawn along a route that a tap can land on.
///
/// The hills and the walker's own detours are hit-tested the same way and are
/// otherwise unrelated, so what they share is stated here rather than being
/// written twice at the two call sites.
private protocol RouteMark: Identifiable {
    var coordinates: [CLLocationCoordinate2D] { get }
}

/// A route option with its geometry already resolved, and the walker's own
/// changes to it.
///
/// The map needs a route as coordinates, and the graph stores it as node
/// indices. Converting once when the route is found, rather than in the view
/// body, keeps a few hundred lookups per polyline out of every render pass. The
/// steep stretches are found in the same pass and for the same reason.
///
/// Two routes are held rather than one. `base` is what the planner offered, and
/// it never changes; `option` is what the walker is actually being shown, which
/// is `base` with a way round every hill they have refused. Keeping the
/// original is what makes those refusals reversible: undoing one is dropping it
/// from a list and rebuilding, not unpicking an edit made in place.
private struct PlannedRoute: Identifiable {
    /// The route as planned, before anything was refused on it.
    let base: RouteOption

    /// Points on the map the walker has pressed to steer this route through,
    /// in the order the route reaches them.
    let waypoints: [Int]

    /// The hills the walker has sent this route around, in the order they
    /// asked.
    let avoidances: [AvoidedHill]

    /// The route as drawn and as walked: `base`, steered and detoured.
    ///
    /// Everything downstream reads this and nothing else, so the cards report
    /// what the changed walk costs and turn-by-turn gives directions along the
    /// road the walker actually chose.
    let option: RouteOption

    /// Which of `waypoints` the city could route through. A point with no way
    /// through leaves the route as it was, and this is how the view knows to
    /// say so instead of accepting the press and changing nothing.
    let reached: [Int]

    /// Which of `avoidances` the city could honour. A hill with no way round
    /// leaves the route as it was, and this is how the view knows to say so.
    let applied: Set<AvoidedHill.ID>

    let coordinates: [CLLocationCoordinate2D]

    /// The parts of the route that climb hard enough to be worth marking.
    let climbs: [Climb]

    /// The stretches that are on the route because the walker refused a hill.
    let detours: [Detour]

    /// The waypoints the route reaches, as points to draw and to tap.
    let stops: [Stop]

    /// The route drawn as consecutive runs, each a shade deeper than the last.
    ///
    /// Consecutive rather than overlaid: run `i` ends on the coordinate run
    /// `i + 1` begins on, so the joins are shared points and the line has no
    /// gaps in it at any zoom.
    let shades: [Shade]

    /// The identity of the option this came from, which the detours do not
    /// change. A route the walker has bent around two hills is still the card
    /// they selected, and taking its id from the planned route is what keeps
    /// the selection on it across a rebuild.
    var id: RouteOption.ID { base.id }

    /// One solid run of the selected route.
    struct Shade: Identifiable {
        /// Its position along the route, which is unique within it.
        let id: Int
        let color: Color
        let coordinates: [CLLocationCoordinate2D]
    }

    /// Cut the route into runs and shade each by how far along it sits.
    private static func shades(along coordinates: [CLLocationCoordinate2D]) -> [Shade] {
        let spans = coordinates.count - 1
        guard spans > 1 else {
            return coordinates.isEmpty
                ? []
                : [Shade(id: 0, color: Theme.routeShade(at: 0), coordinates: coordinates)]
        }

        let runs = min(Theme.routeShadeCount, spans)
        return (0 ..< runs).map { run in
            // Integer arithmetic so the runs tile the route exactly: each one
            // ends on the index the next begins on, with no coordinate dropped
            // between them and none drawn twice.
            let from = run * spans / runs
            let through = (run + 1) * spans / runs
            return Shade(
                id: run,
                color: Theme.routeShade(at: (Double(run) + 0.5) / Double(runs)),
                coordinates: Array(coordinates[from ... through])
            )
        }
    }

    /// A run of consecutive blocks in the same steepness band.
    ///
    /// Runs rather than blocks: a hill is walked as one stretch, and drawing it
    /// as a dozen separate marks would turn one wave into a row of ticks. It is
    /// also what the walker refuses when they tap it — a hill is the thing they
    /// object to, and objecting to one block of it would leave them tapping the
    /// same slope four times.
    struct Climb: RouteMark {
        /// Where the run starts along the route, which is unique within it.
        let id: Int
        let grade: Grade

        /// How far along the route the run's middle sits, from 0 to 1, so the
        /// wave can be drawn in the shade the line itself has there.
        let along: Double

        /// The graph nodes the run covers, which is what a refusal is stated
        /// in: the map draws coordinates, but the router needs somewhere to
        /// route around.
        let nodes: [Int]

        let coordinates: [CLLocationCoordinate2D]
    }

    /// A point the walker pressed, which the route now passes through.
    ///
    /// Drawn as a bare white dot: it is not a place, it has no name and nothing
    /// to say, and the only thing it marks is that the line goes through here
    /// because someone said so. Tapping it takes it back.
    struct Stop: RouteMark {
        /// The graph node it snapped to, which is unique along a route and is
        /// also what the router is told to pass through.
        let id: Int
        let coordinate: CLLocationCoordinate2D

        /// One point, so that a stop is hit-tested by the same code as the
        /// stretches.
        var coordinates: [CLLocationCoordinate2D] { [coordinate] }
    }

    /// A stretch of route the walker's own refusal put there.
    ///
    /// Tapping one puts back the hill it was found to avoid, so it carries the
    /// avoidance it belongs to rather than a copy of what it replaced.
    struct Detour: RouteMark {
        /// Where the stretch starts along the route, which is unique within it.
        /// Not the avoidance's own id: one detour can be drawn in two pieces
        /// where it rejoins the road it replaced for a block.
        let id: Int
        let avoidance: AvoidedHill.ID
        let coordinates: [CLLocationCoordinate2D]
    }

    /// The walker's two kinds of change, applied in the order they have to be.
    ///
    /// Steering first, then refusing hills. A waypoint says which way round the
    /// walk goes and so decides what ground there is to object to; a refusal is
    /// a local objection to ground the route already covers. Doing it the other
    /// way would find a way around a hill on a route the waypoint is about to
    /// replace.
    init(
        base: RouteOption,
        waypoints: [Int] = [],
        avoidances: [AvoidedHill] = [],
        in graph: WalkingGraph
    ) {
        let steered = RouteVia.route(base, through: waypoints, in: graph)
        let viaRoute = RouteOption(
            id: base.id,
            name: base.name,
            nodes: steered.nodes,
            edges: steered.edges,
            metrics: RouteMetrics(edges: steered.edges, in: graph),
            cost: base.cost
        )
        let detoured = HillDetour.apply(avoidances, to: viaRoute, in: graph)
        let coordinates = detoured.nodes.map { node in
            CLLocationCoordinate2D(latitude: graph.latitudes[node], longitude: graph.longitudes[node])
        }

        self.base = base
        self.waypoints = waypoints
        self.avoidances = avoidances
        self.coordinates = coordinates
        reached = steered.reached
        applied = detoured.applied

        // The name and the position on the card list survive: this is still the
        // option the walker selected, however far around a hill it now goes.
        option = RouteOption(
            id: base.id,
            name: base.name,
            nodes: detoured.nodes,
            edges: detoured.edges,
            metrics: RouteMetrics(edges: detoured.edges, in: graph),
            cost: base.cost
        )

        stops = steered.reached.map { node in
            Stop(
                id: node,
                coordinate: CLLocationCoordinate2D(
                    latitude: graph.latitudes[node],
                    longitude: graph.longitudes[node]
                )
            )
        }

        shades = Self.shades(along: coordinates)

        let spans = max(1, detoured.edges.count)
        climbs = Self.runs(across: detoured.edges.count) { position in
            let grade = Grade(
                rise: Double(graph.edgeDeltaElevation[detoured.edges[position]]),
                over: Double(graph.edgeLength[detoured.edges[position]])
            )
            return grade.isWorthWarningAbout ? grade : nil
        }
        .map { run in
            Climb(
                id: run.nodes.lowerBound,
                grade: run.mark,
                along: Double(run.nodes.lowerBound + run.nodes.upperBound) / 2 / Double(spans),
                nodes: Array(detoured.nodes[run.nodes]),
                coordinates: Array(coordinates[run.nodes])
            )
        }

        detours = Self.runs(across: detoured.edges.count) { detoured.detouredBy[$0] }
            .map { run in
                Detour(
                    id: run.nodes.lowerBound,
                    avoidance: run.mark,
                    coordinates: Array(coordinates[run.nodes])
                )
            }
    }

    /// Runs of neighbouring edges that agree about a mark, as node ranges.
    ///
    /// Both things drawn along a route — the hills and the walker's detours —
    /// are runs of edges that share something, and both are wanted as node
    /// ranges because that is what a polyline is drawn from. Edge `i` joins
    /// nodes `i` and `i + 1`, so a run of edges `first ... last` is bounded by
    /// the nodes `first` and `last + 1`.
    private static func runs<Mark: Equatable>(
        across edges: Int,
        markedBy mark: (Int) -> Mark?
    ) -> [(nodes: ClosedRange<Int>, mark: Mark)] {
        var runs: [(nodes: ClosedRange<Int>, mark: Mark)] = []
        var position = 0

        while position < edges {
            guard let found = mark(position) else {
                position += 1
                continue
            }

            var last = position
            while last + 1 < edges, mark(last + 1) == found { last += 1 }

            runs.append((nodes: position ... last + 1, mark: found))
            position = last + 1
        }

        return runs
    }
}

/// What one planning attempt produced.
///
/// The three failures are separated because they call for different responses
/// from the walker: move, choose somewhere else, or accept that the two points
/// are not connected by anything walkable.
private enum RoutePlan {
    case routes([PlannedRoute])
    case startOffNetwork
    case destinationOffNetwork
    case unreachable

    init(
        from start: CLLocationCoordinate2D,
        to destination: CLLocationCoordinate2D,
        in graph: WalkingGraph,
        detour: DetourTolerance
    ) {
        // Both ends are snapped to the network before anything is searched. A
        // coordinate from CoreLocation or from a search result almost never
        // lands on a node exactly, and the graph is the only thing that can say
        // whether "almost" is close enough to route from.
        guard let origin = graph.nearestNode(toLatitude: start.latitude, longitude: start.longitude) else {
            self = .startOffNetwork
            return
        }
        guard let goal = graph.nearestNode(toLatitude: destination.latitude, longitude: destination.longitude) else {
            self = .destinationOffNetwork
            return
        }

        let options = RouteOptions.between(
            start: origin, destination: goal, in: graph, tolerance: detour
        )
        guard !options.isEmpty else {
            self = .unreachable
            return
        }

        self = .routes(options.map { PlannedRoute(base: $0, in: graph) })
    }
}

// MARK: - Markers

/// A point the walker pressed to steer the route through.
///
/// A bare dot, with no label and no symbol. Every other mark on this map stands
/// for something the app knows — where you are, where you are going — and says
/// so. This one stands for nothing but the walker's own intention, which they do
/// not need told back to them; a flag and the words "Dropped pin" made it look
/// like a destination, which is the one thing it is not.
///
/// White rather than emerald: emerald is the route, and a stop is a hand on the
/// route rather than a part of it. The ring is the map's own background, the
/// same way the walker's marker is drawn, so the dot stays legible where it sits
/// on top of the line.
private struct StopMarker: View {
    var body: some View {
        Circle()
            .fill(Theme.destination)
            .overlay(Circle().stroke(Theme.background, lineWidth: 2.5))
            .frame(width: 14, height: 14)
            .shadow(color: .black.opacity(0.5), radius: 3)
    }
}

/// The walker's own position, drawn rather than left to `UserAnnotation` so that
/// it reads as part of the trip alongside the destination flag, not as an
/// unrelated system dot that happens to share the map.
private struct WalkerMarker: View {
    var body: some View {
        Circle()
            .fill(Theme.accent)
            .overlay(Circle().stroke(Theme.background, lineWidth: 3))
            .frame(width: 18, height: 18)
            .shadow(color: .black.opacity(0.5), radius: 3)
    }
}

// MARK: - Geometry helpers

private extension CGPoint {
    /// How far this point lies from a line segment, which is what a tap on a
    /// polyline is asking. Measuring to the drawn vertices instead would let a
    /// tap in the middle of a long straight block miss the block.
    func distance(toSegmentFrom start: CGPoint, to end: CGPoint) -> CGFloat {
        let run = CGPoint(x: end.x - start.x, y: end.y - start.y)
        let lengthSquared = run.x * run.x + run.y * run.y
        guard lengthSquared > 0 else { return hypot(x - start.x, y - start.y) }

        // Clamped, so a tap beyond either end measures to that end rather than
        // to the infinite line the segment sits on.
        let along = min(max(((x - start.x) * run.x + (y - start.y) * run.y) / lengthSquared, 0), 1)
        return hypot(x - (start.x + run.x * along), y - (start.y + run.y * along))
    }
}

private extension MKCoordinateRegion {
    /// Expands and shifts a region so its original contents are centered in the
    /// upper, unobscured part of a full-screen map.
    func reservingBottomFraction(_ fraction: Double) -> MKCoordinateRegion {
        let reserved = min(max(fraction, 0), 0.8)
        let visible = 1 - reserved
        let expandedLatitude = span.latitudeDelta / visible

        return MKCoordinateRegion(
            center: CLLocationCoordinate2D(
                latitude: center.latitude - expandedLatitude * reserved / 2,
                longitude: center.longitude
            ),
            span: MKCoordinateSpan(
                latitudeDelta: expandedLatitude,
                longitudeDelta: span.longitudeDelta
            )
        )
    }

    /// The smallest comfortably readable region holding every coordinate, or
    /// `nil` for none at all.
    ///
    /// The span is padded past the exact bounding box so the outermost points do
    /// not sit against the screen edge, and floored so that a single point — or
    /// two a few meters apart — produces a street-level view instead of zooming
    /// to a span of zero.
    init?(containing coordinates: [CLLocationCoordinate2D]) {
        guard let first = coordinates.first else { return nil }

        var minimum = first
        var maximum = first
        for coordinate in coordinates.dropFirst() {
            minimum.latitude = min(minimum.latitude, coordinate.latitude)
            minimum.longitude = min(minimum.longitude, coordinate.longitude)
            maximum.latitude = max(maximum.latitude, coordinate.latitude)
            maximum.longitude = max(maximum.longitude, coordinate.longitude)
        }

        /// Roughly four city blocks, the tightest useful walking view.
        let minimumSpan = 0.004
        let padding = 1.45

        self.init(
            center: CLLocationCoordinate2D(
                latitude: (minimum.latitude + maximum.latitude) / 2,
                longitude: (minimum.longitude + maximum.longitude) / 2
            ),
            span: MKCoordinateSpan(
                latitudeDelta: max(minimumSpan, (maximum.latitude - minimum.latitude) * padding),
                longitudeDelta: max(minimumSpan, (maximum.longitude - minimum.longitude) * padding)
            )
        )
    }
}

/// Formats a coordinate for display. Held onto rather than rebuilt per call
/// because the trip strip re-renders on every position update.
private struct CLLocationCoordinate2DFormatter {
    private let degrees: NumberFormatter = {
        let formatter = NumberFormatter()
        formatter.numberStyle = .decimal
        formatter.minimumFractionDigits = 5
        formatter.maximumFractionDigits = 5
        return formatter
    }()

    func string(from coordinate: CLLocationCoordinate2D) -> String {
        let latitude = degrees.string(from: coordinate.latitude as NSNumber) ?? "—"
        let longitude = degrees.string(from: coordinate.longitude as NSNumber) ?? "—"
        return "\(latitude), \(longitude)"
    }
}

#Preview {
    if let graph = try? GraphLoader.loadBundledGraph() {
        MapContainerView(graph: graph)
            .preferredColorScheme(.dark)
            .tint(Theme.accent)
    } else {
        Text("The walking map is missing from this build.")
    }
}
