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
//  Once both ends exist the routes are found here too, off the main actor: three
//  searches across a city-sized graph are milliseconds of work, but they are
//  milliseconds spent between two frames, and the map is being panned while they
//  run.

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
    @FocusState private var isSearchFocused: Bool

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

    /// Why there are no routes, when the reason is worth showing.
    @State private var routingProblem: String?

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
                    MapPolyline(coordinates: selected.coordinates)
                        .stroke(Theme.accent, style: Theme.Line.stroke(Theme.Line.selected))

                    // Only the chosen route is marked for steepness. Warning
                    // every line at once would say nothing about the choice
                    // between them, and the walker is comparing routes here --
                    // what they need to see is which parts of *this* one climb.
                    ForEach(selected.climbs) { climb in
                        MapPolyline(coordinates: climb.coordinates)
                            .stroke(
                                Theme.warning(for: climb.grade) ?? Theme.accent,
                                style: Theme.Line.stroke(Theme.Line.warning)
                            )
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
            .mapControls {
                MapCompass()
                MapScaleView()
            }
            .gesture(dropPin(using: proxy))
        }
        .safeAreaInset(edge: .top, spacing: 0) { searchPanel }
        .safeAreaInset(edge: .bottom, spacing: 0) { tripPanel }
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
        .onChange(of: location.hasFix) { _, hasFix in
            // Frame the arrival of a fix, not every update after it. Re-framing
            // on each new position would wrestle the map back from a walker who
            // had panned away from themselves to look at where they are going.
            guard hasFix, origin == nil, destination == nil, let start else { return }
            frame(coordinates: [start])
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

    private func dropPin(at coordinate: CLLocationCoordinate2D) {
        guard ServiceArea.contains(coordinate) else {
            rejectedPin = "FlatPath only routes inside San Francisco."
            return
        }

        rejectedPin = nil
        select(
            Destination(
                name: "Dropped pin",
                address: Self.coordinateLabel.string(from: coordinate),
                coordinate: coordinate
            )
        )
    }

    /// Take a chosen place as whichever end of the trip is being set.
    ///
    /// Setting one end always returns the app to setting the other, because a
    /// walker who has just named a start is on their way to naming a
    /// destination, and because a lingering mode is a mode someone has to
    /// remember they are in.
    private func select(_ place: Destination) {
        switch editing {
        case .start:
            origin = place
        case .destination:
            destination = place
        }

        editing = .destination
        dismissSearch()
        frame(coordinates: [start, destination?.coordinate].compactMap { $0 })
    }

    private func dismissSearch() {
        query = ""
        isSearchFocused = false
        search.clear()
    }

    // MARK: Camera

    /// Move the camera to hold every given point at a readable scale.
    private func frame(coordinates: [CLLocationCoordinate2D]) {
        guard let region = MKCoordinateRegion(containing: coordinates) else { return }
        withAnimation(Theme.Motion.camera) {
            camera = .region(region)
        }
    }

    private static let coordinateLabel: CLLocationCoordinate2DFormatter = .init()
}

// MARK: - Search

