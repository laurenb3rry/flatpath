//  Maneuvers.swift
//
//  Turns a route into instructions a walker can act on, and tracks which one
//  they are on as their position updates.
//
//  A route arrives as a few hundred graph edges, most of them one block long.
//  Reading those out one at a time would bury the two or three moments that
//  actually matter, so consecutive edges fold into a single instruction for as
//  long as the walk carries straight on down the same street. A new instruction
//  is emitted only where the heading swings past what a walker would call a
//  turn, or where the street underfoot takes a different name -- and even then
//  not for the jog across an intersection, which is a corner in the data and
//  part of carrying straight on to the person walking it.
//
//  Most of the network's edges carry no name at all -- crossings, alley
//  cut-throughs, park paths and the links between stretches of sidewalk are
//  unnamed in the source data, and they outnumber the named edges two to one.
//  Instructions never invent a name for them. An unnamed stretch keeps its verb
//  and drops the street clause, so it reads "Turn left" rather than "Turn left
//  onto the path": a verb is something the walker can check against the corner
//  in front of them, and a name that no street sign carries is not.

import CoreLocation
import Foundation

// MARK: - The vocabulary

/// Which way a maneuver goes, in the terms an instruction says it in.
///
/// The bands are cut where the phrasing stops being true rather than at even
/// intervals: "turn left" covers most of a quarter circle because that is what
/// a walker reads a street corner as, while the slight and sharp bands are
/// narrow because they describe the cases a plain "turn" would misdescribe.
enum Turn: Equatable {
    case slightLeft
    case left
    case sharpLeft
    case around
    case sharpRight
    case right
    case slightRight

    /// Below this many degrees of heading change there is no maneuver at all.
    ///
    /// Streets are not straight lines and the graph's nodes carry meter-scale
    /// positional noise, so a block ends a few degrees off the heading it began
    /// on even when the walker has done nothing but keep going. Calling that a
    /// turn would fire an instruction on a street they never leave, which is
    /// worse than silence: it teaches them to distrust the ones that matter.
    static let straightening: Double = 25

    /// Past this, the corner is square enough to be plain "left" or "right".
    /// Below it the walker is bearing off at a fork, not turning at a corner.
    static let squaring: Double = 50

    /// Past this, the turn doubles back far enough that a walker following a
    /// plain "left" would take the wrong one of the two streets on offer.
    static let sharpening: Double = 125

    /// Past this the walk has reversed, and no turn phrasing describes it.
    static let reversal: Double = 160

    /// The turn a heading change amounts to, or `nil` when it amounts to none.
    ///
    /// `degrees` is signed clockwise: positive swings to the walker's right.
    init?(bearingChange degrees: Double) {
        let magnitude = abs(degrees)
        let isRightward = degrees > 0

        switch magnitude {
        case ..<Self.straightening:
            return nil
        case ..<Self.squaring:
            self = isRightward ? .slightRight : .slightLeft
        case ..<Self.sharpening:
            self = isRightward ? .right : .left
        case ..<Self.reversal:
            self = isRightward ? .sharpRight : .sharpLeft
        default:
            self = .around
        }
    }

    /// How the instruction opens. "Bear" rather than "slight" because it is what
    /// the walker is being asked to do, not a grade of turn.
    var verb: String {
        switch self {
        case .slightLeft: "Bear left"
        case .left: "Turn left"
        case .sharpLeft: "Take the sharp left"
        case .around: "Turn around"
        case .sharpRight: "Take the sharp right"
        case .right: "Turn right"
        case .slightRight: "Bear right"
        }
    }

    /// Whether the turn doubles back far enough that a walker could take the
    /// wrong street even when the street they are on keeps its name. This is
    /// what separates a street that bends from a street that forks.
    var isSharp: Bool {
        self == .sharpLeft || self == .sharpRight || self == .around
    }

    /// SF Symbol for the turn. The sharp turns get a plain diagonal arrow rather
    /// than a hooked one so that they read as further round than the ordinary
    /// left and right beside them.
    var symbol: String {
        switch self {
        case .slightLeft: "arrow.up.left"
        case .left: "arrow.turn.up.left"
        case .sharpLeft: "arrow.down.left"
        case .around: "arrow.uturn.down"
        case .sharpRight: "arrow.down.right"
        case .right: "arrow.turn.up.right"
        case .slightRight: "arrow.up.right"
        }
    }
}

