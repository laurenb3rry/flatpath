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
            switch graph {
            case .success(let graph):
                MapContainerView(graph: graph)
            case .failure(let error):
                GraphUnavailableView(error: error)
            }
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
                .font(.title.weight(.semibold))

            Text("The walking map could not be loaded, so no routes can be found.")
                .multilineTextAlignment(.center)

            Text(String(describing: error))
                .font(.system(.footnote, design: .monospaced))
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
        }
        .padding()
    }
}

private extension Duration {
    /// Whole milliseconds, for logging. `components` avoids the floating-point
    /// round trip that `Double(...)` conversions of a `Duration` require.
    var milliseconds: Int64 {
        components.seconds * 1_000 + components.attoseconds / 1_000_000_000_000_000
    }
}
