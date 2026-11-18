import AppKit
import Foundation
import ScreenCaptureKit

/// Keeps a recent picture of the screen under the cursor window, so the glass cursor can show what is beneath it
/// slightly enlarged, as a lens does. Entirely optional: with no screen recording permission, on any failure, or
/// with `OPEN_COMPUTER_USE_CURSOR_LENS=0`, nothing is captured and the cursor is simply see-through.
final class CursorBackdrop: @unchecked Sendable {
    static let shared = CursorBackdrop()

    static let enabled: Bool = {
        let raw = (GodspeedSettings.environment["OPEN_COMPUTER_USE_CURSOR_LENS"] ?? "").lowercased()
        return !["0", "false", "off", "no"].contains(raw)
    }()

    /// A picture older than this is not drawn (the screen may have changed under the cursor).
    static let maxAge: TimeInterval = 0.9
    /// The least time between two captures.
    static let minInterval: TimeInterval = 0.3
    /// How far around the cursor window one capture reaches, so short moves stay inside it.
    static let margin: CGFloat = 70

    private let lock = NSLock()
    private var image: CGImage?
    private var rect: CGRect = .zero        // AppKit screen coordinates
    private var takenAt = Date.distantPast
    private var busy = false
    private var lastRequest = Date.distantPast
    private var offUntil = Date.distantPast

    /// The picture and where it sits relative to `windowFrame`'s origin; nil when there is none that is fresh
    /// and covers the middle of the window (where the pointer is drawn).
    func current(for windowFrame: CGRect) -> (image: CGImage, rect: CGRect)? {
        lock.lock(); defer { lock.unlock() }
        guard let image, Date().timeIntervalSince(takenAt) <= Self.maxAge,
              rect.contains(windowFrame.insetBy(dx: windowFrame.width * 0.3, dy: windowFrame.height * 0.3)) else { return nil }
        return (image, rect.offsetBy(dx: -windowFrame.minX, dy: -windowFrame.minY))
    }

    /// Takes a new picture when the current one is old or the cursor has left it. `onUpdate` runs (on any
    /// thread) once a new picture is in place.
    func refreshIfNeeded(windowFrame: CGRect, windowNumber: Int, onUpdate: @escaping @Sendable () -> Void) {
        guard Self.enabled else { return }
        let now = Date()
        lock.lock()
        let covered = image != nil && rect.contains(windowFrame.insetBy(dx: windowFrame.width * 0.3, dy: windowFrame.height * 0.3))
        let fresh = now.timeIntervalSince(takenAt) <= Self.maxAge * 0.75
        guard !busy, now >= offUntil, now.timeIntervalSince(lastRequest) >= Self.minInterval, !(covered && fresh) else {
            lock.unlock(); return
        }
        busy = true
        lastRequest = now
        lock.unlock()

        guard CGPreflightScreenCaptureAccess(),
              let screen = NSScreen.screens.first(where: { $0.frame.contains(CGPoint(x: windowFrame.midX, y: windowFrame.midY)) }),
              let displayID = (screen.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber)?.uint32Value else {
            finish(nil, .zero, pause: 30); return
        }
        let wanted = windowFrame.insetBy(dx: -Self.margin, dy: -Self.margin).intersection(screen.frame)
        guard wanted.width > 4, wanted.height > 4 else { finish(nil, .zero, pause: 1); return }
        let local = CGRect(x: wanted.minX - screen.frame.minX, y: screen.frame.maxY - wanted.maxY, width: wanted.width, height: wanted.height)
        let scale = screen.backingScaleFactor

        Task.detached(priority: .utility) { [self] in
            do {
                let content = try await SCShareableContent.excludingDesktopWindows(false, onScreenWindowsOnly: true)
                guard let display = content.displays.first(where: { $0.displayID == displayID }) else {
                    self.finish(nil, .zero, pause: 5); return
                }
                let own = content.windows.filter { Int($0.windowID) == windowNumber }
                let configuration = SCStreamConfiguration()
                configuration.sourceRect = local
                configuration.width = Int(ceil(local.width * scale))
                configuration.height = Int(ceil(local.height * scale))
                configuration.showsCursor = false
                let picture = try await SCScreenshotManager.captureImage(
                    contentFilter: SCContentFilter(display: display, excludingWindows: own), configuration: configuration)
                self.finish(picture, wanted, pause: 0)
                onUpdate()
            } catch {
                self.finish(nil, .zero, pause: 30)
            }
        }
    }

    private func finish(_ picture: CGImage?, _ area: CGRect, pause: TimeInterval) {
        lock.lock()
        if let picture { image = picture; rect = area; takenAt = Date() }
        if pause > 0 { offUntil = Date().addingTimeInterval(pause) }
        busy = false
        lock.unlock()
    }
}