/// A compass point, to eight-way precision.
///
/// Only the first instruction needs one. Every later maneuver is described
/// relative to the heading the walker is already on, which they can feel;
/// setting off is the one moment where there is no previous heading to turn
/// from, and "head north" is the only thing left to say.
enum Compass: String {
    case north, northeast, east, southeast, south, southwest, west, northwest

    private static let points: [Compass] = [
        .north, .northeast, .east, .southeast, .south, .southwest, .west, .northwest,
    ]

    /// The nearest of the eight points to a bearing in degrees clockwise from
    /// north. Each point owns the 45 degrees centered on it.
    init(bearing degrees: Double) {
        let sector = Int((degrees / 45).rounded()) % Self.points.count
        self = Self.points[(sector + Self.points.count) % Self.points.count]
    }

    var name: String { rawValue }
}

/// What the walker does at one point along the route.
enum ManeuverKind: Equatable {
    /// Setting off, described by compass point for want of a heading to turn from.
    case depart(Compass)
    case turn(Turn)
    /// The street changes name without the walk changing direction.
    case continueAhead
    case arrive
}

// MARK: - A step

/// One instruction, and the stretch of walking it covers.
///
/// The figures are for the stretch that *follows* the maneuver, up to the next
/// one — which is what "turn left, then 400 feet" means, and what lets the
/// remaining distance and climb be totted up from the steps still ahead.
struct ManeuverStep: Identifiable {
    /// Place in the route's list of steps, which is also its identity: the list
    /// is derived once per route and never reordered.
    let id: Int

    let kind: ManeuverKind

    /// The street this instruction puts the walker on, or `nil` where the ways
    /// it covers are unnamed. Nothing invents a name to fill this.
    let street: String?

    /// Where the maneuver happens, as a position in the route's list of nodes.
    ///
    /// A position rather than a distance from the start, so that how far along
    /// the route a maneuver sits is measured by whoever is tracking the walker,
    /// against the same polyline they are being placed on. Two measurements of
    /// the same route -- one summed from baked edge lengths, one from the drawn
    /// geometry -- disagree by a few meters over a few miles, which is enough to
    /// retire an instruction a corner early.
    let position: Int

    /// The same point as a coordinate, for putting a mark on the map and for
    /// asking how far the walker is from it.
    let coordinate: CLLocationCoordinate2D

    /// Meters from here to the next maneuver. Zero at the destination.
    let distance: Double

    /// Seconds of walking over that stretch, hill penalty excluded — the same
    /// honest figure the route cards report.
    let time: Double

    /// Meters climbed over that stretch, descents not counted against it.
    let climb: Double

    /// The heading the walker leaves on, degrees clockwise from north. The map
    /// turns to this so that the screen agrees with what is in front of them.
    let bearing: Double

    /// The instruction, as a sentence.
    ///
    /// A turn onto an unnamed way drops the street clause rather than filling it
    /// with a placeholder. A reversal drops it too: the walk is going back the
    /// way it came, so naming the street would restate what the walker has been
    /// walking down rather than telling them anything.
    var instruction: String {
        switch kind {
        case .depart(let compass):
            street.map { "Head \(compass.name) on \($0)" } ?? "Head \(compass.name)"
        case .turn(.around):
            Turn.around.verb
        case .turn(let turn):
            street.map { "\(turn.verb) onto \($0)" } ?? turn.verb
        case .continueAhead:
            street.map { "Continue onto \($0)" } ?? "Continue straight"
        case .arrive:
            "Arrive at your destination"
        }
    }

    var symbol: String {
        switch kind {
        case .depart: "figure.walk"
        case .turn(let turn): turn.symbol
        case .continueAhead: "arrow.up"
        case .arrive: "mappin.and.ellipse"
        }
    }
}

// MARK: - Derivation

enum Maneuvers {
    /// How long a stretch has to be before the walker can be asked to do
    /// something at the end of it.
    ///
    /// Crossing an intersection on a sidewalk network is a jog: out to the curb,
    /// across, and back in again, three edges and two corners covering the width
    /// of a street. Announced, each of those corners becomes an instruction that
    /// expires before it can be read. Absorbed, they become what they are to the
    /// walker -- part of carrying straight on -- and the next real corner is
    /// measured from the heading they were on before the jog rather than from
    /// whichever way they were briefly facing in the middle of the road.
    ///
    /// Named ways are exempt however short they are: a name is the strongest
    /// evidence the data offers that a stretch is a street the walker can be
    /// directed onto, and a fifty-foot named block is a real one.
    static let minimumStretch: Double = 40

