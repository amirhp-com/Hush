import Foundation

/// Runs command-line tools. Apps launched from Finder don't get the shell PATH,
/// so Homebrew's folders are always added.
enum Shell {
    static let searchPath = "/opt/homebrew/bin:/opt/homebrew/sbin:/usr/local/bin:/usr/local/sbin:/usr/bin:/bin:/usr/sbin:/sbin"

    static var environment: [String: String] {
        var env = ProcessInfo.processInfo.environment
        let inherited = env["PATH"] ?? ""
        env["PATH"] = inherited.isEmpty ? searchPath : "\(searchPath):\(inherited)"
        if env["HOME"] == nil { env["HOME"] = NSHomeDirectory() }
        env["HOMEBREW_NO_AUTO_UPDATE"] = env["HOMEBREW_NO_AUTO_UPDATE"] ?? "1"
        env["HOMEBREW_NO_ENV_HINTS"] = "1"
        return env
    }

    static func which(_ name: String) -> String? {
        for dir in searchPath.split(separator: ":") {
            let path = "\(dir)/\(name)"
            if FileManager.default.isExecutableFile(atPath: path) { return path }
        }
        return nil
    }

    struct Result {
        var status: Int32
        var output: String
        var ok: Bool { status == 0 }
    }

    /// Runs to completion and returns combined stdout and stderr.
    @discardableResult
    static func run(_ executable: String, _ args: [String], stdin: String? = nil) async -> Result {
        let runner = ProcessRunner(executable: executable, arguments: args)
        return await runner.run(stdin: stdin)
    }
}

/// A process that can stream its output line by line, be paused, resumed and cancelled.
final class ProcessRunner: @unchecked Sendable {
    let executable: String
    let arguments: [String]
    private let process = Process()
    private let lock = NSLock()
    private var buffer = ""
    private var collected = ""
    private(set) var cancelled = false

    init(executable: String, arguments: [String]) {
        self.executable = executable
        self.arguments = arguments
    }

    func run(stdin: String? = nil, onLine: ((String) -> Void)? = nil) async -> Shell.Result {
        process.executableURL = URL(fileURLWithPath: executable)
        process.arguments = arguments
        process.environment = Shell.environment
        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = pipe
        let input = Pipe()
        process.standardInput = stdin == nil ? FileHandle.nullDevice : input

        pipe.fileHandleForReading.readabilityHandler = { [weak self] handle in
            let data = handle.availableData
            guard let self, !data.isEmpty else { return }
            self.consume(String(decoding: data, as: UTF8.self), onLine: onLine)
        }

        return await withCheckedContinuation { continuation in
            process.terminationHandler = { [weak self] proc in
                pipe.fileHandleForReading.readabilityHandler = nil
                // Don't block on EOF: a grandchild (e.g. a brew helper) may keep the pipe open.
                let rest = Self.drain(pipe.fileHandleForReading)
                guard let self else {
                    continuation.resume(returning: Shell.Result(status: proc.terminationStatus, output: ""))
                    return
                }
                if !rest.isEmpty { self.consume(String(decoding: rest, as: UTF8.self), onLine: onLine) }
                self.flush(onLine: onLine)
                self.lock.lock()
                let out = self.collected
                self.lock.unlock()
                continuation.resume(returning: Shell.Result(status: proc.terminationStatus, output: out))
            }
            do {
                try process.run()
                if let stdin {
                    input.fileHandleForWriting.write(Data(stdin.utf8))
                    try? input.fileHandleForWriting.close()
                }
            } catch {
                pipe.fileHandleForReading.readabilityHandler = nil
                continuation.resume(returning: Shell.Result(status: -1, output: "Couldn't start \(executable): \(error.localizedDescription)"))
            }
        }
    }

    private static func drain(_ handle: FileHandle) -> Data {
        let fd = handle.fileDescriptor
        _ = fcntl(fd, F_SETFL, fcntl(fd, F_GETFL) | O_NONBLOCK)
        var data = Data()
        var buffer = [UInt8](repeating: 0, count: 65_536)
        while true {
            let n = read(fd, &buffer, buffer.count)
            if n <= 0 { break }
            data.append(buffer, count: n)
        }
        return data
    }

    private func consume(_ text: String, onLine: ((String) -> Void)?) {
        lock.lock()
        collected += text
        if collected.count > 400_000 { collected = String(collected.suffix(200_000)) }
        buffer += text
        var lines: [String] = []
        while let idx = buffer.firstIndex(where: { $0 == "\n" || $0 == "\r" }) {
            lines.append(String(buffer[..<idx]))
            buffer = String(buffer[buffer.index(after: idx)...])
        }
        lock.unlock()
        lines.filter { !$0.isEmpty }.forEach { onLine?($0) }
    }

    private func flush(onLine: ((String) -> Void)?) {
        lock.lock()
        let rest = buffer
        buffer = ""
        lock.unlock()
        if !rest.isEmpty { onLine?(rest) }
    }

    func cancel() {
        cancelled = true
        if process.isRunning {
            kill(process.processIdentifier, SIGCONT)
            process.terminate()
        }
    }

    func pause() { if process.isRunning { kill(process.processIdentifier, SIGSTOP) } }
    func resume() { if process.isRunning { kill(process.processIdentifier, SIGCONT) } }
}
