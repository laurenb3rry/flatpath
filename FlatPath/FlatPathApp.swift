//  FlatPathApp.swift
//
//  Application entry point. Loads the bundled walking graph once at launch and
//  hands it to the view layer, so no screen ever waits on graph I/O.
//
//  The load is synchronous and deliberately so. Routing is the only thing this
//  app does, and every screen past the first needs the graph, so there is no
//  useful work to do while it arrives — an async load would only trade a slower
//  first frame for a half-loaded UI. If the graph cannot be read the app has
//  nothing to offer, so the failure is surfaced rather than swallowed.

import OSLog
import SwiftUI

@main
struct FlatPathApp: App {
    private let graph: Result<WalkingGraph, Error>

    private static let logger = Logger(subsystem: "com.flatpath.FlatPath", category: "graph")

    init() {
        let started = ContinuousClock.now
        do {
            let graph = try GraphLoader.loadBundledGraph()
            let elapsed = ContinuousClock.now - started
            Self.logger.notice(
                """
                loaded graph: \(graph.nodeCount, privacy: .public) nodes, \
                \(graph.edgeCount, privacy: .public) edges, \
                \(graph.streetNames.count, privacy: .public) street names, \
                \(graph.costSettingCount, privacy: .public) cost settings \
                in \(elapsed.milliseconds, privacy: .public) ms
                """
            )
            self.graph = .success(graph)
        } catch {
            Self.logger.error("failed to load graph: \(String(describing: error), privacy: .public)")
            self.graph = .failure(error)
        }
    }

    var body: some Scene {
        WindowGroup {
            Group {
                switch graph {
                case .success(let graph):
                    MapContainerView(graph: graph)
                case .failure(let error):
                    GraphUnavailableView(error: error)
                }
            }
            // Dark unconditionally, not by system preference. The palette is
            // built on a near-black ground -- the map is dark, the panels laid
            // over it are barely lighter, and the accent is legible because
            // there is nothing bright to compete with it. In a light scheme the
            // same tokens would be an emerald line on white, which is a
            // different design rather than the same one inverted.
            .preferredColorScheme(.dark)
            // Every `.tint` in the view layer resolves to the accent from here,
            // which is what keeps emerald in one place instead of spelled out
            // at each of the handful of things allowed to use it.
            .tint(Theme.accent)
            .background(Theme.background)
        }
    }
}

/// Shown instead of the map when the graph could not be read.
///
/// There is no degraded mode worth offering here. A basemap with no graph under
/// it would take destinations and then refuse every route, so the failure is
/// stated plainly at launch rather than discovered one trip at a time.
private struct GraphUnavailableView: View {
    let error: Error

    var body: some View {
        VStack(spacing: 12) {
            Text("FlatPath")
                .font(Theme.label(.title, weight: .semibold))
                .foregroundStyle(Theme.primaryText)

            Text("The walking map could not be loaded, so no routes can be found.")
                .font(Theme.label(.body))
                .foregroundStyle(Theme.secondaryText)
                .multilineTextAlignment(.center)

            Text(String(describing: error))
                .font(Theme.figure(.footnote))
                .foregroundStyle(Theme.tertiaryText)
                .multilineTextAlignment(.center)
        }
        .padding()
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(Theme.background)
    }
}

private extension Duration {
    /// Whole milliseconds, for logging. `components` avoids the floating-point
    /// round trip that `Double(...)` conversions of a `Duration` require.
    var milliseconds: Int64 {
        components.seconds * 1_000 + components.attoseconds / 1_000_000_000_000_000
    }
}
