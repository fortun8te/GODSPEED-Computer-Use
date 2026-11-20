import Foundation
import XCTest
@testable import OpenComputerUseKit

/// press_menu's shortcut route: confirmed key equivalents only, never in strict mode, never for destructive items,
/// and keyed by app version. Files live in temp directories, never under ~/.godspeed.
final class ShortcutRouteWiringTests: XCTestCase {
    private func tempFile(_ name: String) throws -> URL {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: dir) }
        return dir.appendingPathComponent(name)
    }

    func testRouteUsesMenuUntilOneSuccessIsConfirmed() {
        let cache = ShortcutCache()
        let app = ShortcutCache.appKey(bundleID: "com.example.editor", version: "2.1")
        cache.parse(app: app, items: [.init(path: "Edit > Bold", title: "Bold", commandCharacter: "b", modifierMask: 0)])
        XCTAssertEqual(cache.route(app: app, path: "Edit > Bold", strict: false), .menu)
        cache.confirm(app: app, path: "Edit > Bold")
        XCTAssertEqual(cache.route(app: app, path: "Edit > Bold", strict: false), .shortcut("cmd+b"))
    }

    func testStrictModeAlwaysUsesTheMenu() {
        let cache = ShortcutCache()
        let app = "com.example.editor@2.1"
        cache.parse(app: app, items: [.init(path: "Edit > Bold", title: "Bold", commandCharacter: "b", modifierMask: 0)])
        cache.confirm(app: app, path: "Edit > Bold")
        XCTAssertEqual(cache.route(app: app, path: "Edit > Bold", strict: true), .menu)
    }

    func testDestructiveItemsNeverRouteToShortcuts() {
        let cache = ShortcutCache()
        let app = "com.example.mail@9"
        cache.parse(app: app, items: [
            .init(path: "Message > Delete", title: "Delete", commandCharacter: "d", modifierMask: 0),
            .init(path: "File > Quit", title: "Quit", commandCharacter: "q", modifierMask: 0),
        ])
        cache.confirm(app: app, path: "Message > Delete")
        cache.confirm(app: app, path: "File > Quit")
        XCTAssertEqual(cache.route(app: app, path: "Message > Delete", strict: false), .menu)
        XCTAssertEqual(cache.route(app: app, path: "File > Quit", strict: false), .menu)
    }

    func testAnotherAppVersionMissesTheCache() {
        let cache = ShortcutCache()
        let old = ShortcutCache.appKey(bundleID: "com.example.editor", version: "2.1")
        let new = ShortcutCache.appKey(bundleID: "com.example.editor", version: "2.2")
        cache.parse(app: old, items: [.init(path: "Edit > Bold", title: "Bold", commandCharacter: "b", modifierMask: 0)])
        cache.confirm(app: old, path: "Edit > Bold")
        XCTAssertEqual(cache.route(app: old, path: "Edit > Bold", strict: false), .shortcut("cmd+b"))
        XCTAssertEqual(cache.route(app: new, path: "Edit > Bold", strict: false), .menu)
    }

    func testConfirmedShortcutsSurviveAFileRoundTripAndUnconfirmedOnesDoNot() throws {
        let file = try tempFile("shortcuts.json")
        let app = "com.example.editor@2.1"
        let cache = ShortcutCache()
        cache.parse(app: app, items: [
            .init(path: "Edit > Bold", title: "Bold", commandCharacter: "b", modifierMask: 0),
            .init(path: "Edit > Italic", title: "Italic", commandCharacter: "i", modifierMask: 0),
        ])
        cache.confirm(app: app, path: "Edit > Bold")
        try cache.save(to: file)

        let loaded = ShortcutCache()
        try loaded.load(from: file)
        XCTAssertEqual(loaded.route(app: app, path: "Edit > Bold", strict: false), .shortcut("cmd+b"))
        XCTAssertEqual(loaded.route(app: app, path: "Edit > Italic", strict: false), .menu)
    }

    func testMissingFileLoadsAsEmptyCache() throws {
        let file = try tempFile("absent.json")
        let cache = ShortcutCache()
        try cache.load(from: file)
        XCTAssertEqual(cache.route(app: "a@1", path: "Edit > Bold", strict: false), .menu)
    }
}
