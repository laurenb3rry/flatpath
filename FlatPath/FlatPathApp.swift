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
            GraphStatusView(graph: graph)
        }
    }
}

/// Placeholder first screen: the graph's vital signs, or why it would not load.
/// Stands in until the map becomes the app's root view.
private struct GraphStatusView: View {
    let graph: Result<WalkingGraph, Error>

    var body: some View {
        VStack(spacing: 12) {
            Text("FlatPath")
                .font(.title.weight(.semibold))

            switch graph {
            case .success(let graph):
                Text("\(graph.nodeCount) nodes")
                Text("\(graph.edgeCount) directed edges")
                Text("\(graph.streetNames.count) street names")
            case .failure(let error):
                Text("Graph failed to load")
                Text(String(describing: error))
                    .multilineTextAlignment(.center)
            }
        }
        .font(.system(.body, design: .monospaced))
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
