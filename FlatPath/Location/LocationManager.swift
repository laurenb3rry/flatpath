//  LocationManager.swift
//
//  Wraps CoreLocation: authorization, the current fix used as the default route
//  start, and the position updates that advance navigation steps.
//
//  Location is requested when-in-use only, even though tracking carries on with
//  the app off screen. That is not a contradiction: when-in-use covers a session
//  the walker started themselves and can see is running, which is exactly what
//  turn-by-turn is. Always-authorization would additionally let the app wake
//  itself to find the walker when nobody asked it to, which this app never does,
//  and asking for it is the kind of prompt people decline.
//
//  Off-screen tracking is switched on for the length of a walk and off again at
//  the end of it. Left on, the app would hold a location session open for as
//  long as it was installed; left off, an instruction would stop advancing the
//  moment the phone went into a pocket, which is where a walker puts it between
//  one corner and the next.
//
//  The app stays usable without a fix. A denied or unavailable location costs
//  the walker the convenience of a start point they did not have to place
//  themselves; it does not cost them the map, the search, or the route.

import CoreLocation
import Observation
import OSLog

/// The device's authorization state and latest position, as something a SwiftUI
/// view can observe directly.
///
/// Isolated to the main actor because that is where it is genuinely used and
/// genuinely updated: the object is created from the view layer, so the
/// `CLLocationManager` it owns is created on the main run loop, and CoreLocation
/// delivers every delegate callback back to that same run loop.
@MainActor
@Observable
final class LocationManager: NSObject {
    /// Whether the walker has been asked yet, and what they answered.
    private(set) var authorization: CLAuthorizationStatus = .notDetermined

    /// The most recent fix good enough to trust, or `nil` before the first one
    /// arrives. Views read this as the default route start.
    private(set) var coordinate: CLLocationCoordinate2D?

    /// Why location is unavailable, when the reason is worth showing. Cleared by
    /// the next successful fix, because a transient failure that has since been
    /// recovered from is noise.
    private(set) var failure: String?

    private let manager = CLLocationManager()

    private static let logger = Logger(subsystem: "com.flatpath.FlatPath", category: "location")

    /// A fix older than this is treated as a leftover from a previous session
    /// rather than where the walker is now. CoreLocation hands over its cached
    /// last-known position the instant updates start, which is useful as a first
    /// guess but must not be mistaken for a live one.
    private static let staleFixAge: TimeInterval = 60

    /// Fixes less precise than this are dropped. Early fixes come from cell and
    /// Wi-Fi triangulation and can be kilometers wide — wide enough to place the
    /// route start on the wrong side of a hill, which is the one error this app
    /// cannot afford to make silently.
    private static let worstUsefulAccuracy: CLLocationAccuracy = 100

    override init() {
        super.init()
        manager.delegate = self
        manager.desiredAccuracy = kCLLocationAccuracyBest
        // Walking pace over a city block. Below this the position is redrawing
        // faster than the walker can act on it, and every update is a wakeup.
        manager.distanceFilter = 5
        authorization = manager.authorizationStatus
    }

    /// True once there is a live position to route from.
    var hasFix: Bool { coordinate != nil }

    /// Whether the walker has granted access, whatever they have granted it for.
    var isAuthorized: Bool {
        authorization == .authorizedWhenInUse || authorization == .authorizedAlways
    }

    /// Ask for location if the walker has not been asked, and start updates if
    /// they already said yes.
    ///
    /// Safe to call on every appearance. The system prompt is shown once per
    /// install no matter how many times it is requested, and starting updates
    /// that are already running is a no-op.
    func start() {
        switch authorization {
        case .notDetermined:
            // Nothing starts yet. The authorization callback fires with the
            // walker's answer and starts updates then, so the request is made
            // exactly once rather than racing an unanswered prompt.
            manager.requestWhenInUseAuthorization()
        case .authorizedWhenInUse, .authorizedAlways:
            manager.startUpdatingLocation()
        default:
            failure = Self.explanation(for: authorization)
        }
    }

    /// What to tell the walker about a status that yields no fixes, or `nil`
    /// when the status is not something they need to act on.
    private static func explanation(for status: CLAuthorizationStatus) -> String? {
        switch status {
        case .denied:
            "Location access is off for FlatPath. Turn it on in Settings, or drop a pin to set a start point."
        case .restricted:
            "Location is unavailable on this device."
        default:
            nil
        }
    }

    /// Stop consuming power once no screen needs the walker's position.
    func stop() {
        manager.stopUpdatingLocation()
    }

    /// Whether a walk is being followed right now, and so whether fixes keep
    /// arriving with the app off screen.
    private(set) var isNavigating = false

