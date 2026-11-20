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

    func testDestructiveEnglishAndDutchTitlesNeverResolve() {
        let titles = [
            "Delete", "Delete…", "Remove Item…", "Erase All Content...", "Quit Editor", "quit editor", "Close Window",
            "Stop", "Empty Trash", "Move to Trash", "Move-to-Trash…", "Log Out…", "Log out...", "Logout", "LOGOUT",
            "Sign Out", "Restart…", "Shut Down…", "Shutdown", "Force Quit Editor", "Discard Changes", "Revert to Saved",
            "Format Disk…",
            "Verwijderen", "Verwijder bestand…", "Wis alles", "Sluit venster", "Afmelden…", "Uitloggen", "Herstart",
            "Opnieuw opstarten…", "Zet uit…", "Prullenmand leegmaken", "Naar prullenmand verplaatsen", "Weggooien",
            "Löschen", "Entfernen", "Beenden", "Schließen", "Abmelden…", "Neustarten", "Papierkorb leeren", "Verwerfen",
            "Supprimer", "Quitter", "Fermer", "Déconnexion", "Vider la corbeille", "Redémarrer…", "Éteindre…",
            "Eliminar", "Borrar", "Cerrar sesión…", "Vaciar la papelera",
        ]
        let items = titles.enumerated().map { i, title in
            ShortcutCache.MenuItem(path: "Menu > \(title)", title: title, commandCharacter: "d", modifierMask: 0)
        }
        for title in titles {
            XCTAssertTrue(ShortcutCache.isDestructive(title), "\(title) should be destructive")
        }
        let cache = ShortcutCache()
        cache.parse(app: "A", items: items)
        for item in items {
            XCTAssertNil(cache.lookup(app: "A", path: item.path, includeUnverified: true), "\(item.title) resolved")
            cache.confirm(app: "A", path: item.path)
            XCTAssertNil(cache.lookup(app: "A", path: item.path), "\(item.title) resolved after confirm")
        }
    }

    func testHarmlessTitlesStillResolve() {
        XCTAssertFalse(ShortcutCache.isDestructive("Save"))
        XCTAssertFalse(ShortcutCache.isDestructive("Wishlist"))
        XCTAssertFalse(ShortcutCache.isDestructive("Stopwatch"))
        XCTAssertFalse(ShortcutCache.isDestructive("Bold"))
        let cache = ShortcutCache()
        cache.parse(app: "A", items: [.init(path: "Edit > Bold", title: "Bold", commandCharacter: "b", modifierMask: 0)])
        XCTAssertEqual(cache.lookup(app: "A", path: "Edit > Bold", includeUnverified: true), "cmd+b")
    }

    func testExtraPredicateBlocksOnTopOfBuiltIns() {
        let cache = ShortcutCache(isExtraDestructive: { $0.hasPrefix("Publish") })
        cache.parse(app: "A", items: [
            .init(path: "File > Publish Now", title: "Publish Now", commandCharacter: "p", modifierMask: 0),
            .init(path: "File > Logout", title: "Logout", commandCharacter: "l", modifierMask: 0),
            .init(path: "File > Save", title: "Save", commandCharacter: "s", modifierMask: 0),
        ])
        XCTAssertNil(cache.lookup(app: "A", path: "File > Publish Now", includeUnverified: true))
        XCTAssertNil(cache.lookup(app: "A", path: "File > Logout", includeUnverified: true))
        XCTAssertEqual(cache.lookup(app: "A", path: "File > Save", includeUnverified: true), "cmd+s")
    }
}