private extension MapContainerView {
    @ViewBuilder
    var searchPanel: some View {
        VStack(spacing: 0) {
            HStack(spacing: 8) {
                Image(systemName: "magnifyingglass")
                    .foregroundStyle(Theme.secondaryText)

                TextField(editing.prompt, text: $query)
                    .textFieldStyle(.plain)
                    .font(Theme.label(.body))
                    .foregroundStyle(Theme.primaryText)
                    .autocorrectionDisabled()
                    .submitLabel(.search)
                    .focused($isSearchFocused)

                if search.isSearching {
                    ProgressView().controlSize(.small)
                } else if !query.isEmpty {
                    Button {
                        dismissSearch()
                    } label: {
                        Image(systemName: "xmark.circle.fill")
                            .foregroundStyle(Theme.secondaryText)
                    }
                    .buttonStyle(.plain)
                }
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 10)

            if let message = search.message, !query.isEmpty {
                hairline
                Text(message)
                    .font(Theme.label(.footnote))
                    .foregroundStyle(Theme.secondaryText)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.horizontal, 12)
                    .padding(.vertical, 10)
            }

            if !search.results.isEmpty {
                hairline
                resultList
            }
        }
        .background(Theme.surface)
        .overlay(alignment: .bottom) { hairline }
    }

    /// A rule a device pixel thick. The panels are separated from the map and
    /// from each other by these alone -- no borders, no corner radii, no
    /// shadows -- so that the map keeps the screen and the panels read as edges
    /// of it rather than as windows floating over it.
    var hairline: some View {
        Rectangle()
            .fill(Theme.hairline)
            .frame(height: 1 / displayScale)
    }

    var resultList: some View {
        ScrollView {
            LazyVStack(spacing: 0) {
                ForEach(search.results) { result in
                    Button {
                        select(result)
                    } label: {
                        VStack(alignment: .leading, spacing: 2) {
                            Text(result.name)
                                .font(Theme.label(.body))
                                .foregroundStyle(Theme.primaryText)
                            if let address = result.address {
                                Text(address)
                                    .font(Theme.label(.footnote))
                                    .foregroundStyle(Theme.secondaryText)
                            }
                        }
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(.horizontal, 12)
                        .padding(.vertical, 10)
                        .contentShape(.rect)
                    }
                    .buttonStyle(.plain)

                    hairline.padding(.leading, 12)
                }
            }
        }
        // Tall enough to show a handful of matches, short enough that the map
        // stays the thing on screen — the walker is choosing between places they
        // can see, not reading a list.
        .frame(maxHeight: 240)
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
            HStack(spacing: 12) {
                VStack(alignment: .leading, spacing: 8) {
                    endpoint(
                        .start,
                        symbol: origin == nil ? "location.fill" : "smallcircle.filled.circle",
                        title: "Start",
                        detail: startDetail,
                        isSet: start != nil,
                        // The walker's own position is the now-marker on the
                        // map, and the accent belongs to it. A start they typed
                        // is a place like any other, so it is drawn like one.
                        accent: origin == nil ? Theme.accent : Theme.destination,
                        trailing: origin == nil ? nil : "Use my location"
                    )

                    hairline

                    endpoint(
                        .destination,
                        symbol: "flag.fill",
                        title: "Destination",
                        detail: destination.map { $0.address ?? $0.name }
                            ?? "Press and hold the map, or search above",
                        isSet: destination != nil,
                        accent: Theme.destination,
                        trailing: destination == nil ? nil : "Clear",
                        isBusy: isRouting
                    )
                }

                swapButton
            }

            if let notice = rejectedPin ?? routingProblem {
                Text(notice)
                    .font(Theme.label(.footnote))
                    .foregroundStyle(Theme.secondaryText)
            }
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 12)
        .frame(maxWidth: .infinity, alignment: .leading)
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
            coordinate: coordinate
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
    func endpoint(
        _ end: Endpoint,
        symbol: String,
        title: String,
        detail: String,
        isSet: Bool,
        accent: Color,
        trailing: String? = nil,
        isBusy: Bool = false
    ) -> some View {
        let isEditing = editing == end && isSearchFocused

        HStack(alignment: .firstTextBaseline, spacing: 10) {
            Image(systemName: symbol)
                .font(Theme.label(.caption))
                .foregroundStyle(isSet ? accent : Theme.tertiaryText)
                .frame(width: 16)

            Button {
                edit(end)
            } label: {
                VStack(alignment: .leading, spacing: 2) {
                    Text(title)
                        .font(Theme.label(.caption, weight: .semibold))
                        .foregroundStyle(isEditing ? Theme.accent : Theme.secondaryText)
                    // A set endpoint is a place or a coordinate, which reads as
                    // a figure; an unset one is a sentence asking for one.
                    Text(detail)
                        .font(isSet ? Theme.figure(.footnote) : Theme.label(.footnote))
                        .foregroundStyle(isSet ? Theme.primaryText : Theme.secondaryText)
                        .multilineTextAlignment(.leading)
                        .lineLimit(2)
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .contentShape(.rect)
            }
            .buttonStyle(.plain)

            if isBusy {
                ProgressView().controlSize(.small)
            }

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

    /// Point the search and the next long press at one end of the trip.
    func edit(_ end: Endpoint) {
        editing = end
        query = ""
        search.clear()
        isSearchFocused = true
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
    /// The chooser and the trip strip, as one surface at the foot of the map.
    ///
    /// The strip stays put once routes arrive rather than being replaced by
    /// them: it holds the only way to clear a destination, and it is where the
    /// reason for an empty list gets explained.
    var tripPanel: some View {
        VStack(spacing: 0) {
            if !routes.isEmpty {
                RouteCardsView(routes: routes.map(\.option), selection: $selectedRoute)
                hairline
                startButton
                hairline
            }

            tripSummary
        }
        .background(Theme.surface)
        .overlay(alignment: .top) { hairline }
    }

    /// Enters turn-by-turn on the selected route.
    ///
    /// Deliberately a second act rather than something a card tap does on its
    /// own. Tapping between the cards is how the walker compares the routes --
    /// each tap redraws one in the accent color so it can be looked at on the
    /// map -- and a tap that launched navigation would make the comparison the
    /// app exists for impossible to perform without leaving it three times.
    @ViewBuilder
    var startButton: some View {
        let selected = routes.first { $0.id == selectedRoute }

        Button {
            navigating = selected
        } label: {
            Label("Start \(selected?.option.name ?? "")", systemImage: "figure.walk")
                .font(Theme.label(.subheadline, weight: .semibold))
                .frame(maxWidth: .infinity)
                .padding(.vertical, 12)
                .contentShape(.rect)
        }
        .buttonStyle(.plain)
        // Emerald, as the one action that commits to a route -- the same
        // meaning the accent carries on the line and on the chosen card.
        .foregroundStyle(selected == nil ? Theme.tertiaryText : Theme.accent)
        .disabled(selected == nil)
    }

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
    }

    var planRequest: PlanRequest {
        PlanRequest(origin: origin?.id, destination: destination?.id, hasStart: start != nil)
    }

    /// Find the routes for the current pair of endpoints, if there is one.
    func planRoutes() async {
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
        let plan = await Task.detached(priority: .userInitiated) {
            RoutePlan(from: start, to: destination.coordinate, in: graph)
        }.value

        // A newer request cancelled this one — its own result is the current
        // one, and writing this stale plan over it would win the race by
        // finishing second.
        guard !Task.isCancelled else { return }

        switch plan {
        case .routes(let found):
            withAnimation(Theme.Motion.selection) {
                routes = found
                // The first option is the least hill-averse, which is the
                // closest thing to what another maps app would have given.
                // Selecting it makes every other card a visible trade against a
                // familiar answer.
                selectedRoute = found.first?.id
            }
            routingProblem = nil
            frame(coordinates: found.flatMap(\.coordinates))

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
    }

}

/// One end of a trip, for saying which end is being set.
private enum Endpoint {
    case start
    case destination

    /// What the search field asks for while this end is the one being filled.
    var prompt: String {
        switch self {
        case .start: "Search for a starting point"
        case .destination: "Search San Francisco"
        }
    }
}

/// A route option with its geometry already resolved.
///
/// The map needs a route as coordinates, and the graph stores it as node
/// indices. Converting once when the route is found, rather than in the view
/// body, keeps a few hundred lookups per polyline out of every render pass. The
/// steep stretches are found in the same pass and for the same reason.
private struct PlannedRoute: Identifiable {
    let option: RouteOption
    let coordinates: [CLLocationCoordinate2D]

    /// The parts of the route that climb hard enough to be worth marking.
    let climbs: [Climb]

    var id: RouteOption.ID { option.id }

    /// A run of consecutive blocks in the same steepness band.
    ///
    /// Runs rather than blocks: a hill is walked as one stretch, and drawing it
    /// as a dozen separate marks would turn a warning into a dashed line.
    struct Climb: Identifiable {
        /// Where the run starts along the route, which is unique within it.
        let id: Int
        let grade: Grade
        let coordinates: [CLLocationCoordinate2D]
    }

    init(option: RouteOption, coordinates: [CLLocationCoordinate2D], in graph: WalkingGraph) {
        self.option = option
        self.coordinates = coordinates

        var climbs: [Climb] = []
        var runStart: Int?
        var runGrade = Grade.gentle

        /// Close the run that ends at `position`, if one is open.
        func closeRun(at position: Int) {
            guard let start = runStart, runGrade.isWorthWarningAbout else {
                runStart = nil
                return
            }
            climbs.append(
                Climb(id: start, grade: runGrade, coordinates: Array(coordinates[start ... position]))
            )
            runStart = nil
        }

        for (position, edge) in option.edges.enumerated() {
            let grade = Grade(
                rise: Double(graph.edgeDeltaElevation[edge]),
                over: Double(graph.edgeLength[edge])
            )

            if grade != runGrade {
                closeRun(at: position)
                runGrade = grade
                runStart = grade.isWorthWarningAbout ? position : nil
            }
        }
        closeRun(at: option.edges.count)

        self.climbs = climbs
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

    init(from start: CLLocationCoordinate2D, to destination: CLLocationCoordinate2D, in graph: WalkingGraph) {
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

        let options = RouteOptions.between(start: origin, destination: goal, in: graph)
        guard !options.isEmpty else {
            self = .unreachable
            return
        }

        self = .routes(
            options.map { option in
                PlannedRoute(
                    option: option,
                    coordinates: option.nodes.map { node in
                        CLLocationCoordinate2D(
                            latitude: graph.latitudes[node],
                            longitude: graph.longitudes[node]
                        )
                    },
                    in: graph
                )
            }
        )
    }
}

// MARK: - Markers

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

private extension MKCoordinateRegion {
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
