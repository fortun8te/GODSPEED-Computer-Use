import Foundation
import XCTest
@testable import OpenComputerUseKit

extension HeadlessScenarioBankTests {
    private struct LearningFamily {
        let id: String
        let window: String
        let button: String
        let distractor: String
        let field: String
        let values: [String]
        let confirmation: String
    }

    private struct LearningRow: Encodable {
        let state: String
        let answer: String
        let meta: [String: String]
    }

    func testLearningReceipts() throws {
        let families: [LearningFamily] = [
            .init(id: "contact", window: "Contacts", button: "Save contact", distractor: "Save as template",
                  field: "Saved contact", values: ["Avery", "Morgan"], confirmation: "Contact added to address book"),
            .init(id: "appearance", window: "Appearance", button: "Apply theme", distractor: "Preview theme",
                  field: "Current theme", values: ["Slate", "Ivory"], confirmation: "Theme applied to this workspace"),
            .init(id: "queue", window: "Print queue", button: "Queue job", distractor: "Queue test page",
                  field: "Queued document", values: ["Agenda", "Bulletin"], confirmation: "Job added to print queue"),
            .init(id: "timer", window: "Focus timer", button: "Start timer", distractor: "Start stopwatch",
                  field: "Active timer", values: ["15 minutes", "25 minutes"], confirmation: "Timer is running"),
            .init(id: "playlist", window: "Music library", button: "Add to playlist", distractor: "Add to favorites",
                  field: "Playlist entry", values: ["Desert Sky", "Blue Lake"], confirmation: "Track added to Road Trip"),
            .init(id: "bookmark", window: "Reading room", button: "Create bookmark", distractor: "Create folder",
                  field: "Saved bookmark", values: ["Bird guide", "Trail map"], confirmation: "Bookmark in Reading List"),
            .init(id: "rename", window: "Workspace", button: "Rename project", distractor: "Rename group",
                  field: "Project name", values: ["Cedar", "Willow"], confirmation: "Project renamed"),
            .init(id: "reservation", window: "Room booking", button: "Reserve room", distractor: "Reserve equipment",
                  field: "Reserved room", values: ["Orchid", "Dahlia"], confirmation: "Room reservation confirmed"),
            .init(id: "export", window: "Report builder", button: "Export report", distractor: "Export settings",
                  field: "Exported report", values: ["Overview.pdf", "Summary.pdf"], confirmation: "Report written"),
            .init(id: "schedule", window: "Schedule", button: "Publish shift", distractor: "Publish notice",
                  field: "Published shift", values: ["Monday morning", "Friday afternoon"], confirmation: "Shift on team calendar"),
            .init(id: "library", window: "Document library", button: "Move to archive", distractor: "Copy to archive",
                  field: "Archived document", values: ["Draft notes", "Meeting log"], confirmation: "Original moved to archive"),
            .init(id: "accessibility", window: "Display settings", button: "Enable text scaling", distractor: "Enable screen zoom",
                  field: "Active text size", values: ["Large", "Extra large"], confirmation: "Text scaling enabled")
        ]

        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        var rows = Data()
        for family in families {
            for (seed, value) in family.values.enumerated() {
                for kind in ["success", "disabled", "ignored", "lookalike", "other_window", "staged", "repeat", "next_step"] {
                    for row in try learningRows(family, value: value, seed: seed, kind: kind) {
                        rows.append(try encoder.encode(row))
                        rows.append(0x0a)
                    }
                }
            }
        }
        if let directory = ProcessInfo.processInfo.environment["GODSPEED_LEARNING_OUTPUT"], !directory.isEmpty {
            let output = URL(fileURLWithPath: directory).resolvingSymlinksInPath()
            for folder in [".godspeed", ".ocu-referee"] {
                let live = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(folder).resolvingSymlinksInPath()
                guard output.path != live.path, !output.path.hasPrefix(live.path + "/") else {
                    throw CocoaError(.fileWriteNoPermission)
                }
            }
            try rows.write(to: output.appendingPathComponent("learning.jsonl"), options: .withoutOverwriting)
        }
    }

