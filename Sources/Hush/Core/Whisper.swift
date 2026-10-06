import Foundation
import HushCore

struct TranscribeOptions: Codable, Equatable {
    var model: String
    var language: String
    var translate: Bool
    var vad: Bool
    var maxLength: Int
    var splitOnWord: Bool
    var threads: Int
    var prompt: String
    var persianCleanup: Bool
    var formats: [ExportFormat]
    var outputFolder: String

    static func fromSettings() -> TranscribeOptions {
        let s = AppSettings.shared
        return TranscribeOptions(model: s.defaultModel, language: s.spokenLanguage, translate: s.translateToEnglish, vad: s.useVAD,
                                 maxLength: s.maxSegmentLength, splitOnWord: s.splitOnWord, threads: s.threads,
                                 prompt: s.initialPrompt, persianCleanup: s.persianCleanup,
                                 formats: ExportFormat.allCases.filter { s.formats.contains($0) }, outputFolder: s.outputFolder)
    }
}

/// Runs `whisper-cli` on a 16 kHz WAV and returns the segments.
final class WhisperEngine: @unchecked Sendable {
    private var runner: ProcessRunner?
    private(set) var cancelled = false

    static let vadModelFile = "ggml-silero-v5.1.2.bin"

    func cancel() { cancelled = true; runner?.cancel() }
    func pause() { runner?.pause() }
    func resume() { runner?.resume() }

    func transcribe(wav: URL, options: TranscribeOptions, progress: @escaping (Double) -> Void) async throws -> WhisperResult {
        guard let cli = await ToolManager.shared.whisperCLI else { throw MediaError.missingTool("whisper-cli") }
        let models = AppSettings.shared.modelsURL
        var modelURL = models.appendingPathComponent(options.model)
        if !FileManager.default.fileExists(atPath: modelURL.path) {
            guard let fallback = AppSettings.shared.defaultModelURL else {
                throw MediaError.failed(L("No speech model is downloaded yet. Open Settings → Models and download one."))
            }
            modelURL = fallback
        }
        let base = Paths.temp.appendingPathComponent(UUID().uuidString)
        var args = ["-m", modelURL.path, "-f", wav.path, "-l", options.language, "-t", "\(max(1, options.threads))", "-oj", "-of", base.path, "-pp"]
        if options.translate { args.append("-tr") }
        if options.maxLength > 0 { args += ["-ml", "\(options.maxLength)"] }
        if options.splitOnWord { args.append("-sow") }
        let prompt = options.prompt.trimmingCharacters(in: .whitespacesAndNewlines)
        if !prompt.isEmpty { args += ["--prompt", prompt] }
        let vadModel = models.appendingPathComponent(Self.vadModelFile)
        if options.vad, FileManager.default.fileExists(atPath: vadModel.path) { args += ["--vad", "-vm", vadModel.path] }

        var result = try await run(cli, args, base: base, progress: progress)
        if WhisperOutput.isStuck(result.segments), !cancelled {
            progress(0)
            let again = try await run(cli, args + ["--max-context", "0"], base: base, progress: progress)
            if !WhisperOutput.isStuck(again.segments) { result = again }
        }
        if options.persianCleanup, (result.language ?? options.language) == "fa" {
            result.segments = result.segments.map { var s = $0; s.text = PersianText.normalize(s.text); return s }
        }
        return result
    }

    private func run(_ cli: String, _ args: [String], base: URL, progress: @escaping (Double) -> Void) async throws -> WhisperResult {
        let p = ProcessRunner(executable: cli, arguments: args)
        runner = p
        let r = await p.run { line in
            if let value = WhisperOutput.progress(in: line) { progress(value) }
        }
        runner = nil
        let jsonURL = URL(fileURLWithPath: base.path + ".json")
        defer { try? FileManager.default.removeItem(at: jsonURL) }
        if cancelled { throw CancellationError() }
        guard r.ok, let data = try? Data(contentsOf: jsonURL), let parsed = WhisperOutput.parse(data) else {
            throw MediaError.failed(L("whisper-cli failed: %@", String(r.output.suffix(400))))
        }
        progress(1)
        return parsed
    }
}
