//  LiveNavigation.swift
//
//  Puts the walk on the Lock Screen and in the Dynamic Island, and takes it down
//  again at the end.
//
//  This exists because of how the app is actually used: the phone goes in a
//  pocket between corners and comes out to answer one question -- what am I
//  meant to do next. Making that answer readable without unlocking is worth more
//  than anything on the map screen behind it.
//
//  Updates are pushed only when the walker would see a difference. Fixes arrive
//  every few meters, which is several a minute at a walking pace, and the system
//  budgets how often a Live Activity may be redrawn; spending that budget
//  restating the same sentence would leave nothing for the corner where it
//  changes.

import ActivityKit
import OSLog

/// The Live Activity for one walk.
///
/// Isolated to the main actor because it is driven by the navigation screen and
/// holds the handle that screen's lifetime owns.
@MainActor
final class LiveNavigation {
    private var activity: Activity<NavigationAttributes>?

    /// The last state handed to the system, to compare the next one against.
    private var shown: NavigationAttributes.ContentState?

    fileprivate static let logger = Logger(subsystem: "com.flatpath.FlatPath", category: "activity")

    /// How long a state stays believable without an update.
    ///
    /// The walker can end a walk by swiping the app out of the app switcher, and
    /// a terminated app cannot take its Live Activity down on the way out. The
    /// system marks the content stale at this point instead, which is what stops
    /// a Lock Screen from showing a confident instruction from twenty minutes
    /// ago. Comfortably longer than the gap between fixes, short enough that a
    /// dead walk is not left standing.
    private static let staleAfter: TimeInterval = 3 * 60

    /// Whether the walker has left Live Activities on for this app. They can be
    /// turned off per app in Settings, and off means nothing here does anything.
    private var isPermitted: Bool {
        ActivityAuthorizationInfo().areActivitiesEnabled
    }

    /// Start showing a walk, if one is not already showing.
    func begin(
        routeName: String,
        destination: String,
        state: NavigationAttributes.ContentState
    ) {
        guard activity == nil, isPermitted else { return }

        do {
            activity = try Activity.request(
                attributes: NavigationAttributes(routeName: routeName, destination: destination),
                content: content(for: state),
                pushType: nil
            )
            shown = state
            LiveNavigation.logger.notice("live activity started")
        } catch {
            // Nothing here is load-bearing: the walk carries on with the screen
            // as its only surface, which is how it worked before this existed.
            LiveNavigation.logger.error("live activity refused: \(String(describing: error), privacy: .public)")
        }
    }

    /// Show a new state, if it says anything the last one did not.
    func update(_ state: NavigationAttributes.ContentState) {
        guard let activity, state != shown else { return }

        shown = state
        Task { await activity.update(content(for: state)) }
    }

    /// Take the walk off the Lock Screen.
    ///
    /// Immediately rather than lingering: the walker has either arrived or
    /// chosen to stop, and in both cases the instruction is no longer something
    /// they should be acting on.
    func end() {
        guard let activity else { return }

        self.activity = nil
        shown = nil
        Task { await activity.end(nil, dismissalPolicy: .immediate) }
        LiveNavigation.logger.notice("live activity ended")
    }

    /// Clear away anything left over from a previous run of the app.
    ///
    /// A walker who ends a walk by swiping the app out of the app switcher kills
    /// the process, and a killed process cannot take its Live Activity down on
    /// the way out. The system stops trusting the content once it goes stale,
    /// but the card itself stays until something ends it -- so the next launch
    /// does, which is the first moment the app can.
    static func endOrphans() {
        for activity in Activity<NavigationAttributes>.activities {
            Task { await activity.end(nil, dismissalPolicy: .immediate) }
            logger.notice("ended an orphaned live activity")
        }
    }

    private func content(
        for state: NavigationAttributes.ContentState
    ) -> ActivityContent<NavigationAttributes.ContentState> {
        ActivityContent(state: state, staleDate: .now + Self.staleAfter)
    }
}
