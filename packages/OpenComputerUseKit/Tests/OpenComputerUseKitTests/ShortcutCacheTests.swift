import XCTest
@testable import OpenComputerUseKit

final class ShortcutCacheTests: XCTestCase {
    func testModifierDecodingAndConfirmation() {
        let cache = ShortcutCache()
        cache.parse(app: "Editor", items: [.init(path: "File > Save As…", title: "Save As…", commandCharacter: "S", modifierMask: 1)])
        XCTAssertNil(cache.lookup(app: "Editor", path: "File > Save As…"))
        XCTAssertEqual(cache.lookup(app: "Editor", path: "File > Save As…", includeUnverified: true), "cmd+shift+s")
        cache.confirm(app: "Editor", path: "File > Save As…")
        XCTAssertEqual(cache.lookup(app: "Editor", path: "File > Save As…"), "cmd+shift+s")
    }

    func testAllMasksAndNoCommand() {
        let cache = ShortcutCache()
        cache.parse(app: "A", items: [0, 1, 2, 3, 4, 8].enumerated().map { i, mask in .init(path: "Menu > Item\(i)", title: "Item\(i)", commandCharacter: "x", modifierMask: mask) })
        XCTAssertEqual(cache.lookup(app: "A", path: "Menu > Item0", includeUnverified: true), "cmd+x")
        XCTAssertEqual(cache.lookup(app: "A", path: "Menu > Item1", includeUnverified: true), "cmd+shift+x")
        XCTAssertEqual(cache.lookup(app: "A", path: "Menu > Item2", includeUnverified: true), "cmd+option+x")
        XCTAssertEqual(cache.lookup(app: "A", path: "Menu > Item3", includeUnverified: true), "cmd+shift+option+x")
        XCTAssertEqual(cache.lookup(app: "A", path: "Menu > Item4", includeUnverified: true), "cmd+ctrl+x")
        XCTAssertNil(cache.lookup(app: "A", path: "Menu > Item5", includeUnverified: true))
    }

    func testDestructiveFilteringAndInvalidate() {
        let cache = ShortcutCache()
        cache.parse(app: "A", items: [.init(path: "File > Quit", title: "Quit", commandCharacter: "q", modifierMask: 0), .init(path: "File > Save", title: "Save", commandCharacter: "s", modifierMask: 0)])
        XCTAssertNil(cache.lookup(app: "A", path: "File > Quit", includeUnverified: true))
        cache.confirm(app: "A", path: "File > Save")
        cache.invalidate(app: "A")
        XCTAssertNil(cache.lookup(app: "A", path: "File > Save", includeUnverified: true))
    }
}
