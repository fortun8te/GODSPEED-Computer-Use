import CoreGraphics

enum CursorPathPlanner {
    /// A direct trip is safe only if the line is covered by real display
    /// rectangles. A union bounding box also includes the gaps between them.
    static func isVisibleTrip(from start: CGPoint, to end: CGPoint, displays: [CGRect]) -> Bool {
        var covered: CGFloat = 0
        let spans = displays.compactMap { span(from: start, to: end, inside: $0) }
            .sorted { $0.lowerBound < $1.lowerBound }
        for span in spans {
            guard span.lowerBound <= covered + 1e-8 else { return false }
            covered = max(covered, span.upperBound)
            if covered >= 1 { return true }
        }
        return false
    }

    private static func span(from start: CGPoint, to end: CGPoint, inside rect: CGRect) -> ClosedRange<CGFloat>? {
        func axis(_ start: CGFloat, _ end: CGFloat, _ min: CGFloat, _ max: CGFloat) -> ClosedRange<CGFloat>? {
            let delta = end - start
            guard delta != 0 else { return (min...max).contains(start) ? 0...1 : nil }
            let a = (min - start) / delta
            let b = (max - start) / delta
            return Swift.min(a, b)...Swift.max(a, b)
        }
        guard let horizontal = axis(start.x, end.x, rect.minX, rect.maxX),
              let vertical = axis(start.y, end.y, rect.minY, rect.maxY) else { return nil }
        let entry = max(0, horizontal.lowerBound, vertical.lowerBound)
        let exit = min(1, horizontal.upperBound, vertical.upperBound)
        return entry <= exit ? entry...exit : nil
    }

    /// The part of the edge two displays share, or nil when they only touch at a corner or have a gap.
    private static func sharedEdge(_ first: CGRect, _ second: CGRect) -> (from: CGPoint, to: CGPoint)? {
        if first.maxX == second.minX || second.maxX == first.minX {
            let low = max(first.minY, second.minY)
            let high = min(first.maxY, second.maxY)
            guard low < high else { return nil }
            let x = first.maxX == second.minX ? first.maxX : first.minX
            return (CGPoint(x: x, y: low), CGPoint(x: x, y: high))
        }
        if first.maxY == second.minY || second.maxY == first.minY {
            let low = max(first.minX, second.minX)
            let high = min(first.maxX, second.maxX)
            guard low < high else { return nil }
            let y = first.maxY == second.minY ? first.maxY : first.minY
            return (CGPoint(x: low, y: y), CGPoint(x: high, y: y))
        }
        return nil
    }

    /// For offset adjacent displays, the point on their shared edge where the trip crosses: where the straight
    /// line meets the edge, kept a little away from the edge's ends so the curve never grazes a corner.
    /// Displays with a real gap return nil.
    static func crossing(from start: CGPoint, to end: CGPoint, between first: CGRect, and second: CGRect) -> CGPoint? {
        guard let edge = sharedEdge(first, second) else { return nil }
        let vertical = edge.from.x == edge.to.x
        let low = vertical ? edge.from.y : edge.from.x
        let high = vertical ? edge.to.y : edge.to.x
        let margin = min(24, (high - low) / 4)
        let fixed = vertical ? edge.from.x : edge.from.y
        // Where the straight line meets the edge's line; the midpoint when the trip runs along it.
        let along: CGFloat
        let (a0, a1, f0, f1) = vertical ? (start.y, end.y, start.x, end.x) : (start.x, end.x, start.y, end.y)
        if abs(f1 - f0) > 0.001 {
            along = a0 + (a1 - a0) * ((fixed - f0) / (f1 - f0)).clamped(to: 0...1)
        } else {
            along = (a0 + a1) / 2
        }
        let value = along.clamped(to: (low + margin)...(high - margin))
        return vertical ? CGPoint(x: fixed, y: value) : CGPoint(x: value, y: fixed)
    }

