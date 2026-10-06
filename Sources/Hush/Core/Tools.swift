import AppKit
import Foundation

enum Tool: String, CaseIterable, Identifiable {
    case homebrew, whisper, ffmpeg, piper
    var id: String { rawValue }

    var title: String {
        switch self {
        case .homebrew: return "Homebrew"
        case .whisper: return "whisper.cpp"
        case .ffmpeg: return "FFmpeg"
        case .piper: return "Piper"
        }
    }

    var purpose: String {
        switch self {
        case .homebrew: return L("Installs and updates the other tools.")
        case .whisper: return L("Turns speech into text, offline on this Mac.")
        case .ffmpeg: return L("Reads audio and video files and converts them.")
        case .piper: return L("Natural text-to-speech voices, including Persian.")
        }
    }

    var required: Bool { self == .whisper || self == .ffmpeg }

    /// Executables this tool provides; the first one is used to detect it.
    var binaries: [String] {
        switch self {
        case .homebrew: return ["brew"]
        case .whisper: return ["whisper-cli", "whisper-server"]
        case .ffmpeg: return ["ffmpeg", "ffprobe"]
        case .piper: return ["piper"]
        }
    }

    var formula: String? {
        switch self {
        case .whisper: return "whisper.cpp"
        case .ffmpeg: return "ffmpeg"
        default: return nil
        }
    }
}

struct ToolStatus: Equatable {
    var path: String?
    var version: String?
    var outdated: Bool = false
    var installed: Bool { path != nil }
}

@MainActor
final class ToolManager: ObservableObject {
    static let shared = ToolManager()

    @Published private(set) var status: [Tool: ToolStatus] = [:]
    @Published private(set) var busy: Tool?
    @Published var log = ""

    static var piperEnv: URL { Paths.folder("piper-env") }

    private init() {}

    func path(_ binary: String) -> String? {
        if let custom = AppSettings.shared.toolOverrides[binary], FileManager.default.isExecutableFile(atPath: custom) { return custom }
        if binary == "piper" {
            let p = Self.piperEnv.appendingPathComponent("bin/piper").path
            return FileManager.default.isExecutableFile(atPath: p) ? p : nil
        }
        return Shell.which(binary)
    }

    var whisperCLI: String? { path("whisper-cli") }
    var whisperServer: String? { path("whisper-server") }
    var ffmpeg: String? { path("ffmpeg") }
    var ffprobe: String? { path("ffprobe") }
    var piper: String? { path("piper") }
    var brew: String? { path("brew") }

    var missingRequired: [Tool] { Tool.allCases.filter { $0.required && !(status[$0]?.installed ?? (path($0.binaries[0]) != nil)) } }

    func refresh() async {
        var result: [Tool: ToolStatus] = [:]
        for tool in Tool.allCases {
            var s = ToolStatus(path: path(tool.binaries[0]))
            if s.installed { s.version = await version(of: tool) }
            result[tool] = s
        }
        status = result
        await checkOutdated()
    }

    private func version(of tool: Tool) async -> String? {
        switch tool {
        case .homebrew:
            guard let brew else { return nil }
            return (await Shell.run(brew, ["--version"])).output.split(separator: "\n").first.map { String($0).replacingOccurrences(of: "Homebrew ", with: "") }
        case .ffmpeg:
            guard let ffmpeg else { return nil }
            let line = (await Shell.run(ffmpeg, ["-version"])).output.split(separator: "\n").first.map(String.init) ?? ""
            return line.components(separatedBy: " ").dropFirst(2).first
        case .whisper:
            if let brew, case let r = await Shell.run(brew, ["list", "--versions", "whisper.cpp"]), r.ok {
                return r.output.split(separator: " ").last.map { String($0).trimmingCharacters(in: .whitespacesAndNewlines) }
            }
            return L("installed")
        case .piper:
            let pip = Self.piperEnv.appendingPathComponent("bin/pip").path
            guard FileManager.default.isExecutableFile(atPath: pip) else { return L("installed") }
            let r = await Shell.run(pip, ["show", "piper-tts"])
            return r.output.split(separator: "\n").first { $0.hasPrefix("Version:") }.map { $0.replacingOccurrences(of: "Version: ", with: "") }
        }
    }

    private func checkOutdated() async {
        guard let brew else { return }
        let r = await Shell.run(brew, ["outdated", "--json=v2", "whisper.cpp", "ffmpeg"])
        guard let json = try? JSONSerialization.jsonObject(with: Data(r.output.utf8)) as? [String: Any],
              let formulae = json["formulae"] as? [[String: Any]] else { return }
        let names = Set(formulae.compactMap { $0["name"] as? String })
        if names.contains("whisper.cpp") { status[.whisper]?.outdated = true }
        if names.contains("ffmpeg") { status[.ffmpeg]?.outdated = true }
    }

    /// Install or update a tool, streaming the log.
    func install(_ tool: Tool, update: Bool = false) async {
        guard busy == nil else { return }
        busy = tool
        log = ""
        defer { busy = nil }
        switch tool {
        case .homebrew:
            installHomebrew()
            return
        case .whisper, .ffmpeg:
            guard let brew, let formula = tool.formula else {
                append(L("Homebrew is needed first. Install it above, then try again."))
                return
            }
            await stream(brew, [update ? "upgrade" : "install", formula])
        case .piper:
            await installPiper(update: update)
        }
        await refresh()
    }

    private func installPiper(update: Bool) async {
        let python = Shell.which("python3.12") ?? Shell.which("python3.11") ?? Shell.which("python3") ?? "/usr/bin/python3"
        let env = Self.piperEnv
        let pip = env.appendingPathComponent("bin/pip").path
        if !FileManager.default.isExecutableFile(atPath: pip) {
            append("$ \(python) -m venv \(env.path)")
            let r = await stream(python, ["-m", "venv", env.path])
            guard r == 0 else {
                append(L("Python 3 is needed for Piper. Install it with Homebrew (brew install python) and try again."))
                return
            }
        }
        await stream(pip, ["install", "--upgrade", "pip"])
        await stream(pip, ["install", update ? "--upgrade" : "--upgrade-strategy=only-if-needed", "piper-tts"])
    }

    func uninstallPiper() async {
        try? FileManager.default.removeItem(at: Self.piperEnv)
        await refresh()
    }

    @discardableResult
    private func stream(_ exe: String, _ args: [String]) async -> Int32 {
        append("$ \((exe as NSString).lastPathComponent) \(args.joined(separator: " "))")
        let runner = ProcessRunner(executable: exe, arguments: args)
        let result = await runner.run { line in
            Task { @MainActor in ToolManager.shared.append(line) }
        }
        append(result.ok ? "✓ " + L("Done") : "✗ " + L("Failed with code %d", result.status))
        return result.status
    }

    func append(_ line: String) {
        log += line + "\n"
        if log.count > 60_000 { log = String(log.suffix(40_000)) }
    }

    private func installHomebrew() {
        let command = #"/bin/bash -c \"$(curl -fsSL https://raw.githubusercontent.com/Homebrew/install/HEAD/install.sh)\""#
        let script = "tell application \"Terminal\"\nactivate\ndo script \"\(command)\"\nend tell"
        var error: NSDictionary?
        NSAppleScript(source: script)?.executeAndReturnError(&error)
        if error != nil {
            NSWorkspace.shared.open(URL(string: "https://brew.sh")!)
        }
        append(L("The Homebrew installer opened in Terminal. Follow its steps, then click Refresh."))
    }
}
