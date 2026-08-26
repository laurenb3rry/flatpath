//  RouteCardsView.swift
//
//  The route chooser: one card per option, each showing time, elevation gain,
//  and distance, tappable to select.
//
//  Elevation gain is the emphasized column. Every other maps app hides that
//  number, and surfacing it is the reason to use this one.

import SwiftUI

struct RouteCardsView: View {
    let routes: [RouteOption]
    @Binding var selection: RouteOption.ID?

    var body: some View {
        VStack(spacing: 0) {
            ForEach(routes) { route in
                Button {
                    selection = route.id
                } label: {
                    RouteCard(route: route, isSelected: route.id == selection)
                }
                .buttonStyle(.plain)

                if route.id != routes.last?.id {
                    Divider().padding(.leading, 16)
                }
            }
        }
    }
}

/// One route as a single line: what it is, then the three numbers.
///
/// The numbers sit in a fixed order and a monospaced face so that the columns
/// line up between rows. Comparing routes means comparing digits in the same
/// place — a proportional face would leave the minutes of one route under the
/// feet of another, and the whole point of showing three routes at once is that
/// the differences between them can be read without arithmetic.
private struct RouteCard: View {
    let route: RouteOption
    let isSelected: Bool

    var body: some View {
        HStack(spacing: 12) {
            // Echoes the polyline on the map: the selected route is the one
            // drawn in the accent color, and this is the same mark beside its
            // name, so the row and the line read as the same object.
            Capsule()
                .fill(isSelected ? AnyShapeStyle(.tint) : AnyShapeStyle(.quaternary))
                .frame(width: 3, height: 26)

            Text(route.name)
                .font(.subheadline.weight(isSelected ? .semibold : .regular))

            Spacer(minLength: 8)

            HStack(spacing: 6) {
                Text(route.metrics.timeText)

                separator

                // The hero number, and the only one drawn at full strength.
                Text(route.metrics.elevationGainText)
                    .fontWeight(.semibold)
                    .foregroundStyle(.primary)

                separator

                Text(route.metrics.distanceText)
            }
            .font(.system(.subheadline, design: .monospaced))
            .foregroundStyle(.secondary)
            .lineLimit(1)
            .minimumScaleFactor(0.8)
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(isSelected ? AnyShapeStyle(.tint.opacity(0.12)) : AnyShapeStyle(.clear))
        // The whole row is the target, not just the text in it.
        .contentShape(.rect)
        .accessibilityElement(children: .combine)
        .accessibilityAddTraits(isSelected ? [.isButton, .isSelected] : .isButton)
    }

    private var separator: some View {
        Text("·").foregroundStyle(.tertiary)
    }
}

#Preview {
    @Previewable @State var selection: RouteOption.ID? = 1

    let samples = [
        RouteOption(id: 0, name: "Flatter", nodes: [], edges: [],
                    metrics: RouteMetrics(time: 18 * 60, elevationGain: 104, distance: 1_770)),
        RouteOption(id: 1, name: "Balanced", nodes: [], edges: [],
                    metrics: RouteMetrics(time: 21 * 60, elevationGain: 37, distance: 1_930)),
        RouteOption(id: 2, name: "Flattest", nodes: [], edges: [],
                    metrics: RouteMetrics(time: 24 * 60, elevationGain: 18, distance: 2_250)),
    ]

    return RouteCardsView(routes: samples, selection: $selection)
        .background(.regularMaterial)
}
