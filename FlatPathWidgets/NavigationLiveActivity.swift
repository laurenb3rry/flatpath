//  NavigationLiveActivity.swift
//
//  How a walk in progress draws itself outside the app: on the Lock Screen and
//  in Notification Center, and in the Dynamic Island in its three sizes.
//
//  This process gets no graph, no route and no position -- only the state the
//  app hands it, already measured and already phrased. So there is no logic
//  here beyond layout, and every figure it prints is the same figure the app is
//  showing on its own screen.
//
//  It is read in the worst conditions the app has: a locked phone pulled halfway
//  out of a pocket, at arm's length, in motion. The instruction therefore gets
//  the size and the contrast, and everything else is quieter than it would be on
//  a screen someone is actually looking at.

import ActivityKit
import SwiftUI
import WidgetKit

@main
struct FlatPathWidgets: WidgetBundle {
    var body: some Widget {
        NavigationLiveActivity()
    }
}

struct NavigationLiveActivity: Widget {
    var body: some WidgetConfiguration {
        ActivityConfiguration(for: NavigationAttributes.self) { context in
            LockScreenView(attributes: context.attributes, state: context.state)
                .activityBackgroundTint(Theme.surface)
                .activitySystemActionForegroundColor(Theme.accent)
        } dynamicIsland: { context in
            DynamicIsland {
                DynamicIslandExpandedRegion(.leading) {
                    ManeuverGlyph(symbol: context.state.symbol, size: 28)
                        .padding(.leading, 4)
                }

                DynamicIslandExpandedRegion(.trailing) {
                    if let distance = context.state.distanceToManeuver, !context.state.hasArrived {
                        Text(distance)
                            .font(Theme.figure(.title3, weight: .semibold))
                            .foregroundStyle(Theme.primaryText)
                            .padding(.trailing, 4)
                    }
                }

                DynamicIslandExpandedRegion(.center) {
                    Text(context.state.instruction)
                        .font(Theme.label(.subheadline, weight: .medium))
                        .foregroundStyle(Theme.primaryText)
                        .multilineTextAlignment(.leading)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }

                DynamicIslandExpandedRegion(.bottom) {
                    RemainingRow(state: context.state, routeName: context.attributes.routeName)
                }
            } compactLeading: {
                ManeuverGlyph(symbol: context.state.symbol, size: 15)
            } compactTrailing: {
                // The one figure worth the few points the compact form gets: how
                // far to the thing being asked for.
                if let distance = context.state.distanceToManeuver, !context.state.hasArrived {
                    Text(distance)
                        .font(Theme.figure(.caption2, weight: .semibold))
                        .foregroundStyle(Theme.primaryText)
                }
            } minimal: {
                ManeuverGlyph(symbol: context.state.symbol, size: 15)
            }
            .keylineTint(Theme.accent)
        }
    }
}

// MARK: - Lock Screen

/// The full presentation, used on the Lock Screen and in Notification Center.
private struct LockScreenView: View {
    let attributes: NavigationAttributes
    let state: NavigationAttributes.ContentState

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(alignment: .top, spacing: 12) {
                ManeuverGlyph(symbol: state.symbol, size: 26)

                VStack(alignment: .leading, spacing: 2) {
                    if let distance = state.distanceToManeuver, !state.hasArrived {
                        Text(distance)
                            .font(Theme.figure(.title3, weight: .semibold))
                            .foregroundStyle(Theme.primaryText)
                    }

                    Text(state.instruction)
                        .font(Theme.label(.headline, weight: .medium))
                        .foregroundStyle(Theme.primaryText)
                        .fixedSize(horizontal: false, vertical: true)

                    if let following = state.following, !state.hasArrived {
                        Text(following)
                            .font(Theme.label(.caption))
                            .foregroundStyle(Theme.secondaryText)
                            .lineLimit(1)
                    }
                }

                Spacer(minLength: 0)
            }

            if let climb = state.climb, !state.hasArrived {
                ClimbWarning(climb: climb)
            }

            RemainingRow(state: state, routeName: attributes.routeName)
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 14)
    }
}

// MARK: - Pieces

/// The maneuver arrow, in the accent that means "this is the live one".
private struct ManeuverGlyph: View {
    let symbol: String
    let size: CGFloat

    var body: some View {
        Image(systemName: symbol)
            .font(.system(size: size, weight: .semibold))
            .foregroundStyle(Theme.accent)
    }
}

private struct ClimbWarning: View {
    let climb: NavigationAttributes.Climb

    var body: some View {
        HStack(spacing: 5) {
            Image(systemName: "arrow.up.forward")
                .font(Theme.label(.caption2, weight: .bold))
            Text(climb.percentage)
                .font(Theme.figure(.caption2, weight: .semibold))
            Text("climb")
                .font(Theme.label(.caption2))
        }
        .foregroundStyle(Theme.warning(for: climb.grade) ?? Theme.moderate)
    }
}

/// What is left of the walk: the same three figures the route was chosen by.
private struct RemainingRow: View {
    let state: NavigationAttributes.ContentState
    let routeName: String

    var body: some View {
        HStack(spacing: 6) {
            Text(state.hasArrived ? "Arrived" : state.timeRemaining)
                .foregroundStyle(Theme.primaryText)
            Text("·").foregroundStyle(Theme.tertiaryText)
            Text(state.distanceRemaining)
            Text("·").foregroundStyle(Theme.tertiaryText)
            Text(state.climbRemaining)
            Text("·").foregroundStyle(Theme.tertiaryText)
            Text(routeName)
                .font(Theme.label(.caption))
        }
        .font(Theme.figure(.caption))
        .foregroundStyle(Theme.secondaryText)
        .lineLimit(1)
        .minimumScaleFactor(0.75)
    }
}
