import Foundation

/// One in-memory clipboard per existing Godspeed client identity, shared by its native and web tools.
final class PrivateClipboard: @unchecked Sendable {
    enum Payload: Equatable {
        case text(String)
        case files(paths: [String], move: Bool)
    }

    enum Action: String {
        case copy, cut, paste, moveFiles

        init?(key: String, browser: Bool = false) {
            let key = ComputerUseService.canonicalKey(key)
            switch key {
            case "cmd+c": self = .copy
            case "cmd+x": self = .cut
            case "cmd+v", "alt+cmd+shift+v", "cmd+shift+v": self = .paste
            case "alt+cmd+v": self = .moveFiles
            case "ctrl+c" where browser: self = .copy
            case "ctrl+x" where browser: self = .cut
            case "ctrl+v" where browser, "ctrl+shift+v" where browser: self = .paste
            default: return nil
            }
        }
    }

    static let maxTextBytes = 1_048_576
    private static let clients = ScopedStore<PrivateClipboard> { _ in PrivateClipboard() }
    static var current: PrivateClipboard { clients.current }

    private let lock = NSLock()
    private var stored: Payload?

    var payload: Payload? { lock.withLock { stored } }

    func writeText(_ text: String) throws {
        guard text.utf8.count <= Self.maxTextBytes else {
            throw ComputerUseError.invalidArguments("Private clipboard text must be at most 1 MiB.")
        }
        write(.text(text))
    }

    func write(_ payload: Payload) { lock.withLock { stored = payload } }
    func clear() { lock.withLock { stored = nil } }

    func clear(matching payload: Payload) {
        lock.withLock {
            if stored == payload { stored = nil }
        }
    }

    func textForPaste() throws -> String {
        switch payload {
        case .text(let text): return text
        case .files: throw ComputerUseError.invalidArguments("The private clipboard holds files. Paste into Finder or a Chrome file input.")
        case nil: throw ComputerUseError.invalidArguments("The private clipboard is empty. Copy something first.")
        }
    }
}