    /// Waypoints from `start` to `end` across `displays`: the two points when the straight trip stays on
    /// screen, otherwise the shortest chain of shared-edge crossings (any number of displays). Nil when the
    /// displays are not connected.
    static func route(from start: CGPoint, to end: CGPoint, displays: [CGRect]) -> [CGPoint]? {
        if isVisibleTrip(from: start, to: end, displays: displays) { return [start, end] }
        guard let first = displays.firstIndex(where: { $0.contains(start) }),
              let last = displays.firstIndex(where: { $0.contains(end) }), first != last else { return nil }
        // Dijkstra over displays; each hop costs the straight distance to its crossing point.
        var best: [Int: (cost: CGFloat, points: [CGPoint])] = [first: (0, [start])]
        var open: Set<Int> = [first]
        var done: Set<Int> = []
        while let current = open.min(by: { best[$0]!.cost < best[$1]!.cost }) {
            open.remove(current)
            done.insert(current)
            let here = best[current]!
            let from = here.points.last!
            if current == last {
                return here.points + [end]
            }
            for next in displays.indices where !done.contains(next) {
                guard let seam = crossing(from: from, to: end, between: displays[current], and: displays[next]) else { continue }
                let cost = here.cost + hypot(seam.x - from.x, seam.y - from.y)
                if cost < best[next]?.cost ?? .infinity {
                    best[next] = (cost, here.points + [seam])
                    open.insert(next)
                }
            }
        }
        return nil
    }

    /// A smooth path through `points` (start, crossings, end). At each crossing the curve keeps one tangent, so the
    /// cursor banks through it instead of turning a corner. With `displays`, every leg's control points stay on
    /// the display that leg runs on, so the whole curve stays on screen.
    static func through(_ points: [CGPoint], displays: [CGRect]?) -> CursorMotionPath {
        guard points.count > 2 else {
            let start = points.first ?? .zero
            let end = points.last ?? start
            let c1 = CGPoint(x: start.x + (end.x - start.x) / 3, y: start.y + (end.y - start.y) / 3)
            let c2 = CGPoint(x: start.x + (end.x - start.x) * 2 / 3, y: start.y + (end.y - start.y) * 2 / 3)
            return CursorMotionPath(start: start, end: end, segments: [CursorMotionSegment(end: end, control1: c1, control2: c2)])
        }
        func length(_ a: CGPoint, _ b: CGPoint) -> CGFloat { hypot(b.x - a.x, b.y - a.y) }
        func display(for a: CGPoint, _ b: CGPoint) -> CGRect? {
            let middle = CGPoint(x: (a.x + b.x) / 2, y: (a.y + b.y) / 2)
            return displays?.first { $0.insetBy(dx: -0.5, dy: -0.5).contains(middle) }
        }
        func inside(_ point: CGPoint, _ rect: CGRect?) -> Bool {
            rect.map { $0.insetBy(dx: -0.5, dy: -0.5).contains(point) } ?? true
        }
        // Handles at each interior point: (incoming control, outgoing control).
        var handles: [(into: CGPoint, out: CGPoint)] = []
        for index in 1..<(points.count - 1) {
            let previous = points[index - 1], point = points[index], next = points[index + 1]
            let before = display(for: previous, point), after = display(for: point, next)
            var chord = CGVector(dx: next.x - previous.x, dy: next.y - previous.y)
            let chordLength = max(hypot(chord.dx, chord.dy), 0.001)
            chord = CGVector(dx: chord.dx / chordLength, dy: chord.dy / chordLength)
            // Across the shared edge, for when the smooth direction would leave a display.
            var across = chord
            if let before, let after, let edge = sharedEdge(before, after) {
                across = edge.from.x == edge.to.x
                    ? CGVector(dx: after.midX > before.midX ? 1 : -1, dy: 0)
                    : CGVector(dx: 0, dy: after.midY > before.midY ? 1 : -1)
            }
            let reach = min(length(previous, point), length(point, next)) * 0.3
            var chosen: (CGPoint, CGPoint)?
            for direction in [chord, across] {
                var size = reach
                for _ in 0..<5 {
                    let into = CGPoint(x: point.x - direction.dx * size, y: point.y - direction.dy * size)
                    let out = CGPoint(x: point.x + direction.dx * size, y: point.y + direction.dy * size)
                    if inside(into, before), inside(out, after) { chosen = (into, out); break }
                    size /= 2
                }
                if chosen != nil { break }
            }
            handles.append(chosen ?? (point, point))
        }
        var segments: [CursorMotionSegment] = []
        for index in 0..<(points.count - 1) {
            let a = points[index], b = points[index + 1]
            let c1 = index == 0
                ? CGPoint(x: a.x + (b.x - a.x) / 3, y: a.y + (b.y - a.y) / 3)
                : handles[index - 1].out
            let c2 = index == points.count - 2
                ? CGPoint(x: b.x - (b.x - a.x) / 3, y: b.y - (b.y - a.y) / 3)
                : handles[index].into
            segments.append(CursorMotionSegment(end: b, control1: c1, control2: c2))
        }
        return CursorMotionPath(start: points[0], end: points[points.count - 1], segments: segments)
    }

