import CoreGraphics
import XCTest
@testable import OpenComputerUseKit

/// Pure-logic tests for the rename rule of type_text (a full new name typed over Finder's selection of the name
/// without its extension) and for choosing a save panel's name field. Nothing here touches an app.
final class TypedNameReplacementTests: XCTestCase {
    private let renameSelection = CFRange(location: 0, length: 5)

    func testFullNameWithSameExtensionReplacesWholeName() {
        XCTAssertTrue(typedNameReplacesWholeValue(value: "notes.txt", selection: renameSelection, text: "report.txt"))
        XCTAssertTrue(typedNameReplacesWholeValue(value: "notes.txt", selection: renameSelection, text: "Report.TXT"))
        XCTAssertTrue(typedNameReplacesWholeValue(value: "a.b.txt", selection: CFRange(location: 0, length: 3), text: "x.y.txt"))
    }

    func testNameWithoutExtensionIsLeftToTheSelection() {
        XCTAssertFalse(typedNameReplacesWholeValue(value: "notes.txt", selection: renameSelection, text: "report"))
    }

    func testOtherTextOverPartialSelectionIsNotARename() {
        // The selection does not start at the beginning, or it covers the whole value, or there is no extension.
        XCTAssertFalse(typedNameReplacesWholeValue(value: "notes.txt", selection: CFRange(location: 2, length: 3), text: "x.txt"))
        XCTAssertFalse(typedNameReplacesWholeValue(value: "notes.txt", selection: CFRange(location: 0, length: 9), text: "x.txt"))
        XCTAssertFalse(typedNameReplacesWholeValue(value: "notes", selection: CFRange(location: 0, length: 5), text: "x.txt"))
        XCTAssertFalse(typedNameReplacesWholeValue(value: "notes.txt", selection: CFRange(location: 0, length: 0), text: "x.txt"))
    }

    func testOnlyAnExtensionAsTheTypedTextIsNotAName() {
        XCTAssertFalse(typedNameReplacesWholeValue(value: "notes.txt", selection: renameSelection, text: ".txt"))
    }

    func testDifferentExtensionIsNotTreatedAsSameRename() {
        XCTAssertFalse(typedNameReplacesWholeValue(value: "notes.txt", selection: renameSelection, text: "notes.rtf"))
    }

    func testFinderRenameFromTheTranscriptReplacesWholeName() {
        // Finder selects "old-name-06" of "old-name-06.txt"; the model typed the full new name.
        XCTAssertTrue(typedNameReplacesWholeValue(value: "old-name-06.txt", selection: CFRange(location: 0, length: 11), text: "final-name-06.txt"))
    }

    func testWholeNameRuleAppliesOnlyInFinderRenameEditor() {
        // The same text field state in another app is ordinary editing: a word at the start of a document.
        XCTAssertTrue(isFinderRenameEditor(bundleIdentifier: "com.apple.finder", role: "AXTextField", insideSheetOrDialog: false))
        XCTAssertFalse(isFinderRenameEditor(bundleIdentifier: "com.apple.TextEdit", role: "AXTextField", insideSheetOrDialog: false))
        XCTAssertFalse(isFinderRenameEditor(bundleIdentifier: "com.apple.finder", role: "AXTextArea", insideSheetOrDialog: false))
        XCTAssertFalse(isFinderRenameEditor(bundleIdentifier: nil, role: "AXTextField", insideSheetOrDialog: false))
    }

    func testFinderFieldInsideASheetIsNotARenameEditor() {
        // Finder's Go To and other sheets have text fields too; they never take the whole-name rule.
        XCTAssertFalse(isFinderRenameEditor(bundleIdentifier: "com.apple.finder", role: "AXTextField", insideSheetOrDialog: true))
    }

    func testPreferredNameFieldSkipsSearchAndTagsFields() {
        let fields = [
            SmartSteps.SaveFieldCandidate(label: "search", isSearch: true, settable: true),
            SmartSteps.SaveFieldCandidate(label: "save as", isSearch: false, settable: true),
            SmartSteps.SaveFieldCandidate(label: "tags", isSearch: false, settable: true),
        ]
        XCTAssertEqual(SmartSteps.preferredNameFieldIndex(fields), 1)
    }

    func testPreferredNameFieldPrefersNamedFieldOverEarlierUnnamedField() {
        let fields = [
            SmartSteps.SaveFieldCandidate(label: "", isSearch: false, settable: true),
            SmartSteps.SaveFieldCandidate(label: "name", isSearch: false, settable: true),
        ]
        XCTAssertEqual(SmartSteps.preferredNameFieldIndex(fields), 1)
    }

    func testPreferredNameFieldIgnoresReadOnlyFields() {
        let fields = [
            SmartSteps.SaveFieldCandidate(label: "name", isSearch: false, settable: false),
            SmartSteps.SaveFieldCandidate(label: "", isSearch: false, settable: true),
        ]
        XCTAssertEqual(SmartSteps.preferredNameFieldIndex(fields), 1)
        XCTAssertNil(SmartSteps.preferredNameFieldIndex([SmartSteps.SaveFieldCandidate(label: "", isSearch: true, settable: true)]))
    }

    func testSavePanelFromTranscriptPicksTheSaveAsField() {
        // The TextEdit save sheet of transcript 01: Search (AXSearchField), "Save As" field (identifier saveAsNameTextField),
        // Tags editor (description "tag editor"). Column-view file names are inside a browser and never candidates.
        let fields = [
            SmartSteps.SaveFieldCandidate(label: "search", isSearch: true, settable: true),
            SmartSteps.SaveFieldCandidate(label: "saveasnametextfield", isSearch: false, settable: true),
            SmartSteps.SaveFieldCandidate(label: "tag editor", isSearch: false, settable: true),
        ]
        XCTAssertEqual(SmartSteps.preferredNameFieldIndex(fields), 1)
    }

    func testWhereFolderRequiresTheFullDestinationPath() {
        XCTAssertTrue(SmartSteps.whereMatches(popupValue: "/Users/michael/work", folder: "/Users/michael/work"))
        XCTAssertTrue(SmartSteps.whereMatches(popupValue: "/Users/michael/work/", folder: "/Users/michael/work"))
        XCTAssertTrue(SmartSteps.whereMatches(popupValue: "/", folder: "/"))
        XCTAssertFalse(SmartSteps.whereMatches(popupValue: "work", folder: "/Users/michael/work"))
        XCTAssertFalse(SmartSteps.whereMatches(popupValue: "/Users/another/work", folder: "/Users/michael/work"))
        XCTAssertFalse(SmartSteps.whereMatches(popupValue: nil, folder: "/Users/michael/work"))
        XCTAssertFalse(SmartSteps.whereMatches(popupValue: "Macintosh HD", folder: "/"))
    }

    func testWhereFolderDoesNotGuessThroughSymlinksOrRelativePaths() {
        XCTAssertFalse(SmartSteps.whereMatches(popupValue: "/Users/michael/link/../work", folder: "/Users/michael/work"))
        XCTAssertFalse(SmartSteps.whereMatches(popupValue: "~/work", folder: "/Users/michael/work"))
        XCTAssertFalse(SmartSteps.whereMatches(popupValue: "work", folder: "work"))
        XCTAssertFalse(SmartSteps.whereMatches(popupValue: "/Users/michael/work", folder: "/Users/michael/work "))
        XCTAssertFalse(SmartSteps.whereMatches(popupValue: " /Users/michael/work/\n", folder: "/Users/michael/work"))
    }
}
