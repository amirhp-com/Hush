import Foundation

public struct WhisperModel: Codable, Hashable, Identifiable, Sendable {
    public var file: String
    public var bytes: Int64
    public var id: String { file }

    public init(file: String, bytes: Int64) {
        self.file = file
        self.bytes = bytes
    }

    /// "ggml-large-v3-turbo-q5_0.bin" → "large-v3-turbo-q5_0"
    public var name: String {
        var n = file
        if n.hasPrefix("ggml-") { n.removeFirst(5) }
        if n.hasSuffix(".bin") { n.removeLast(4) }
        return n
    }

    public var family: String {
        let base = name.components(separatedBy: "-q").first ?? name
        return base.replacingOccurrences(of: ".en", with: "")
    }

    public var englishOnly: Bool { name.contains(".en") }
    public var quantized: String? { name.range(of: #"q\d_\d"#, options: .regularExpression).map { String(name[$0]) } }
    public var isDiarize: Bool { name.contains("tdrz") }

    /// 1 (fastest) … 5 (slowest)
    public var speed: Int {
        switch family {
        case "tiny": return 5
        case "base": return 4
        case "small": return 3
        case "large-v3-turbo": return 3
        case "medium": return 2
        default: return 1
        }
    }

    /// 1 … 5 (most accurate)
    public var accuracy: Int {
        switch family {
        case "tiny": return 1
        case "base": return 2
        case "small": return 3
        case "medium": return 4
        default: return 5
        }
    }

    public var isRecommended: Bool { name == "large-v3-turbo-q5_0" || name == "small" }

    /// Parses `https://huggingface.co/api/models/ggerganov/whisper.cpp/tree/main`.
    public static func parseTree(_ data: Data) -> [WhisperModel] {
        guard let items = try? JSONSerialization.jsonObject(with: data) as? [[String: Any]] else { return [] }
        return items.compactMap { item in
            guard let path = item["path"] as? String, path.hasPrefix("ggml-"), path.hasSuffix(".bin") else { return nil }
            let size = (item["size"] as? NSNumber)?.int64Value ?? ((item["lfs"] as? [String: Any])?["size"] as? NSNumber)?.int64Value ?? 0
            return WhisperModel(file: path, bytes: size)
        }.sorted(by: order)
    }

    public static func order(_ a: WhisperModel, _ b: WhisperModel) -> Bool {
        let rank = ["tiny", "base", "small", "medium", "large-v1", "large-v2", "large-v3", "large-v3-turbo"]
        let ra = rank.firstIndex(of: a.family) ?? 99, rb = rank.firstIndex(of: b.family) ?? 99
        return ra != rb ? ra < rb : a.name < b.name
    }

    /// Offline fallback when Hugging Face can't be reached.
    public static let builtIn: [WhisperModel] = [
        .init(file: "ggml-tiny.bin", bytes: 77_691_713),
        .init(file: "ggml-base.bin", bytes: 147_951_465),
        .init(file: "ggml-small.bin", bytes: 487_601_967),
        .init(file: "ggml-medium.bin", bytes: 1_533_763_059),
        .init(file: "ggml-large-v3.bin", bytes: 3_095_033_483),
        .init(file: "ggml-large-v3-turbo.bin", bytes: 1_624_555_275),
        .init(file: "ggml-large-v3-turbo-q5_0.bin", bytes: 574_041_195),
        .init(file: "ggml-large-v3-turbo-q8_0.bin", bytes: 874_188_075)
    ]
}