    private func learningRows(_ family: LearningFamily, value: String, seed: Int, kind: String) throws -> [LearningRow] {
        // The simulated app owns the stored value and the window ID. A tool acknowledgement does not change either.
        let intendedEffect = ["success", "next_step"].contains(kind)
        let committed = kind == "success"
        let otherWindow = kind == "other_window"
        let wrongElement = kind == "lookalike"
        let dialog = kind == "next_step"
        let staged = kind == "staged"
        let disabled = kind == "disabled"
        let clicks = kind == "repeat" ? 3 : 1
        let archiveProof = family.id == "library"
        let outputProof = family.id == "export"
        let source = "\n6 row Original in Inbox"
        let before = """
        Window: "\(family.window)", App: Fixture.
        1 button \(family.button)\(disabled ? " (disabled)" : "")
        2 button \(family.distractor)
        3 text field \(family.field) = None
        """ + (archiveProof ? source : "")
        let after = before.replacingOccurrences(of: " = None", with: " = \(committed ? value : "None")")
            + (committed ? "\n4 text \(family.confirmation)" : "")
            + (dialog ? "\n4 dialog Confirm \(family.button)\n5 button Confirm" : "")
            + (staged ? "\n4 text field Draft = \(value)\n5 text Changes pending" : "")
            + (wrongElement ? "\n4 text \(family.distractor) completed" : "")
        let screen = otherWindow ? after.replacingOccurrences(of: family.window, with: "\(family.window) preview")
            .replacingOccurrences(of: " = None", with: " = \(value)") + "\n4 text \(family.confirmation)" :
            committed && archiveProof ? after.replacingOccurrences(of: source, with: "") : after
        var gone = Set<Int>()
        let effects = BatchEffects.effectLines(before: before, after: screen, reportedGone: &gone)
        let window = BatchEffects.compare(bound: BatchEffects.windowSig(state: before, id: 1),
                                          now: BatchEffects.windowSig(state: screen, id: otherWindow ? 2 : 1))
        let changedWindow: Bool
        if case .moved = window { changedWindow = true } else { changedWindow = false }
        var receipt = TrajectoryLog.BatchReceipt(totalSteps: clicks)
        let step = TrajectoryLog.BatchReceipt.Step(
            failureCode: disabled ? .toolError : nil,
            observation: disabled ? BatchEffects.failureReceipt(.notSent) :
                BatchEffects.sawNoChange(effects) ? .noEffectSeen : nil
        )
        receipt.steps = Array(repeating: step, count: clicks)
        receipt.stop = changedWindow ? .windowChanged : disabled ? .stepFailure : nil
        // A real temporary file, written after the baseline only when the fixture commits, so file_exists
        // can prove the file appeared during the batch.
        let output = FileManager.default.temporaryDirectory
            .appendingPathComponent("godspeed-learning-\(UUID().uuidString)-\(value)").path
        defer { try? FileManager.default.removeItem(atPath: output) }
        var checks: [DoneCheck.Condition] = [.field(label: family.field, equals: value), .text(family.confirmation)]
        if archiveProof { checks.append(.gone("Original in Inbox")) }
        if outputProof { checks.append(.fileExists(output)) }
        // Change-aware completion (L2): the proof must appear since the batch started, so the
        // fixture passes its starting screen as the baseline.
        let target = BatchCompletion.Target.native(pid: 1, launch: Date(timeIntervalSince1970: 0), window: 1)
        let baseline = BatchCompletion(conditions: checks, startedAt: Date(),
                                       before: .init(target: target, screen: before, canProveAbsence: true))
        if committed, outputProof { FileManager.default.createFile(atPath: output, contents: Data(value.utf8)) }
        if !changedWindow, case .verified = DoneCheck.check(checks, evidence: .init(
            screenText: screen, pageURL: { nil }
        ), baseline: baseline, after: .init(target: target, screen: screen, canProveAbsence: true)) {
            receipt.doneCheck = .verified
        } else {
            receipt.doneCheck = .unmet
        }

        let evidence: String
        if receipt.doneCheck == .verified { evidence = "done_verified" }
        else if receipt.stop == .windowChanged || wrongElement { evidence = "wrong_target_changed" }
        else if receipt.steps.count >= 3 && step.observation == .noEffectSeen { evidence = "stuck" }
        else if step.observation == .noEffectSeen || step.observation == .notSent { evidence = "click_no_effect" }
        else { evidence = "partial_completion" }
        let expected = [
            "success": "done_verified", "disabled": "click_no_effect", "ignored": "click_no_effect",
            "lookalike": "wrong_target_changed", "other_window": "wrong_target_changed",
            "staged": "partial_completion", "repeat": "stuck", "next_step": "partial_completion"
        ]
        XCTAssertEqual(evidence, expected[kind])
        XCTAssertEqual(receipt.doneCheck == .verified, committed)

        let action = "Click \"\(family.button)\"" + (clicks > 1 ? " (\(clicks) attempts)" : "")
        let result = disabled ? "Click refused. The control is disabled." : "Click returned ok."
        let task = "In the \(family.window) window, use \(family.button) to finish setting \(family.field) to \(value)."
        let click = "Confirm the click on \(family.button) took effect for \(value). Look for \(family.confirmation) or its confirmation dialog in \(family.window)."

        return try [
            ("decision", task, committed ? "done" : clicks > 1 ? "stuck" : dialog || disabled ? "act" : "look_again"),
            ("click", click, intendedEffect ? "done" : clicks > 1 ? "stuck" : disabled ? "act" : "look_again")
        ].map { check, goal, answer in
            let summary = RefereeSummary.build(
                goal: goal, steps: Array(repeating: (action, result), count: clicks),
                repeatedFailures: clicks - 1, screenChanged: !BatchEffects.sawNoChange(effects),
                dialogOpen: RefereeSummary.dialogOpen(in: screen), changes: effects.joined(separator: "\n"),
                screen: RefereeSummary.screen(from: screen)
            )
            let state = try Self.learningState(goal: goal, lastStep: action, result: result, view: summary)
            return LearningRow(state: state, answer: answer, meta: [
                "id": "\(family.id)/\(seed)/\(kind)/\(check)", "family": family.id, "source": "synthetic_headless",
                "check": check, "outcome": evidence, "variant": kind
            ])
        }
    }

