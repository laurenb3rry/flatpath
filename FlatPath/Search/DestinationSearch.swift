//  DestinationSearch.swift
//
//  Destination lookup by name or address, biased to San Francisco so that local
//  results rank first. Routing only covers the bundled SF graph, so destinations
//  outside it cannot be routed to and should not be offered.
//
//  The bias and the filter are separate mechanisms doing separate jobs. Biasing
//  the request is a ranking hint — it makes "Mission" mean the SF district
//  rather than a street in San Antonio — but it is only a hint, and results from
//  outside the region still come back. The filter is what actually enforces
//  coverage: anything the router could not reach is dropped before the walker
//  ever sees it, so no result on screen is one that leads to a dead end.

import CoreLocation
import MapKit
import Observation

/// The ground the app can route across: the same box the offline graph was cut
/// to, as (west, south, east, north) degrees.
///
/// This is duplicated from the graph build's configuration rather than read from
/// the graph file, which does not carry its own bounds. The two must agree. If
/// the build's box is widened, widening this one is what makes the new area
/// searchable; leaving it narrow silently hides streets the router can reach.
/// Narrower here than there is safe. Wider is not — it offers destinations that
/// have no nodes to route to.
enum ServiceArea {
    static let west = -122.5150
    static let south = 37.7080
    static let east = -122.3570
    static let north = 37.8330

    static let center = CLLocationCoordinate2D(
        latitude: (south + north) / 2,
        longitude: (west + east) / 2
    )

    /// The whole coverage area, for the opening camera and the search bias.
    static let region = MKCoordinateRegion(
        center: center,
        span: MKCoordinateSpan(
            latitudeDelta: north - south,
            longitudeDelta: east - west
        )
    )

    static func contains(_ coordinate: CLLocationCoordinate2D) -> Bool {
        (south ... north).contains(coordinate.latitude)
            && (west ... east).contains(coordinate.longitude)
    }
}

/// Somewhere the walker can be routed to: a searched place, or a dropped pin.
struct Destination: Identifiable {
    let id = UUID()
    /// What to call it on the map and in the route cards.
    let name: String
    /// Street address, when there is one worth showing alongside the name.
    let address: String?
    let coordinate: CLLocationCoordinate2D

    /// Whether this is somewhere with a name, as opposed to a spot on the map
    /// known only by its coordinates.
    ///
    /// Decides how the detail line under it is set: an address is a sentence
    /// and belongs in the reading face, a latitude and longitude are figures
    /// and belong in the monospaced one.
    let isNamed: Bool

    init(name: String, address: String?, coordinate: CLLocationCoordinate2D, isNamed: Bool = true) {
        self.name = name
        self.address = address
        self.coordinate = coordinate
        self.isNamed = isNamed
    }
}

/// Runs destination queries and holds the results a view lists.
///
/// Isolated to the main actor: every property here exists to be read by a view
/// mid-render, and the work between them is network latency rather than
/// computation, so there is nothing to gain by updating them anywhere else.
@MainActor
@Observable
final class DestinationSearch {
    private(set) var results: [Destination] = []
    private(set) var isSearching = false

    /// Why the list is empty, when emptiness needs explaining. `nil` means the
    /// list stands on its own — either it has results, or nothing was asked.
    private(set) var message: String?

    /// Queries shorter than this are not sent. One or two characters match
    /// half the city and cost a round trip to say nothing.
    ///
    /// Visible so that a view can tell the walker why nothing has happened yet
    /// rather than leaving a field that appears to be ignoring them.
    static let shortestUsefulQuery = 3

    /// How long the typing has to pause before a query is sent. Long enough that
    /// a word typed at speed costs one request instead of one per letter, short
    /// enough to still feel like it is keeping up.
    private static let typingPause = Duration.milliseconds(300)

    /// Look up `query`, replacing whatever the last call found.
    ///
    /// Cancellation-aware throughout, so a view can drive this straight from the
    /// text field's value and let each new keystroke abandon the last search.
    func search(matching query: String) async {
        let query = query.trimmingCharacters(in: .whitespacesAndNewlines)

        guard query.count >= Self.shortestUsefulQuery else {
            clear()
            return
        }

        do {
            try await Task.sleep(for: Self.typingPause)
        } catch {
            // Cancelled mid-pause: the walker typed again, and a later call is
            // already handling what they typed. Leaving the current results and
            // spinner untouched keeps the list from flickering between letters.
            return
        }

        isSearching = true
        defer { isSearching = false }

        let request = MKLocalSearch.Request()
        request.naturalLanguageQuery = query
        request.region = ServiceArea.region
        request.resultTypes = [.address, .pointOfInterest]
        if #available(iOS 18.0, *) {
            // Turns the region from a ranking preference into a hard constraint.
            // Only tightens what the filter below already enforces, but it stops
            // out-of-area matches from crowding local ones out of the response.
            request.regionPriority = .required
        }

        do {
            let response = try await MKLocalSearch(request: request).start()
            guard !Task.isCancelled else { return }

            let routable = response.mapItems.compactMap(Destination.init(mapItem:))
            results = routable
            message = routable.isEmpty ? Self.nothingNearbyMessage(hadResults: !response.mapItems.isEmpty) : nil
        } catch is CancellationError {
            return
        } catch let error as MKError where error.code == .placemarkNotFound {
            results = []
            message = Self.nothingNearbyMessage(hadResults: false)
        } catch {
            guard !Task.isCancelled else { return }
            results = []
            message = "Search is unavailable right now."
        }
    }

    func clear() {
        results = []
        message = nil
    }

    /// Distinguishes "the city has no such place" from "that place exists, but
    /// not where this app can walk you", because only the second is worth the
    /// walker knowing they were not simply misspelling something.
    private static func nothingNearbyMessage(hadResults: Bool) -> String {
        hadResults
            ? "Only found matches outside San Francisco."
            : "No matches in San Francisco."
    }
}

private extension Destination {
    /// A map item as a routable destination, or `nil` if it falls outside the
    /// area the graph covers.
    init?(mapItem: MKMapItem) {
        let placemark = mapItem.placemark
        let coordinate = placemark.coordinate

        guard CLLocationCoordinate2DIsValid(coordinate), ServiceArea.contains(coordinate) else {
            return nil
        }

        let name = mapItem.name ?? placemark.title ?? "Dropped pin"
        // For a plain address the name and the formatted address are the same
        // string, and showing it twice reads as a rendering bug.
        let address = placemark.title.flatMap { $0 == name ? nil : $0 }

        self.init(name: name, address: address, coordinate: coordinate)
    }
}
