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
                    ForEach(selected.shades) { shade in
                        MapPolyline(coordinates: shade.coordinates)
                            .stroke(shade.color, style: Theme.Line.stroke(Theme.Line.selected))
                    }

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
            .mapStyle(Theme.mapStyle)
            .mapControls {
                MapCompass()
                MapScaleView()
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
                coordinate: coordinate,
                isNamed: false
            ),
            as: editing
        )
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

    /// The route drawn as consecutive runs, each a shade deeper than the last.
    ///
    /// Consecutive rather than overlaid: run `i` ends on the coordinate run
    /// `i + 1` begins on, so the joins are shared points and the line has no
    /// gaps in it at any zoom.
    let shades: [Shade]

    var id: RouteOption.ID { option.id }

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

        shades = Self.shades(along: coordinates)

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