    /// The instructions for a route, from setting off to arriving.
    ///
    /// Two passes over the route's edges. The first cuts it into runs of edges
    /// with nothing to say in between; the second decides which of those cuts
    /// is worth saying out loud, folding the rest back into the run before it.
    static func steps(for route: RouteOption, in graph: WalkingGraph) -> [ManeuverStep] {
        let nodes = route.nodes
        let edges = route.edges

        // A destination on top of the start: nowhere to walk, but the walker is
        // owed the one instruction that is still true. A path whose edges do not
        // line up with its nodes is not a walk at all, and yields nothing to say
        // rather than instructions for a route that was never found.
        guard let last = nodes.last, edges.count == nodes.count - 1, !edges.isEmpty else {
            return nodes.count == 1
                ? [arrival(at: nodes[0], position: 0, bearing: 0, id: 0, in: graph)]
                : []
        }

        let bearings = (0 ..< edges.count).map {
            bearing(from: nodes[$0], to: nodes[$0 + 1], in: graph)
        }

        let announced = announce(
            cut(edges, bearings: bearings, in: graph),
            edges: edges,
            bearings: bearings,
            in: graph
        )

        let steps = announced.enumerated().map { order, run in
            ManeuverStep(
                id: order,
                kind: run.kind,
                street: run.segment.street,
                position: run.segment.start,
                coordinate: coordinate(of: nodes[run.segment.start], in: graph),
                distance: total(\.edgeLength, over: run.segment.positions, of: edges, in: graph),
                time: total(\.edgeTime, over: run.segment.positions, of: edges, in: graph),
                climb: climb(over: run.segment.positions, of: edges, in: graph),
                bearing: bearings[run.segment.start]
            )
        }

        return steps + [
            arrival(
                at: last,
                position: nodes.count - 1,
                bearing: bearings[bearings.count - 1],
                id: steps.count,
                in: graph
            )
        ]
    }

    /// A run of edges the walker covers under one instruction.
    private struct Segment {
        /// Half-open range of positions in the route's edge list.
        var start: Int
        var end: Int

        /// The street the run is called by: the first named way in it, since a
        /// run that opens on an unnamed crossing and continues down a named
        /// street is a walk down that street as far as the walker is concerned.
        var street: String?

        /// Positions in the route's edge list, not graph edge indices.
        var positions: Range<Int> { start ..< end }
    }

    /// First pass: cut the route wherever the heading turns or the street
    /// underfoot takes a name it did not have before.
    ///
    /// A turn that keeps the same street name is a bend in the street, not a
    /// maneuver, and passes without a cut -- otherwise a walker climbing a
    /// street that curves is told to turn onto the street they are already on.
    /// The exception is a turn sharp enough to double back, where the same name
    /// can lead in two directions and the walker needs to be told which.
    private static func cut(_ edges: [Int], bearings: [Double], in graph: WalkingGraph) -> [Segment] {
        var segments = [Segment(start: 0, end: edges.count, street: name(of: edges[0], in: graph))]

        for joint in 1 ..< edges.count {
            let turn = Turn(bearingChange: change(from: bearings[joint - 1], to: bearings[joint]))
            let street = name(of: edges[joint], in: graph)
            let current = segments[segments.count - 1].street

            let bends = street != nil && street == current && !(turn?.isSharp ?? false)
            let renamed = street != nil && current != nil && street != current

            guard !bends, turn != nil || renamed else {
                // An unnamed run takes the first name it meets. Nothing is
                // overwritten: a run that already has a name keeps it, so the
                // crossing between two streets is compared against the street
                // the walker set out on and yields the instruction onto the next.
                if current == nil {
                    segments[segments.count - 1].street = street
                }
                continue
            }

            segments[segments.count - 1].end = joint
            segments.append(Segment(start: joint, end: edges.count, street: street))
        }

        return segments
    }

