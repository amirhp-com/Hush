import AVFoundation
import Foundation
import HushCore

struct Voice: Identifiable, Hashable {
    enum Engine: String { case system, piper }
    var engine: Engine
    var key: String
    var name: String
    var language: String
    var id: String { engine.rawValue + ":" + key }
}

struct PiperVoiceInfo: Identifiable, Hashable {
    var key: String
    var name: String
    var language: String
    var languageName: String
    var quality: String
    var bytes: Int64
    var onnxPath: String
    var id: String { key }
}

/// Text to speech with the macOS voices (`say`) and Piper (natural voices, including Persian).
@MainActor
final class Speech: ObservableObject {
    static let shared = Speech()

    @Published private(set) var piperCatalog: [PiperVoiceInfo] = []
    @Published private(set) var installedPiper: [String] = []
    @Published private(set) var downloading: [String: Double] = [:]
    @Published var error: String?

    private var player: AVAudioPlayer?
    private var downloads: [String: FileDownload] = [:]

    var voicesFolder: URL { Paths.folder("PiperVoices") }

    private init() { scanPiper() }

    var systemVoices: [Voice] {
        AVSpeechSynthesisVoice.speechVoices()
            .map { Voice(engine: .system, key: $0.name, name: $0.name, language: $0.language) }
            .sorted { ($0.language, $0.name) < ($1.language, $1.name) }
    }

    var piperVoices: [Voice] {
        installedPiper.map { key in
            let info = piperCatalog.first { $0.key == key }
            return Voice(engine: .piper, key: key, name: info.map { "\($0.name) (\($0.quality))" } ?? key, language: info?.language ?? String(key.prefix(5)))
        }
    }

    var allVoices: [Voice] { piperVoices + systemVoices }

    func voice(id: String) -> Voice? { allVoices.first { $0.id == id } }

    /// The best voice for a text: an installed Persian Piper voice for Persian, otherwise the chosen or system voice.
    func bestVoice(for text: String) -> Voice? {
        if Exporter.isRightToLeft(text) {
            if let v = piperVoices.first(where: { $0.language.hasPrefix("fa") }) { return v }
            return systemVoices.first { $0.language.hasPrefix("fa") || $0.language.hasPrefix("ar") }
        }
        if let chosen = voice(id: AppSettings.shared.ttsVoice), !chosen.language.hasPrefix("fa") { return chosen }
        return systemVoices.first { $0.language.hasPrefix("en") } ?? systemVoices.first
    }

    // MARK: - Synthesis

    func synthesize(_ text: String, voice: Voice, rate: Double) async throws -> URL {
        let out = Paths.temp.appendingPathComponent("speech-\(UUID().uuidString.prefix(8))")
        switch voice.engine {
        case .system:
            let file = out.appendingPathExtension("aiff")
            let input = out.appendingPathExtension("txt")
            try text.write(to: input, atomically: true, encoding: .utf8)
            defer { try? FileManager.default.removeItem(at: input) }
            let wpm = Int(180 * rate)
            let r = await Shell.run("/usr/bin/say", ["-v", voice.key, "-r", "\(wpm)", "-o", file.path, "-f", input.path])
            guard r.ok else { throw MediaError.failed(r.output) }
            return file
        case .piper:
            guard let piper = ToolManager.shared.piper else { throw MediaError.missingTool("Piper") }
            let model = voicesFolder.appendingPathComponent(voice.key + ".onnx")
            let file = out.appendingPathExtension("wav")
            let lengthScale = String(format: "%.2f", 1 / max(0.3, rate))
            let r = await Shell.run(piper, ["-m", model.path, "-f", file.path, "--length-scale", lengthScale], stdin: text)
            guard r.ok, FileManager.default.fileExists(atPath: file.path) else { throw MediaError.failed(String(r.output.suffix(400))) }
            return file
        }
    }

