import Carbon.HIToolbox
import CoreGraphics
import Foundation

/// Which key types a character on the keyboard layout in use. Key presses are sent as key codes (positions),
/// so "*" as shift+8 is only right on a US layout; on others the same position types something else.
enum KeyboardLayoutLookup {
    typealias Key = (keyCode: CGKeyCode, shift: Bool)

    private static let lock = NSLock()
    nonisolated(unsafe) private static var cached: (at: Date, map: [Character: Key])?

    /// The key (and whether shift is needed) that types `character` now, or nil when the layout cannot be read.
    static func key(for character: Character) -> Key? {
        table()?[character]
    }

    private static func table() -> [Character: Key]? {
        lock.lock()
        if let cached, Date().timeIntervalSince(cached.at) < 30 {
            lock.unlock()
            return cached.map
        }
        lock.unlock()
        // The text input APIs belong to the main thread. A caller on another thread asks it and waits briefly;
        // if the main thread is busy, the caller falls back to the US positions.
        var built: [Character: Key]?
        if Thread.isMainThread {
            built = build()
        } else {
            let done = DispatchSemaphore(value: 0)
            let box = Box()
            DispatchQueue.main.async {
                box.map = build()
                done.signal()
            }
            if done.wait(timeout: .now() + 0.3) == .success { built = box.map }
        }
        guard let built, !built.isEmpty else { return nil }
        lock.lock(); cached = (Date(), built); lock.unlock()
        return built
    }

    private final class Box: @unchecked Sendable { var map: [Character: Key]? }

    private static func build() -> [Character: Key]? {
        guard let source = TISCopyCurrentKeyboardLayoutInputSource()?.takeRetainedValue(),
              let pointer = TISGetInputSourceProperty(source, kTISPropertyUnicodeKeyLayoutData) else { return nil }
        let data = Unmanaged<CFData>.fromOpaque(pointer).takeUnretainedValue() as Data
        var map: [Character: Key] = [:]
        data.withUnsafeBytes { raw in
            guard let layout = raw.bindMemory(to: UCKeyboardLayout.self).baseAddress else { return }
            for shift in [false, true] {
                for code in UInt16(0)..<UInt16(51) {   // the printable keys of ANSI and ISO keyboards
                    var deadKeys: UInt32 = 0
                    var length = 0
                    var characters = [UniChar](repeating: 0, count: 4)
                    let status = UCKeyTranslate(
                        layout, code, UInt16(kUCKeyActionDown), shift ? UInt32(shiftKey >> 8) & 0xFF : 0,
                        UInt32(LMGetKbdType()), OptionBits(kUCKeyTranslateNoDeadKeysBit), &deadKeys, 4, &length, &characters
                    )
                    guard status == noErr, length == 1, let scalar = UnicodeScalar(characters[0]),
                          !CharacterSet.controlCharacters.contains(scalar) else { continue }
                    let character = Character(scalar)
                    if map[character] == nil { map[character] = (CGKeyCode(code), shift) }
                }
            }
        }
        return map
    }
}