    /// Second pass: keep the cuts a walker can act on, fold the rest away.
    ///
    /// Each surviving cut is judged against the heading of the last instruction
    /// actually given rather than the heading of the edge before it. Across an
    /// absorbed jog those differ, and the first is the one the walker is holding
    /// in their head: they were told to go left, so the next thing they are told
    /// has to be measured from left.
    private static func announce(
        _ segments: [Segment],
        edges: [Int],
        bearings: [Double],
        in graph: WalkingGraph
    ) -> [(segment: Segment, kind: ManeuverKind)] {
        var announced = [(segment: segments[0], kind: ManeuverKind.depart(Compass(bearing: bearings[0])))]

        /// The heading held across a jog, or `nil` to measure the next turn
        /// against the edge that runs into it.
        var reference: Double?

        for segment in segments.dropFirst() {
            let incoming = reference ?? bearings[segment.start - 1]
            let turn = Turn(bearingChange: change(from: incoming, to: bearings[segment.start]))

            let previous = announced[announced.count - 1].segment
            let renamed = segment.street != nil && segment.street != previous.street
            let isConnector =
                segment.street == nil
                && total(\.edgeLength, over: segment.positions, of: edges, in: graph) < minimumStretch

            guard turn != nil || renamed, !isConnector else {
                announced[announced.count - 1].segment.end = segment.end
                // A jog's headings are noise and the pre-jog heading stands. A
                // stretch absorbed for having nothing to announce is real
                // walking, though, and the heading it ends on is where the
                // walker genuinely faces.
                reference = isConnector ? incoming : nil
                continue
            }

            announced.append((segment, turn.map(ManeuverKind.turn) ?? .continueAhead))
            reference = nil
        }

        return announced
    }

    private static func arrival(
        at node: Int,
        position: Int,
        bearing: Double,
        id: Int,
        in graph: WalkingGraph
    ) -> ManeuverStep {
        ManeuverStep(
            id: id,
            kind: .arrive,
            street: nil,
            position: position,
            coordinate: coordinate(of: node, in: graph),
            distance: 0,
            time: 0,
            climb: 0,
            bearing: bearing
        )
    }

    /// An edge's street, or `nil` where it has none. The graph stores unnamed
    /// ways as the empty string; the rest of this file wants the absence to be
    /// impossible to print by accident.
    private static func name(of edge: Int, in graph: WalkingGraph) -> String? {
        let name = graph.name(of: edge)
        return name.isEmpty ? nil : name
    }

    private static func coordinate(of node: Int, in graph: WalkingGraph) -> CLLocationCoordinate2D {
        CLLocationCoordinate2D(latitude: graph.latitudes[node], longitude: graph.longitudes[node])
    }

    /// Sums a per-edge figure over a run of the route, addressed by position in
    /// the route rather than by graph edge index.
    private static func total(
        _ attribute: KeyPath<WalkingGraph, [Float]>,
        over positions: Range<Int>,
        of edges: [Int],
        in graph: WalkingGraph
    ) -> Double {
        let values = graph[keyPath: attribute]
        return positions.reduce(0) { $0 + Double(values[edges[$1]]) }
    }

    /// Only the ascents, for the same reason the route cards count only those:
    /// the walk down the far side does not give back the climb up this one.
    private static func climb(over positions: Range<Int>, of edges: [Int], in graph: WalkingGraph) -> Double {
        positions.reduce(0) { $0 + max(0, Double(graph.edgeDeltaElevation[edges[$1]])) }
    }

    // MARK: Geometry

    /// Initial bearing along an edge, degrees clockwise from north.
    ///
    /// The initial bearing rather than an average one: what the instruction is
    /// comparing is the direction the walker arrives at a corner against the
    /// direction they would leave it, and both are read at the corner itself.
    private static func bearing(from origin: Int, to destination: Int, in graph: WalkingGraph) -> Double {
        let fromLatitude = graph.latitudes[origin] * .pi / 180
        let toLatitude = graph.latitudes[destination] * .pi / 180
        let longitudeDelta = (graph.longitudes[destination] - graph.longitudes[origin]) * .pi / 180

        let easting = sin(longitudeDelta) * cos(toLatitude)
        let northing =
            cos(fromLatitude) * sin(toLatitude)
            - sin(fromLatitude) * cos(toLatitude) * cos(longitudeDelta)

        let degrees = atan2(easting, northing) * 180 / .pi
        return degrees < 0 ? degrees + 360 : degrees
    }

    /// Signed heading change between two bearings, wrapped into (-180, 180] so
    /// that a swing rightward is positive and the wrap at north is not read as
    /// a turn all the way around.
    private static func change(from: Double, to: Double) -> Double {
        (to - from + 540).truncatingRemainder(dividingBy: 360) - 180
    }
}

