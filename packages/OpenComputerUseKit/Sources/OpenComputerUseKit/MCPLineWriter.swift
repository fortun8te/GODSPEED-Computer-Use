import Foundation

/// The request worker and overflow reader share one output stream. Serialize
/// complete UTF-8 lines so a busy refusal cannot split another JSON-RPC reply.
public final class MCPLineWriter: @unchecked Sendable {
    private let lock = NSLock()
    private let output: (Data) -> Void

    public convenience init(file: FileHandle = .standardOutput) {
        self.init(output: { file.write($0) })
    }

    init(output: @escaping (Data) -> Void) {
        self.output = output
    }

    public func writeLine(_ line: String) {
        writeLine(Data(line.utf8))
    }

    public func writeLine(_ data: Data) {
        lock.lock()
        defer { lock.unlock() }
        output(data + Data([10]))
    }
}
