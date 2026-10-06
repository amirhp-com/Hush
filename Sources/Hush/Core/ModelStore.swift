import Foundation
import HushCore

@MainActor
final class ModelStore: ObservableObject {
    static let shared = ModelStore()

    struct Progress: Equatable {
        var fraction: Double
        var written: Int64
        var total: Int64
    }

    @Published private(set) var available: [WhisperModel] = WhisperModel.builtIn
    @Published private(set) var installed: [String] = []
    @Published private(set) var downloads: [String: Progress] = [:]
    @Published var error: String?
    @Published private(set) var loading = false

    private var tasks: [String: FileDownload] = [:]

    private init() { scanInstalled() }

    var directory: URL { AppSettings.shared.modelsURL }

    func scanInstalled() {
        let files = (try? FileManager.default.contentsOfDirectory(atPath: directory.path)) ?? []
        installed = files.filter { $0.hasPrefix("ggml-") && $0.hasSuffix(".bin") && !$0.contains("silero") }.sorted {
            WhisperModel.order(WhisperModel(file: $0, bytes: 0), WhisperModel(file: $1, bytes: 0))
        }
    }

    var hasVADModel: Bool { FileManager.default.fileExists(atPath: directory.appendingPathComponent(WhisperEngine.vadModelFile).path) }

    func refreshCatalog() async {
        loading = true
        defer { loading = false }
        let host = AppSettings.shared.modelSource.host
        guard let url = URL(string: "\(host)/api/models/ggerganov/whisper.cpp/tree/main") else { return }
        do {
            let (data, _) = try await Network.shared.session.data(from: url)
            let models = WhisperModel.parseTree(data)
            if !models.isEmpty { available = models; error = nil }
        } catch {
            self.error = L("Couldn't load the model list (%@). Showing the built-in list.", error.localizedDescription)
        }
        scanInstalled()
    }

    func isInstalled(_ file: String) -> Bool { installed.contains(file) || (file == WhisperEngine.vadModelFile && hasVADModel) }

    func download(_ file: String) {
        guard tasks[file] == nil else { return }
        let host = AppSettings.shared.modelSource.host
        let repo = file.contains("silero") ? "ggml-org/whisper-vad" : "ggerganov/whisper.cpp"
        guard let url = URL(string: "\(host)/\(repo)/resolve/main/\(file)") else { return }
        let task = FileDownload(url: url, destination: directory.appendingPathComponent(file))
        task.onProgress = { fraction, written, total in
            Task { @MainActor in ModelStore.shared.downloads[file] = Progress(fraction: fraction, written: written, total: total) }
        }
        task.onFinish = { err in
            Task { @MainActor in
                let store = ModelStore.shared
                store.tasks[file] = nil
                store.downloads[file] = nil
                if let err, (err as NSError).code != NSURLErrorCancelled {
                    store.error = L("Download of %@ failed: %@", file, err.localizedDescription)
                }
                store.scanInstalled()
                if err == nil, !AppSettings.shared.defaultModelExists, !file.contains("silero") {
                    AppSettings.shared.defaultModel = file
                }
            }
        }
        tasks[file] = task
        downloads[file] = Progress(fraction: 0, written: 0, total: 0)
        task.start()
    }

    func cancel(_ file: String) {
        tasks[file]?.cancel()
        tasks[file] = nil
        downloads[file] = nil
    }

    func delete(_ file: String) {
        try? FileManager.default.removeItem(at: directory.appendingPathComponent(file))
        scanInstalled()
    }
}

extension AppSettings {
    var defaultModelExists: Bool { FileManager.default.fileExists(atPath: modelsURL.appendingPathComponent(defaultModel).path) }
}