// MARK: - Following the steps

/// Which instruction the walker is on, advanced by their position.
///
/// The step held is the maneuver *ahead* — the thing about to be asked of them,
/// which is what an instruction on screen has to be. Walking past a maneuver is
/// what moves the instruction on, so the walker is never told to turn at a
/// corner they have already gone through, and never has one taken off the
/// screen while it is still in front of them.
///
/// "Past" is measured along the route rather than as the crow flies. Standing at
/// a corner and having gone round it put the walker in the same place to within
/// the error of a city fix, and only the distance walked tells the two apart —
/// a route that starts a few paces short of its first turn would otherwise open
/// by announcing the second one.
struct ManeuverFollower {
    let steps: [ManeuverStep]

    /// The route as drawn, one coordinate per node. `ManeuverStep.position`
    /// indexes into this, so it has to be the same list of nodes the steps were
    /// derived from, in the same order.
    private let coordinates: [CLLocationCoordinate2D]

    /// Meters from the start of the route to each node along it.
    private let distancesAlong: [Double]

    /// The maneuver being approached.
    private(set) var index = 0

    /// Meters walked, or `nil` until the first fix arrives.
    private(set) var progress: Double?

    /// The last position taken, for the questions that are about where the
    /// walker actually is rather than how far they have come.
    private(set) var fix: CLLocationCoordinate2D?

    /// How near the destination counts as being at it.
    ///
    /// A phone's fix in a city with hills and tall buildings is good to roughly
    /// ten meters and occasionally worse. Tighter than this and a walker
    /// standing on the doorstep is still being told to keep going; much wider
    /// and the screen congratulates them a house or two early.
    static let arrivalRadius: Double = 25

    init(steps: [ManeuverStep], coordinates: [CLLocationCoordinate2D]) {
        self.steps = steps
        self.coordinates = coordinates

        var running = 0.0
        var distances = [Double]()
        distances.reserveCapacity(coordinates.count)
        for (from, to) in zip(coordinates, coordinates.dropFirst()) {
            distances.append(running)
            running += from.distance(to: to)
        }
        distances.append(running)
        distancesAlong = distances
    }

    /// The instruction on screen, or `nil` for a route with no steps at all.
    var pending: ManeuverStep? {
        steps.indices.contains(index) ? steps[index] : nil
    }

    /// The one after it, for the "then" line.
    var following: ManeuverStep? {
        steps.indices.contains(index + 1) ? steps[index + 1] : nil
    }

    /// The step whose stretch the walker is on now — the one whose instruction
    /// they have already carried out. `nil` before the first maneuver is
    /// reached, when there is nothing behind them yet.
    var underfoot: ManeuverStep? {
        index > 0 ? steps[index - 1] : nil
    }

    /// True once the last maneuver — arrival — is the one being approached.
    var isFinishing: Bool { index == steps.count - 1 }

    /// True once the walker is standing at the destination.
    ///
    /// Straight-line, unlike everything else here: this is the one question
    /// about where they physically are rather than how far they have walked,
    /// and someone who has stepped off the route into the doorway they were
    /// heading for has arrived.
    var hasArrived: Bool {
        guard isFinishing, let fix, let destination = steps.last?.coordinate else { return false }
        return fix.distance(to: destination) <= Self.arrivalRadius
    }

    /// Meters still to walk to the maneuver ahead, or `nil` before the first fix.
    var distanceToPending: Double? {
        guard let progress, let pending else { return nil }
        return max(0, distanceAlong(pending) - progress)
    }

    var distanceRemaining: Double { remainder(of: \.distance) }
    var timeRemaining: Double { remainder(of: \.time) }

    /// Meters still to climb. The figure the app exists for, and the one a
    /// walker part-way up a hill most wants to know is nearly spent.
    var climbRemaining: Double { remainder(of: \.climb) }

    /// Take a new position: move the instruction on if the walker has gone past
    /// the corner it names.
    ///
    /// Every maneuver behind them is skipped, not just the next one. Fixes
    /// arrive every few meters at a walking pace, but they also arrive after a
    /// tunnel, a stall, or a phone in a pocket, and a walker two corners further
    /// on than the screen says needs the instruction to catch up to them rather
    /// than to wait for them to come back.
    ///
    /// The index only ever rises. A route that doubles back on itself, or a fix
    /// that jitters across a corner, must not push the instruction backwards
    /// onto something already done.
    mutating func advance(to coordinate: CLLocationCoordinate2D) {
        guard !steps.isEmpty, coordinates.count > 1 else { return }

        fix = coordinate
        let walked = distanceAlong(coordinate)
        progress = walked

        var reached = index
        while reached < steps.count - 1, distanceAlong(steps[reached]) <= walked {
            reached += 1
        }
        index = max(index, reached)
    }