    private static func learningState(goal: String, lastStep: String, result: String, view: String) throws -> String {
        let fields = ["goal": goal, "last_step": lastStep, "result": result, "view": view]
        // A focused secure field can echo an unlabeled value elsewhere in its observation.
        let secureFocus = TrajectoryLog.focusesSecureField(view)
        let state = fields.mapValues(TrajectoryLog.redactSecureLines).merging(
            secureFocus ? ["last_step": TrajectoryLog.redactedValue, "result": TrajectoryLog.redactedValue,
                           "view": TrajectoryLog.redactedValue] : [:]
        ) { _, redacted in
            redacted
        }
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        return String(decoding: try encoder.encode(state), as: UTF8.self)
    }

    func testLearningScrubsSecureValues() throws {
        let state = try Self.learningState(
            goal: "Fixture goal\nPasscode Value: 1234", lastStep: "Type Echoed value", result: "Typed result-secret",
            view: "1 secure field focus\n2 text field Other = unlabeled-secret"
        )
        for secret in ["1234", "Echoed value", "result-secret", "unlabeled-secret"] {
            XCTAssertFalse(state.contains(secret))
        }
        XCTAssertTrue(state.contains("Fixture goal"))
        XCTAssertTrue(state.contains("[redacted]"))
    }
}