    /// Keep the walker's position coming while the app is in the background and
    /// while the screen is asleep.
    ///
    /// Three settings together are what make that work, and each fails silently
    /// in its own way if it is left out. Without the background updates flag the
    /// system stops delivering the moment the app leaves the screen. Without
    /// turning off automatic pausing, CoreLocation decides on its own that a
    /// walker waiting at a long light has finished their trip, and never
    /// resumes. And the activity type is what tells it these are footsteps, so
    /// that stopping at a corner is read as part of walking rather than as the
    /// end of it.
    ///
    /// The system shows its own indicator the whole time this is on. That is
    /// the right trade and it is deliberately not hidden: an app holding a
    /// location session open in a pocket should be visible from the outside.
    ///
    /// Nothing survives the app being swiped out of the app switcher. A walker
    /// who closes it has ended the walk, and this asks for no permission that
    /// would let it start itself up again afterwards.
    func startNavigating() {
        guard isAuthorized else { return }

        manager.activityType = .fitness
        manager.pausesLocationUpdatesAutomatically = false
        manager.allowsBackgroundLocationUpdates = true
        manager.showsBackgroundLocationIndicator = true
        manager.startUpdatingLocation()

        isNavigating = true
        Self.logger.notice("navigation tracking on")
    }

    /// Give the background session back at the end of a walk.
    ///
    /// Updates themselves carry on, because the map screen behind navigation
    /// still wants a position to route from — what stops is the entitlement to
    /// keep receiving them with the app off screen.
    func stopNavigating() {
        guard isNavigating else { return }

        manager.allowsBackgroundLocationUpdates = false
        manager.pausesLocationUpdatesAutomatically = true
        manager.activityType = .other

        isNavigating = false
        Self.logger.notice("navigation tracking off")
    }
}

// CoreLocation's delegate protocol makes no isolation promise, so its methods
// have to be declared outside the actor even though CoreLocation does in fact
// call them on the run loop the manager was created on — the main one. Each shim
// therefore states that assumption rather than hopping asynchronously: a hop
// would let a fix land a frame later than the run loop already delivered it, and
// would leave the delegate silently working if the assumption were ever wrong.
// Asserting it means a violation surfaces immediately instead of as a data race.
extension LocationManager: CLLocationManagerDelegate {
    nonisolated func locationManagerDidChangeAuthorization(_ manager: CLLocationManager) {
        MainActor.assumeIsolated { authorizationChanged(reportedBy: manager) }
    }

    nonisolated func locationManager(_ manager: CLLocationManager, didUpdateLocations locations: [CLLocation]) {
        MainActor.assumeIsolated { received(locations) }
    }

    nonisolated func locationManager(_ manager: CLLocationManager, didFailWithError error: Error) {
        MainActor.assumeIsolated { updateFailed(error) }
    }
}

private extension LocationManager {
    func authorizationChanged(reportedBy manager: CLLocationManager) {
        authorization = manager.authorizationStatus
        Self.logger.notice("authorization is now \(self.authorization.rawValue, privacy: .public)")

        if isAuthorized {
            failure = nil
            manager.startUpdatingLocation()
        } else {
            // A revoked authorization leaves the last fix on screen as the route
            // start, which would quietly become wrong as the walker moves.
            coordinate = nil
            manager.stopUpdatingLocation()
            // Deliberately not routed back through `start()`: this callback also
            // fires while the status is still undetermined, and re-requesting
            // from here would put the system prompt on screen at launch rather
            // than when a screen actually asks for the walker's position.
            failure = Self.explanation(for: authorization)
        }
    }

    func received(_ locations: [CLLocation]) {
        guard let fix = locations.last, isTrustworthy(fix) else { return }
        coordinate = fix.coordinate
        failure = nil
    }

    func updateFailed(_ error: Error) {
        // A lone failure means CoreLocation has not converged yet, not that it
        // never will, so it is logged and left alone. Only a persistent absence
        // of any fix at all is worth telling the walker about.
        Self.logger.error("location update failed: \(error.localizedDescription, privacy: .public)")
        guard coordinate == nil, (error as? CLError)?.code != .locationUnknown else { return }
        failure = "Could not determine your location."
    }

    /// Whether a fix is recent enough and precise enough to route from.
    func isTrustworthy(_ fix: CLLocation) -> Bool {
        // A negative accuracy is CoreLocation's way of saying the coordinate is
        // invalid, not that it is extraordinarily precise.
        guard fix.horizontalAccuracy >= 0, fix.horizontalAccuracy <= Self.worstUsefulAccuracy else {
            return false
        }
        return -fix.timestamp.timeIntervalSinceNow <= Self.staleFixAge
    }
}