    /// Meters from the start of the route to a maneuver.
    private func distanceAlong(_ step: ManeuverStep) -> Double {
        distancesAlong.indices.contains(step.position) ? distancesAlong[step.position] : 0
    }

    /// How far along the route a position is, by the nearest point on it.
    ///
    /// A scan of every segment. The route is a few hundred points and this runs
    /// once per fix — every few seconds at a walking pace — so there is nothing
    /// here worth indexing for, and the alternative of searching only near the
    /// last known progress would be a structure to maintain in exchange for
    /// arithmetic that does not show up in a trace.
    private func distanceAlong(_ coordinate: CLLocationCoordinate2D) -> Double {
        var walked = 0.0
        var nearest = Double.greatestFiniteMagnitude

        for position in 0 ..< coordinates.count - 1 {
            let (offset, along) = coordinate.projection(
                onto: coordinates[position],
                coordinates[position + 1]
            )
            if offset < nearest {
                nearest = offset
                walked = distancesAlong[position] + along
            }
        }

        return walked
    }

    /// A per-step figure summed over everything still to walk: all of each step
    /// from the pending maneuver onward, plus the unwalked share of the stretch
    /// currently underfoot.
    ///
    /// That share is measured by distance and applied to all three figures, so
    /// they shrink together and describe the same remaining walk.
    private func remainder(of figure: KeyPath<ManeuverStep, Double>) -> Double {
        guard !steps.isEmpty else { return 0 }

        let ahead = steps[index...].reduce(0) { $0 + $1[keyPath: figure] }

        guard let underfoot, underfoot.distance > 0 else { return ahead }
        let left = distanceToPending ?? underfoot.distance
        return ahead + underfoot[keyPath: figure] * min(1, left / underfoot.distance)
    }
}

/// Flat-earth geometry, by the same approximation the graph uses to snap a
/// coordinate to a node. Over the distances these are asked about it differs
/// from the great-circle figure by millimeters, and it costs a handful of
/// multiplications rather than a `CLLocation` allocation on every fix.
private extension CLLocationCoordinate2D {
    static let metersPerDegree: Double = 111_320

    func distance(to other: CLLocationCoordinate2D) -> Double {
        let northing = (other.latitude - latitude) * Self.metersPerDegree
        let easting =
            (other.longitude - longitude) * Self.metersPerDegree * cos(latitude * .pi / 180)
        return (northing * northing + easting * easting).squareRoot()
    }

    /// How far this point lies off a segment, and how far along that segment its
    /// nearest point sits. Both in meters, with the nearest point clamped to the
    /// segment's ends so that a walker level with the middle of a block is
    /// placed in the middle of it rather than off the end of the line.
    func projection(
        onto start: CLLocationCoordinate2D,
        _ end: CLLocationCoordinate2D
    ) -> (offset: Double, along: Double) {
        let eastingScale = Self.metersPerDegree * cos(start.latitude * .pi / 180)

        let pointEasting = (longitude - start.longitude) * eastingScale
        let pointNorthing = (latitude - start.latitude) * Self.metersPerDegree
        let segmentEasting = (end.longitude - start.longitude) * eastingScale
        let segmentNorthing = (end.latitude - start.latitude) * Self.metersPerDegree

        let lengthSquared = segmentEasting * segmentEasting + segmentNorthing * segmentNorthing
        guard lengthSquared > 0 else {
            return ((pointEasting * pointEasting + pointNorthing * pointNorthing).squareRoot(), 0)
        }

        let fraction = min(
            1,
            max(0, (pointEasting * segmentEasting + pointNorthing * segmentNorthing) / lengthSquared)
        )
        let offEasting = pointEasting - segmentEasting * fraction
        let offNorthing = pointNorthing - segmentNorthing * fraction

        return (
            offset: (offEasting * offEasting + offNorthing * offNorthing).squareRoot(),
            along: fraction * lengthSquared.squareRoot()
        )
    }
}
