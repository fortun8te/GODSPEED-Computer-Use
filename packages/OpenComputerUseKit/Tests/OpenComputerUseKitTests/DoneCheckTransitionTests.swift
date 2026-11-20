import XCTest
@testable import OpenComputerUseKit

/// Plain presence checks verify only when they became true during the batch.
final class DoneCheckTransitionTests: XCTestCase {
    private let target = BatchCompletion.Target.native(pid: 1, launch: Date(timeIntervalSince1970: 0), window: 7)

    private func check(_ conditions: [DoneCheck.Condition], before: String, after: String) -> DoneCheck.Result {
        let baseline = BatchCompletion(conditions: conditions, startedAt: Date(),
                                       before: .init(target: target, screen: before, canProveAbsence: true))
        return DoneCheck.check(conditions, evidence: .init(screenText: after, pageURL: { nil }),
                               baseline: baseline, after: .init(target: target, screen: after, canProveAbsence: true))
    }

    func testTextThatAppearedDuringTheBatchVerifies() {
        guard case .verified = check([.text("Message sent")], before: "1 button Send", after: "1 text Message sent") else {
            return XCTFail("new confirmation text is proof")
        }
    }

    func testTextAlreadyThereBeforeTheBatchStaysWeak() {
        guard case .weak = check([.text("Message sent")], before: "1 text Message sent", after: "1 text Message sent") else {
            return XCTFail("an old banner is not proof")
        }
    }

    func testFieldValueThatChangedVerifiesAndAnUnchangedOneStaysWeak() {
        guard case .verified = check([.field(label: "To", equals: "sam@x.com")],
                                     before: "1 text field To = None", after: "1 text field To = sam@x.com") else {
            return XCTFail("changed field is proof")
        }
        guard case .weak = check([.field(label: "To", equals: "sam@x.com")],
                                 before: "1 text field To = sam@x.com", after: "1 text field To = sam@x.com") else {
            return XCTFail("unchanged field is not proof")
        }
    }

    func testWithoutABaselineAPresenceMatchIsWeak() {
        guard case .weak = DoneCheck.check([.text("Message sent")], evidence: .init(screenText: "1 text Message sent", pageURL: { nil })) else {
            return XCTFail("no baseline means no proof of change")
        }
    }

    func testOnePreexistingConditionMakesTheWholeResultWeak() {
        guard case .weak = check([.text("Message sent"), .text("Inbox")],
                                 before: "1 text Inbox", after: "1 text Inbox\n2 text Message sent") else {
            return XCTFail("every met check must have changed")
        }
    }

    func testFileCreatedDuringTheBatchVerifiesAndAnOldFileStaysWeak() throws {
        let fresh = FileManager.default.temporaryDirectory.appendingPathComponent("gs-done-\(UUID().uuidString).txt").path
        let old = FileManager.default.temporaryDirectory.appendingPathComponent("gs-done-\(UUID().uuidString).txt").path
        defer { try? FileManager.default.removeItem(atPath: fresh); try? FileManager.default.removeItem(atPath: old) }
        FileManager.default.createFile(atPath: old, contents: Data("x".utf8))
        let conditions: [DoneCheck.Condition] = [.fileExists(fresh)]
        let baseline = BatchCompletion(conditions: conditions, startedAt: Date())
        FileManager.default.createFile(atPath: fresh, contents: Data("y".utf8))
        guard case .verified = DoneCheck.check(conditions, evidence: .init(screenText: nil, pageURL: { nil }), baseline: baseline) else {
            return XCTFail("a file that appeared is proof")
        }
        let oldConditions: [DoneCheck.Condition] = [.fileExists(old)]
        let oldBaseline = BatchCompletion(conditions: oldConditions, startedAt: Date())
        guard case .weak = DoneCheck.check(oldConditions, evidence: .init(screenText: nil, pageURL: { nil }), baseline: oldBaseline) else {
            return XCTFail("an untouched old file is not proof")
        }
    }
}
