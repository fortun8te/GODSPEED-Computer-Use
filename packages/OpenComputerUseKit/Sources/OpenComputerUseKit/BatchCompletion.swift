import AppKit
import CryptoKit
import Darwin
import Foundation

/// A private before/after observation. It never publishes new element indexes.
struct BatchCompletion {
    enum Target: Equatable {
        case native(pid: pid_t, launch: Date, window: UInt32)
        case browser(tab: Int, generation: Int)
    }

    struct Observation {
        let target: Target
        var screen: String?
        var url: String?
        var canProveAbsence: Bool
    }

    struct Artifact: Equatable {
        let modified: Date
        let size: UInt64
        let digest: SHA256.Digest?

        private struct Metadata: Equatable {
            let modified: Date
            let size: UInt64
            let inode: UInt64
        }

        private static func attributes(_ path: String) throws -> Metadata? {
            let values = try FileManager.default.attributesOfItem(atPath: path)
            guard values[.type] as? FileAttributeType == .typeRegular,
                  let date = values[.modificationDate] as? Date, let size = values[.size] as? NSNumber,
                  let inode = values[.systemFileNumber] as? NSNumber else { return nil }
            return Metadata(modified: date, size: size.uint64Value, inode: inode.uint64Value)
        }

        enum Sample {
            case absent
            case unavailable
            case file(Artifact)
        }

        static func sample(_ path: String) -> Sample {
            let metadata: Metadata
            do {
                guard let found = try attributes(path) else { return .unavailable }
                metadata = found
            } catch let error as CocoaError where error.code == .fileReadNoSuchFile || error.code == .fileNoSuchFile {
                return .absent
            } catch {
                return .unavailable
            }

            do {
                // Keep large exports cheap. Size and mtime suffice when either changes.
                let digest: SHA256.Digest?
                if metadata.size <= 16 * 1024 * 1024 {
                    // The path could change between stat and open. Never follow a replacement link or wait on a pipe.
                    let fd = open(path, O_RDONLY | O_NOFOLLOW | O_NONBLOCK)
                    guard fd >= 0 else { return .unavailable }
                    let handle = FileHandle(fileDescriptor: fd, closeOnDealloc: true)
                    var opened = stat()
                    guard fstat(fd, &opened) == 0, opened.st_ino == metadata.inode,
                          opened.st_mode & S_IFMT == S_IFREG else { return .unavailable }
                    var hash = SHA256()
                    var remaining = metadata.size
                    while remaining > 0 {
                        guard let data = try handle.read(upToCount: Int(min(remaining, 64 * 1024))), !data.isEmpty else {
                            return .unavailable
                        }
                        hash.update(data: data)
                        remaining -= UInt64(data.count)
                    }
                    digest = hash.finalize()
                } else {
                    digest = nil
                }
                guard try attributes(path) == metadata else { return .unavailable }
                return .file(Artifact(modified: metadata.modified, size: metadata.size, digest: digest))
            } catch {
                return .unavailable
            }
        }
    }

    let startedAt: Date
    let before: Observation?
    private let files: [String: Artifact.Sample]

    init(conditions: [DoneCheck.Condition], startedAt: Date, before: Observation? = nil) {
        self.startedAt = startedAt
        self.before = before
        var files: [String: Artifact.Sample] = [:]
        for case .fileChanged(let path) in conditions where files[path] == nil {
            files[path] = Artifact.sample(path)
        }
        self.files = files
    }

    func meets(_ condition: DoneCheck.Condition, after: Observation?) -> Bool {
        if case .fileChanged(let path) = condition {
            guard let prior = files[path], case .file(let current) = Artifact.sample(path) else { return false }
            switch prior {
            case .absent: return true
            case .unavailable: return false
            case .file(let previous):
                return current.size != previous.size
                    || (current.modified > previous.modified && current.modified >= startedAt)
                    || (previous.digest != nil && current.digest != nil && previous.digest != current.digest)
            }
        }
        guard let before, let after, before.target == after.target else { return false }
        switch condition {
        case .appeared(let text):
            guard before.canProveAbsence, let previous = before.screen, let current = after.screen else { return false }
            return !DoneCheck.textMatches(previous, text) && DoneCheck.textMatches(current, text)
        case .fieldChanged(let label, let value):
            guard before.canProveAbsence, after.canProveAbsence,
                  let prior = before.screen.flatMap({ DoneCheck.exactFieldValue($0, label: label) }),
                  let current = after.screen.flatMap({ DoneCheck.exactFieldValue($0, label: label) }) else { return false }
            return current == value && prior != current
        case .urlChanged(let url):
            guard let previous = before.url, let current = after.url else { return false }
            return previous != current && current == url
        case .disappeared(let text):
            guard after.canProveAbsence, let previous = before.screen, let current = after.screen else { return false }
            return DoneCheck.textMatches(previous, text) && !DoneCheck.textMatches(current, text)
        default:
            return false
        }
    }

    static func native(app: String, windowID: UInt32?) -> Observation? {
        guard let running = try? AppDiscovery.resolveRunning(app),
              let launch = running.runningApplication.launchDate else { return nil }
        return SnapshotBuilder.$publishesElementNumbers.withValue(false) {
            guard let snapshot = try? SnapshotBuilder.build(
                for: running, recoveryPolicy: .readOnly, observation: .init(includeScreenshot: false), windowID: windowID
            ), let id = snapshot.observedWindowID else { return nil }
            let screen = snapshot.treeLines.filter { LeanOutput.leadingIndex($0) != nil }
            guard !screen.isEmpty else { return nil }
            let complete = DoneCheck.supportsAbsenceCheck(snapshot.treeLines.joined(separator: "\n"))
                && !screen.contains { $0.count >= defaultTextLimit && $0.contains("...") }
            return Observation(
                target: .native(pid: running.pid, launch: launch, window: id),
                screen: screen.joined(separator: "\n"), canProveAbsence: complete
            )
        }
    }

    static func browser(tabID: Int?, needsText: Bool, deadline: TimeInterval) -> Observation? {
        guard BrowserBridge.isAvailable else { return nil }
        let bridge = BrowserBridge.shared
        return BrowserCallBudget.withDeadline(deadline) {
            guard deadline - ProcessInfo.processInfo.systemUptime > 0.6,
                  let tab = tabID ?? (try? bridge.resolveImplicitTab())?.id else { return nil }
            let page = BrowserPage(bridge: bridge, tab: ["tab_id": tab])
            return page.completionObservation(tabID: tab, needsText: needsText)
        }
    }
}
