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

    /// For offset adjacent displays, connect the two in-display legs at the
    /// closest point on their shared edge. Displays with a real gap return nil.
    static func crossing(from start: CGPoint, to end: CGPoint, between first: CGRect, and second: CGRect) -> CGPoint? {
        if first.maxX == second.minX || second.maxX == first.minX {
            let low = max(first.minY, second.minY)
            let high = min(first.maxY, second.maxY)
            guard low < high else { return nil }
            let x = first.maxX == second.minX ? first.maxX : first.minX
            return CGPoint(x: x, y: ((start.y + end.y) / 2).clamped(to: low...high))
        }
        if first.maxY == second.minY || second.maxY == first.minY {
            let low = max(first.minX, second.minX)
            let high = min(first.maxX, second.maxX)
            guard low < high else { return nil }
            let y = first.maxY == second.minY ? first.maxY : first.minY
            return CGPoint(x: ((start.x + end.x) / 2).clamped(to: low...high), y: y)
        }
        return nil
    }

    static func plan(start: CGPoint, end: CGPoint, bounds: CGRect?, startForward: CGVector, restForward: CGVector)
        -> (path: CursorMotionPath, length: CGFloat) {
        let dx = end.x - start.x
        let dy = end.y - start.y
        let distance = hypot(dx, dy)
        let normal = distance > 0 ? CGVector(dx: -dy / distance, dy: dx / distance) : .zero
        let bend = min(distance / 8, 64)
        let visibleBounds = bounds.flatMap { $0.contains(start) && $0.contains(end) ? $0 : nil }

        func control(_ fraction: CGFloat, heading: CGVector) -> CGPoint {
            let onLine = CGPoint(x: start.x + dx * fraction, y: start.y + dy * fraction)
            let lateral = (heading.dx * normal.dx + heading.dy * normal.dy).clamped(to: -1...1)
            let offset = CGVector(dx: normal.dx * bend * lateral, dy: normal.dy * bend * lateral)
            guard let visibleBounds else {
                return CGPoint(x: onLine.x + offset.dx, y: onLine.y + offset.dy)
            }
            // Shorten only the sideways movement. The controls keep their order
            // along the trip, and their convex hull remains on-screen.
            let roomX = offset.dx < 0 ? onLine.x - visibleBounds.minX : visibleBounds.maxX - onLine.x
            let roomY = offset.dy < 0 ? onLine.y - visibleBounds.minY : visibleBounds.maxY - onLine.y
            let scale = max(0, min(1, offset.dx == 0 ? 1 : roomX / abs(offset.dx), offset.dy == 0 ? 1 : roomY / abs(offset.dy)))
            return CGPoint(x: onLine.x + offset.dx * scale, y: onLine.y + offset.dy * scale)
        }

        let first = control(1 / 3, heading: startForward)
        let second = control(2 / 3, heading: restForward)
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
