//  Zigzag.swift
//
//  Redrawing a stretch of route as a tight triangle wave along its own line.
//
//  This is how a steep stretch is marked on the map. It replaces a colored
//  overlay, and the change is a deliberate one about what the mark says: a
//  second color said "this part of your route is dangerous", which is a claim
//  about the ground, while a wave in the route's own color says "the line does
//  not run straight through here" — which is a claim about the walk, and is the
//  one the app can actually support. It also leaves the emerald meaning exactly
//  what it means everywhere else in the app: this is your route.
//
//  The wave is sized in points on the screen rather than in meters on the
//  ground, and that is the whole reason this is computed here instead of once
//  when the route is found. A wave a few meters wide is invisible at the zoom a
//  cross-town route is framed at and enormous at the zoom a single block is
//  read at; a wave a few points wide looks the same at both, which is what a
//  mark has to do to stay a mark.

import CoreLocation
import Foundation

/// A stretch of route drawn as a triangle wave that follows it.
enum Zigzag {
    /// The wave along `path`, or `path` itself when there is not enough of it
    /// to turn.
    ///
    /// Both ends sit exactly on the path, so the wave joins the line it marks
    /// rather than starting beside it. Everything between them alternates to
    /// either side, half a wavelength apart.
    ///
    /// - Parameters:
    ///   - amplitude: How far to either side the wave reaches, in meters.
    ///   - wavelength: Ground covered by one full left-right cycle, in meters.
    static func along(
        _ path: [CLLocationCoordinate2D],
        amplitude: Double,
        wavelength: Double
    ) -> [CLLocationCoordinate2D] {
        guard path.count > 1, amplitude > 0, wavelength > 0 else { return path }

        let frame = MetricFrame(origin: path[0])
        let points = path.map(frame.point(for:))

        // Distance to each point from the start, which is what turns "half a
        // wavelength further along" into a position on a path made of segments
        // of no particular length.
        var travelled = [0.0]
        travelled.reserveCapacity(points.count)
        for (from, to) in zip(points, points.dropFirst()) {
            travelled.append(travelled[travelled.count - 1] + from.distance(to: to))
        }

        // A stretch too short to turn twice is drawn as it is. Half a wave is
        // not a zigzag, it is the line leaning to one side.
        let length = travelled[travelled.count - 1]
        guard length > wavelength else { return path }

        let turns = max(2, Int((length / (wavelength / 2)).rounded()))
        var walker = PathWalker(points: points, travelled: travelled)

        return (0 ... turns).map { turn in
            let (point, normal) = walker.sample(at: length * Double(turn) / Double(turns))
            return frame.coordinate(for: point.offset(by: normal, times: reach(of: turn, of: turns, amplitude)))
        }
    }

    /// How far off the line the wave sits at one of its turns.
    ///
    /// Zero at both ends and alternating in between, so the mark begins and
    /// ends on the route it belongs to.
    private static func reach(of turn: Int, of turns: Int, _ amplitude: Double) -> Double {
        guard turn > 0, turn < turns else { return 0 }
        return turn.isMultiple(of: 2) ? -amplitude : amplitude
    }

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
    /// An equirectangular frame pinned to the start of the stretch. A steep run
    /// is a few hundred meters at most, over which the approximation is good to
    /// millimeters — far inside the accuracy of the nodes it is drawn from —
    /// and it makes "half a wavelength along, an amplitude to the left" ordinary
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
    /// Stateful because the turns are asked for in order: keeping the segment
    /// the last question landed in makes the whole wave one pass over the path
    /// rather than a search per turn.
    private struct PathWalker {
        let points: [Point]
        let travelled: [Double]
        private var segment = 0

        init(points: [Point], travelled: [Double]) {
            self.points = points
            self.travelled = travelled
        }

        /// Where the path is at `distance`, and the unit vector pointing to its
        /// left.
        mutating func sample(at distance: Double) -> (point: Point, normal: Point) {
            while segment < points.count - 2, travelled[segment + 1] < distance {
                segment += 1
            }

            let from = points[segment]
            let to = points[segment + 1]
            let span = travelled[segment + 1] - travelled[segment]

            // Two nodes can be mapped on top of each other, which leaves a
            // segment with no direction to be perpendicular to. Facing north is
            // as good an answer as any and is never reached by a real street.
            guard span > 0 else { return (from, Point(east: -1, north: 0)) }

            let along = (distance - travelled[segment]) / span
            return (
                Point(
                    east: from.east + (to.east - from.east) * along,
                    north: from.north + (to.north - from.north) * along
                ),
                Point(east: -(to.north - from.north) / span, north: (to.east - from.east) / span)
            )
        }
    }
}