    /// One shallow arc from `start` to `end`. The bend grows smoothly with distance (none for short hops, the
    /// full bend from `visualCursorFullBendDistance`), so there is no visible change of style at any distance.
    /// `startTangent`, from a cursor that is already moving, makes the arc leave in that direction with no kink.
    static func plan(start: CGPoint, end: CGPoint, bounds: CGRect?, startForward: CGVector, restForward: CGVector,
                     startTangent: CGVector? = nil)
        -> (path: CursorMotionPath, length: CGFloat) {
        let dx = end.x - start.x
        let dy = end.y - start.y
        let distance = hypot(dx, dy)
        let normal = distance > 0 ? CGVector(dx: -dy / distance, dy: dx / distance) : .zero
        let ramp = ((distance - visualCursorStraightDistance)
            / (visualCursorFullBendDistance - visualCursorStraightDistance)).clamped(to: 0...1)
        let bend = min(distance / 8, 64) * ramp * ramp * (3 - 2 * ramp)
        let visibleBounds = bounds.flatMap { $0.contains(start) && $0.contains(end) ? $0 : nil }

        /// Shortens only the part of `offset` that would leave the display, so the convex hull of the controls
        /// (and with it the whole curve) stays on screen.
        func keepInside(_ base: CGPoint, offset: CGVector) -> CGPoint {
            guard let visibleBounds else { return CGPoint(x: base.x + offset.dx, y: base.y + offset.dy) }
            let roomX = offset.dx < 0 ? base.x - visibleBounds.minX : visibleBounds.maxX - base.x
            let roomY = offset.dy < 0 ? base.y - visibleBounds.minY : visibleBounds.maxY - base.y
            let scale = max(0, min(1, offset.dx == 0 ? 1 : roomX / abs(offset.dx), offset.dy == 0 ? 1 : roomY / abs(offset.dy)))
            return CGPoint(x: base.x + offset.dx * scale, y: base.y + offset.dy * scale)
        }

        func control(_ fraction: CGFloat, heading: CGVector) -> CGPoint {
            let onLine = CGPoint(x: start.x + dx * fraction, y: start.y + dy * fraction)
            let lateral = (heading.dx * normal.dx + heading.dy * normal.dy).clamped(to: -1...1)
            return keepInside(onLine, offset: CGVector(dx: normal.dx * bend * lateral, dy: normal.dy * bend * lateral))
        }

        var first = control(1 / 3, heading: startForward)
        let second = control(2 / 3, heading: restForward)
        if let startTangent {
            let speed = hypot(startTangent.dx, startTangent.dy)
            if speed > 0.001 {
                let reach = distance / 3
                first = keepInside(start, offset: CGVector(dx: startTangent.dx / speed * reach, dy: startTangent.dy / speed * reach))
            }
        }
        let path = CursorMotionPath(
            start: start,
            end: end,
            startControl: first,
            endControl: second,
            segments: [CursorMotionSegment(end: end, control1: first, control2: second)]
        )
        let controlLength = hypot(first.x - start.x, first.y - start.y)
            + hypot(second.x - first.x, second.y - first.y)
            + hypot(end.x - second.x, end.y - second.y)
        return (path, (distance + controlLength) / 2)
    }
}
