import CoreGraphics
import XCTest
@testable import OpenComputerUseKit

final class SkyKeyRoutingTests: XCTestCase {
    private func context(
        backgroundOnly: Bool = false, frontmost: Bool = false, borrowed: Bool = false,
        sky: Bool = true, window: Bool = true, bundle: String? = "com.example.App",
        sheet: Bool = false, menuDialog: Bool = false
    ) -> KeyRouteContext {
        KeyRouteContext(
            backgroundOnly: backgroundOnly, targetIsFrontmost: frontmost, borrowed: borrowed,
            skyLightAvailable: sky, hasTargetWindow: window, bundleIdentifier: bundle,
            focusInSheetOrDialog: sheet, opensDialogFromMenu: menuDialog
        )
    }

    func testBackgroundAppUsesSkyLightWithoutBackgroundOnlyMode() {
        XCTAssertTrue(shouldRouteKeysThroughSkyLight(context()))
    }

    func testFrontmostOrBorrowedUsesNormalRoute() {
        XCTAssertFalse(shouldRouteKeysThroughSkyLight(context(frontmost: true)))
        XCTAssertFalse(shouldRouteKeysThroughSkyLight(context(borrowed: true)))
        XCTAssertFalse(shouldRouteKeysThroughSkyLight(context(backgroundOnly: true, borrowed: true)))
    }

    func testMissingSkyLightOrWindowFallsBack() {
        XCTAssertFalse(shouldRouteKeysThroughSkyLight(context(sky: false)))
        XCTAssertFalse(shouldRouteKeysThroughSkyLight(context(window: false)))
    }

    func testSheetsFinderAndDialogMenusKeepBorrowOutsideBackgroundOnly() {
        XCTAssertFalse(shouldRouteKeysThroughSkyLight(context(sheet: true)))
        XCTAssertFalse(shouldRouteKeysThroughSkyLight(context(bundle: "com.apple.finder")))
        XCTAssertFalse(shouldRouteKeysThroughSkyLight(context(menuDialog: true)))
    }

    func testBackgroundOnlyAlwaysUsesSkyLightForBackgroundApp() {
        XCTAssertTrue(shouldRouteKeysThroughSkyLight(context(backgroundOnly: true, bundle: "com.apple.finder", sheet: true, menuDialog: true)))
    }

    func testAuthenticationSkippedForCommandChords() {
        XCTAssertTrue(keyEventUsesAuthentication(flags: [], authenticated: true))
        XCTAssertTrue(keyEventUsesAuthentication(flags: [.maskShift], authenticated: true))
        XCTAssertFalse(keyEventUsesAuthentication(flags: [.maskCommand], authenticated: true))
        XCTAssertFalse(keyEventUsesAuthentication(flags: [], authenticated: false))
    }

    func testEventRecordProbeOrderAndMiss() {
        let a = UnsafeMutableRawPointer(bitPattern: 0x10)
        let b = UnsafeMutableRawPointer(bitPattern: 0x20)
        var seen: [Int] = []
        XCTAssertEqual(skyLightEventRecordPointer { seen.append($0); return $0 == 32 ? b : ($0 == 16 ? a : nil) }, b)
        XCTAssertEqual(seen, [24, 32])
        XCTAssertNil(skyLightEventRecordPointer { _ in nil })
    }

    func testSPIDoesNotCrashResolvingAuthentication() {
        // Value depends on the OS (selector is macOS 15+); resolving must simply not crash.
        _ = SkyLightSPI.shared.keyAuthenticationAvailable
    }
}
