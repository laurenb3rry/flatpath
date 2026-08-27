//  RouteDots.swift
//
//  Breaking a stretch of route into the dots that mark it as a climb.
//
//  The obvious way to do this is a dash pattern, and it does not work. MapKit
//  draws `StrokeStyle.dash` in a unit that grows with how much ground the map is
//  showing rather than in points of screen: measured on device, the same pattern
//  that reads as clean round dots over four blocks reads as a row of merged
//  blobs at the zoom a cross-town route is framed at, the dots growing by the
//  same factor the view widens by. Line *width* is honest points — the solid
//  route holds its weight at every zoom — so only the pattern along the line is
//  affected, which is exactly the part a dash is for.
//
//  So the dots are placed here instead. Each one is a very short piece of the
//  route drawn with a round cap, which is a dot of exactly the stroke's width,
//  and the spacing between them is worked out in meters from how much ground a
//  point of screen currently covers. That gives dots that stay the same size and
//  the same distance apart whatever the map is showing, with no dependence on
//  what MapKit does with a dash pattern.

import CoreLocation
import Foundation

/// A stretch of route rendered as evenly spaced dots along its own line.
enum RouteDots {
    /// The dots marking `path`, each a two-point stub to be stroked with a
    /// round cap.
    ///
    /// Placed by distance along the path rather than at its vertices. A route's
    /// nodes are spaced by whatever the street data happened to record — every
    /// few meters at a mapped corner, a hundred down a straight block — and
    /// dotting the vertices would bunch the marks at junctions and leave the
    /// blocks between them bare.
    ///
    /// - Parameter spacing: Ground between one dot and the next, in meters.
    static func along(
        _ path: [CLLocationCoordinate2D],
        every spacing: Double
    ) -> [[CLLocationCoordinate2D]] {
        guard path.count > 1, spacing > 0 else { return [] }

        let frame = MetricFrame(origin: path[0])
        let points = path.map(frame.point(for:))

        var travelled = [0.0]
        travelled.reserveCapacity(points.count)
        for (from, to) in zip(points, points.dropFirst()) {
            travelled.append(travelled[travelled.count - 1] + from.distance(to: to))
        }

        let length = travelled[travelled.count - 1]
        guard length > 0 else { return [] }

        // Never fewer than one, and never more than the stretch has room for.
        // Forcing a minimum onto a stretch shorter than one space between dots
        // is what turns a short marked block into a blob: the dots are placed
        // closer together than they are wide, and merge.
        let count = max(1, Int((length / spacing).rounded()))
        var walker = PathWalker(points: points, travelled: travelled)

        return (0 ..< count).map { step in
            // Inset from both ends by half a space, so a dotted stretch does
            // not put a dot exactly where the solid line resumes and read as a
            // thickening rather than as a break.
            let along = length * (Double(step) + 0.5) / Double(count)
            let (point, heading) = walker.sample(at: along)

            // A stub rather than a single repeated point: a zero-length
            // polyline has no direction to cap and MapKit draws nothing at all
            // for one. Short enough that the cap is what is seen.
            return [
                frame.coordinate(for: point.offset(by: heading, times: -stubLength / 2)),
                frame.coordinate(for: point.offset(by: heading, times: stubLength / 2)),
            ]
        }
    }

    /// How long the piece of route under each dot is, in meters. Well under the
    /// width the dot is drawn at, so the round caps on its two ends overlap into
    /// one circle rather than a capsule.
    private static let stubLength = 0.35

    /// A position on the flat, in meters east and north of some origin.
    private struct Point {
        var east: Double
        var north: Double

        func distance(to other: Point) -> Double {
            hypot(other.east - east, other.north - north)
        }

        func offset(by direction: Point, times scale: Double) -> Point {
            Point(east: east + direction.east * scale, north: north + direction.north * scale)
        }
    }

    /// Meters east and north of one coordinate, and back again.
    ///
    /// An equirectangular frame pinned to the start of the stretch. A marked
    /// climb is a few hundred meters at most, over which the approximation is
    /// good to millimeters — far inside the accuracy of the nodes it is drawn
    /// from — and it makes "twelve meters further along the path" ordinary
    /// arithmetic instead of spherical trigonometry.
    private struct MetricFrame {
        private static let metersPerDegreeLatitude = 111_320.0

        let origin: CLLocationCoordinate2D
        let metersPerDegreeLongitude: Double

        init(origin: CLLocationCoordinate2D) {
            self.origin = origin
            metersPerDegreeLongitude = Self.metersPerDegreeLatitude * cos(origin.latitude * .pi / 180)
        }

        func point(for coordinate: CLLocationCoordinate2D) -> Point {
            Point(
                east: (coordinate.longitude - origin.longitude) * metersPerDegreeLongitude,
                north: (coordinate.latitude - origin.latitude) * Self.metersPerDegreeLatitude
            )
        }

        func coordinate(for point: Point) -> CLLocationCoordinate2D {
            CLLocationCoordinate2D(
                latitude: origin.latitude + point.north / Self.metersPerDegreeLatitude,
                longitude: origin.longitude + point.east / metersPerDegreeLongitude
            )
        }
    }

    /// Walks a path once, answering where it is and which way it faces at a
    /// given distance along it.
    ///
    /// Stateful because the dots are asked for in order: keeping the segment the
    /// last question landed in makes the whole stretch one pass over the path
    /// rather than a search per dot.
    private struct PathWalker {
        let points: [Point]
        let travelled: [Double]
        private var segment = 0

        init(points: [Point], travelled: [Double]) {
            self.points = points
            self.travelled = travelled
        }

        /// Where the path is at `distance`, and the unit vector it runs along.
        mutating func sample(at distance: Double) -> (point: Point, heading: Point) {
            while segment < points.count - 2, travelled[segment + 1] < distance {
                segment += 1
            }

            let from = points[segment]
            let to = points[segment + 1]
            let span = travelled[segment + 1] - travelled[segment]

            // Two nodes can be mapped on top of each other, which leaves a
            // segment with no direction. Facing north is as good an answer as
            // any for a stub a third of a meter long.
            guard span > 0 else { return (from, Point(east: 0, north: 1)) }

            let along = (distance - travelled[segment]) / span
            return (
                Point(
                    east: from.east + (to.east - from.east) * along,
                    north: from.north + (to.north - from.north) * along
                ),
                Point(east: (to.east - from.east) / span, north: (to.north - from.north) / span)
            )
        }
    }
}