    func synthesizeForTelegram(_ text: String) async throws -> URL {
        guard let voice = bestVoice(for: text) else { throw MediaError.failed(L("No voice is available.")) }
        let audio = try await synthesize(text, voice: voice, rate: AppSettings.shared.ttsRate)
        defer { try? FileManager.default.removeItem(at: audio) }
        return try await Media.convertAudio(audio, to: .ogg)
    }

    func play(_ url: URL) {
        player = try? AVAudioPlayer(contentsOf: url)
        player?.play()
    }

    func stop() { player?.stop() }
    var isPlaying: Bool { player?.isPlaying ?? false }

    // MARK: - Piper voices

    func scanPiper() {
        let files = (try? FileManager.default.contentsOfDirectory(atPath: voicesFolder.path)) ?? []
        installedPiper = files.filter { $0.hasSuffix(".onnx") }.map { String($0.dropLast(5)) }.sorted()
    }

    func refreshPiperCatalog() async {
        let host = AppSettings.shared.modelSource.host
        guard let url = URL(string: "\(host)/rhasspy/piper-voices/resolve/main/voices.json") else { return }
        do {
            let (data, _) = try await Network.shared.session.data(from: url)
            guard let json = try JSONSerialization.jsonObject(with: data) as? [String: [String: Any]] else { return }
            piperCatalog = json.values.compactMap { v in
                guard let key = v["key"] as? String, let files = v["files"] as? [String: [String: Any]],
                      let onnx = files.first(where: { $0.key.hasSuffix(".onnx") }) else { return nil }
                let lang = v["language"] as? [String: Any] ?? [:]
                return PiperVoiceInfo(key: key, name: v["name"] as? String ?? key, language: lang["code"] as? String ?? "",
                                      languageName: "\(lang["name_native"] as? String ?? "") · \(lang["country_english"] as? String ?? "")",
                                      quality: v["quality"] as? String ?? "", bytes: (onnx.value["size_bytes"] as? NSNumber)?.int64Value ?? 0, onnxPath: onnx.key)
            }.sorted { a, b in
                let fa = (a.language.hasPrefix("fa"), b.language.hasPrefix("fa"))
                if fa.0 != fa.1 { return fa.0 }
                return (a.language, a.name) < (b.language, b.name)
            }
            error = nil
        } catch {
            self.error = L("Couldn't load the voice list: %@", error.localizedDescription)
        }
    }

    func download(_ info: PiperVoiceInfo) {
        guard downloads[info.key] == nil else { return }
        let host = AppSettings.shared.modelSource.host
        let base = "\(host)/rhasspy/piper-voices/resolve/main/"
        guard let modelURL = URL(string: base + info.onnxPath), let configURL = URL(string: base + info.onnxPath + ".json") else { return }
        let config = FileDownload(url: configURL, destination: voicesFolder.appendingPathComponent(info.key + ".onnx.json"))
        config.start()
        let model = FileDownload(url: modelURL, destination: voicesFolder.appendingPathComponent(info.key + ".onnx"))
        model.onProgress = { f, _, _ in Task { @MainActor in Speech.shared.downloading[info.key] = f } }
        model.onFinish = { err in
            Task { @MainActor in
                let s = Speech.shared
                s.downloads[info.key] = nil
                s.downloading[info.key] = nil
                if let err, (err as NSError).code != NSURLErrorCancelled { s.error = err.localizedDescription }
                s.scanPiper()
            }
        }
        downloads[info.key] = model
        downloading[info.key] = 0
        model.start()
    }

    func cancelDownload(_ key: String) {
        downloads[key]?.cancel()
        downloads[key] = nil
        downloading[key] = nil
    }

    func deletePiper(_ key: String) {
        try? FileManager.default.removeItem(at: voicesFolder.appendingPathComponent(key + ".onnx"))
        try? FileManager.default.removeItem(at: voicesFolder.appendingPathComponent(key + ".onnx.json"))
        scanPiper()
    }
}
