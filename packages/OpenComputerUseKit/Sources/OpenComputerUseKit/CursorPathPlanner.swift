import CoreGraphics

enum CursorPathPlanner {
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
