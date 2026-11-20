import XCTest
@testable import OpenComputerUseKit

final class RiskLexiconTests: XCTestCase {
    private let destructiveSamples = [
        "Delete", "Move to Trash", "Verwijder bestand…", "Naar prullenbak verplaatsen", "Prullenmand leegmaken",
        "Wis alles", "Afmelden…", "Uitloggen", "Löschen", "Papierkorb leeren", "Supprimer", "Vider la corbeille",
        "Eliminar", "Vaciar la papelera", "Send", "Verstuur", "Plaats bericht", "Senden", "Jetzt absenden",
        "Envoyer", "Enviar", "Buy now", "Koop nu", "Betaal nu", "Bestellen", "Afrekenen", "Kaufen", "Bezahlen",
        "Acheter", "Payer", "Comprar", "Pagar", "Place order", "Quit TextEdit", "Don’t Save", "Sign Out",
        "Discard Changes", "Upload", "Sign in", "Überschreiben", "Vervang", "Replace",
    ]

    func testEveryConsumerAgreesOnDestructiveLabels() {
        for label in destructiveSamples {
            XCTAssertTrue(RiskLexicon.isDestructive(label), label)
            XCTAssertTrue(MenuItemLookup.isDestructive(label), label)
            XCTAssertTrue(ShortcutCache.isDestructive(label), label)
            XCTAssertTrue(FailureSignatureStore.containsRiskyWord(toolName: "click", label: label), label)
        }
    }

    func testHarmlessLabelsAreNotDestructiveAnywhere() {
        for label in ["Save", "Opslaan", "Wishlist", "Stopwatch", "Bold", "Sender Info", "Closed Captions", "Cuts list",
                      "Border", "Information", "Wissel", "Display settings", "Zoom In", "Make Plain Text", "Select All"] {
            XCTAssertFalse(RiskLexicon.isDestructive(label), label)
            XCTAssertFalse(MenuItemLookup.isDestructive(label), label)
            XCTAssertFalse(ShortcutCache.isDestructive(label), label)
            XCTAssertFalse(FailureSignatureStore.containsRiskyWord(toolName: "click", label: label), label)
        }
    }

    func testPrefixStemsMatchInflectionsButNotUnrelatedWords() {
        XCTAssertTrue(RiskLexicon.categories(["Verwijderen"]).contains(.delete))
        XCTAssertTrue(RiskLexicon.categories(["Bestellung aufgeben"]).contains(.purchase))
        XCTAssertTrue(RiskLexicon.categories(["Absenden"]).contains(.send))
        XCTAssertFalse(RiskLexicon.categories(["Formation"]).contains(.discard))
        XCTAssertFalse(RiskLexicon.categories(["Removable Disk"]).contains(.delete))
    }

    func testEachLabelIsReadOnItsOwnSoWordsDoNotJoinAcrossNames() {
        XCTAssertTrue(RiskLexicon.categories(["Log", "Out"]).isDisjoint(with: [.discard]))
        XCTAssertTrue(RiskLexicon.categories(["Log out"]).contains(.discard))
        XCTAssertTrue(RiskLexicon.categories([nil, "Delete"]).contains(.delete))
    }
}
