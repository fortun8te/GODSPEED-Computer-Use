import XCTest
@testable import OpenComputerUseKit

final class ClickVerifierTests: XCTestCase {
    private let head = "App=com.example (pid 1)\nWindow: \"Editor\", App: Example.\nWindow ID: 17\n[legend]\n"
    private let base = "1 button \"Save\"\n2 text field \"Title\" = \"Draft\"\n3 button \"Send\"\n"
    private let clipNote = "[Accessibility tree truncated: prioritized visible controls; some nodes were omitted.]"

    private func state(_ body: String, footer: String = "") -> String { head + body + footer }

    /// Runs the classifier the way the batch step does: effect lines and events from the two reads.
    private func verdict(before: String, after: String, afterID: UInt32? = 17, boundID: UInt32? = 17,
                         windowChanged: Bool = false, pixels: Bool? = nil) -> ClickVerifier.Verdict {
        var gone = Set<Int>()
        let lines = BatchEffects.effectLines(before: before, after: after, reportedGone: &gone)
        let events = SemanticChanges.events(before: before, after: after)
        return ClickVerifier.verdict(before: before, after: after, beforeWindowID: boundID, afterWindowID: afterID,
                                     windowChanged: windowChanged, effectLines: lines, events: events, pixelsChanged: pixels)
    }

    func testChangedFieldIsEffectSeen() {
        let before = state(base)
        let after = state("1 button \"Save\"\n2 text field \"Title\" = \"Final\"\n3 button \"Send\"\n")
        XCTAssertEqual(verdict(before: before, after: after), .effectSeen)
    }

    func testIdenticalCompleteReadsOfSameWindowAreNoEffectSeen() {
        let before = state(base)
        XCTAssertEqual(verdict(before: before, after: before), .noEffectSeen)
    }

    func testClippedAfterReadIsUnknownEvenWhenNothingDiffers() {
        let before = state(base)
        let after = state(base, footer: "\n" + clipNote)
        XCTAssertEqual(verdict(before: before, after: after), .unknown)
    }

    func testClippedBeforeReadCannotProveNoEffect() {
        let before = state(base, footer: "\n…(12 more)")
        XCTAssertEqual(verdict(before: before, after: state(base)), .unknown)
    }

    func testTextChangeOnClippedReadIsNotCountedAsEffect() {
        // A clipped read can show an element as new only because the earlier read cut it off.
        let before = state(base, footer: "\n" + clipNote)
        let after = state(base + "4 text \"Sent\"\n")
        XCTAssertEqual(verdict(before: before, after: after), .unknown)
    }

    func testWindowChangeIsEffectSeenEvenOnClippedReads() {
        let before = state(base, footer: "\n…(3 more)")
        XCTAssertEqual(verdict(before: before, after: before, afterID: 18, windowChanged: true), .effectSeen)
    }

    func testDifferentOrMissingWindowIdentityIsUnknown() {
        let before = state(base)
        XCTAssertEqual(verdict(before: before, after: before, afterID: 18), .unknown)
        XCTAssertEqual(verdict(before: before, after: before, afterID: nil), .unknown)
    }

    func testPixelChangeIsEffectSeenAndUnchangedPixelsDoNotBlockNoEffect() {
        let before = state(base)
        XCTAssertEqual(verdict(before: before, after: before, pixels: true), .effectSeen)
        XCTAssertEqual(verdict(before: before, after: before, pixels: false), .noEffectSeen)
    }

    func testPixelComparisonNeedsTwoSameSizeFingerprints() {
        let cells = [UInt64](repeating: 0, count: 16 * 10)
        var moved = cells
        moved[3] = UInt64.max
        let a = RegionFingerprint(columns: 16, rows: 10, hashes: cells, pixelWidth: 800, pixelHeight: 500)
        let b = RegionFingerprint(columns: 16, rows: 10, hashes: moved, pixelWidth: 800, pixelHeight: 500)
        let resized = RegionFingerprint(columns: 16, rows: 10, hashes: cells, pixelWidth: 900, pixelHeight: 500)
        XCTAssertNil(ClickVerifier.pixelsChanged(before: a, after: nil))
        XCTAssertNil(ClickVerifier.pixelsChanged(before: a, after: resized))
        XCTAssertEqual(ClickVerifier.pixelsChanged(before: a, after: b), true)
        XCTAssertEqual(ClickVerifier.pixelsChanged(before: a, after: a), false)
    }

    func testRiskyClicksGetTheSameHonestLineAndNoRetryWording() {
        for label in ["Send", "Delete", "Empty Trash", "Place Order", "Remove"] {
            let target = ClickVerifier.target(arguments: ["label": label])
            let line = ClickVerifier.noEffectLine(tool: "click", target: target)
            XCTAssertEqual(line, "Click on \"\(label)\" changed nothing visible. It may need a different target.")
            XCTAssertFalse(line.lowercased().contains("retry"))
        }
    }

    func testOnlyClickLikeToolsAreVerified() {
        XCTAssertTrue(ClickVerifier.applies(tool: "click"))
        XCTAssertTrue(ClickVerifier.applies(tool: "press_key"))
        XCTAssertTrue(ClickVerifier.applies(tool: "perform_secondary_action"))
        XCTAssertFalse(ClickVerifier.applies(tool: "scroll"))
        XCTAssertFalse(ClickVerifier.applies(tool: "type_text"))
    }

    func testTargetNamesTheElementOrKey() {
        XCTAssertEqual(ClickVerifier.target(arguments: ["element_index": 12]), "#12")
        XCTAssertEqual(ClickVerifier.target(arguments: ["key": "cmd+s"]), "cmd+s")
        XCTAssertEqual(ClickVerifier.target(arguments: [:]), "that item")
    }
}
