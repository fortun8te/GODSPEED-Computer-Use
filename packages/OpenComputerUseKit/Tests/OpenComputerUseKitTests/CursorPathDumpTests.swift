import AppKit
import XCTest
@testable import OpenComputerUseKit

/// GODSPEED_PATH_DUMP=file.json writes sample glides for plotting; skipped otherwise.
final class CursorPathDumpTests: XCTestCase {
    func testDumpPlannedPaths() throws {
        guard let out = ProcessInfo.processInfo.environment["GODSPEED_PATH_DUMP"] else { throw XCTSkip("dump only") }
        let base = visualCursorRenderBaseHeading()
        let restAngle = visualCursorAppKitForwardHeading(renderRotation: 0)
        let rest = CGVector(dx: cos(restAngle), dy: sin(restAngle))
        let bounds = CGRect(x: 0, y: 0, width: 1600, height: 1000)
        let start = CGPoint(x: 800, y: 500)
        var rows: [[String: Any]] = []
        for (dx, dy) in [(520.0, 0.0), (-520.0, 0.0), (0.0, 380.0), (0.0, -380.0), (420.0, -320.0), (-420.0, 320.0), (420.0, 320.0), (-420.0, -320.0), (110.0, 40.0)] {
            let end = CGPoint(x: start.x + dx, y: start.y + dy)
            let glide = CursorGlide(start: start, end: end, startVelocity: .zero, startForward: rest, restForward: rest,
                                    bounds: bounds, planned: true, startTime: 0, speed: 1, queuedBehind: 0)
            var samples: [[Double]] = []
            for i in 0...24 {
                let t = glide.duration * Double(i) / 24
                let p = glide.point(at: t)
                var rot: CGFloat = glide.tilt(at: t)
                if let tan = glide.tangent(at: t) { rot = CursorPoseDynamics.normalize(-base - atan2(tan.dy, tan.dx)) }
                samples.append([Double(p.x), Double(p.y), Double(rot)])
            }
            rows.append(["ms": Int(glide.duration * 1000), "samples": samples])
        }
        try JSONSerialization.data(withJSONObject: rows).write(to: URL(fileURLWithPath: out))
    }
}
