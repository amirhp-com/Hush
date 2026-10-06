import Foundation

public struct Segment: Codable, Equatable, Hashable, Identifiable, Sendable {
    public var id: UUID
    public var start: Double
    public var end: Double
    public var text: String

    public init(id: UUID = UUID(), start: Double, end: Double, text: String) {
        self.id = id
        self.start = start
        self.end = end
        self.text = text
    }
}

public struct WhisperResult: Equatable, Sendable {
    public var language: String?
    public var segments: [Segment]

    public init(language: String?, segments: [Segment]) {
        self.language = language
        self.segments = segments
    }
}

public enum WhisperOutput {
    /// Parses the file written by `whisper-cli -oj`.
    public static func parse(_ data: Data) -> WhisperResult? {
        guard let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { return nil }
        let language = (json["result"] as? [String: Any])?["language"] as? String
        let items = json["transcription"] as? [[String: Any]] ?? []
        var segments: [Segment] = []
        for item in items {
            let text = (item["text"] as? String ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
            guard !text.isEmpty else { continue }
            let offsets = item["offsets"] as? [String: Any] ?? [:]
            let from = (offsets["from"] as? NSNumber)?.doubleValue ?? 0
            let to = (offsets["to"] as? NSNumber)?.doubleValue ?? from
            segments.append(Segment(start: from / 1000, end: to / 1000, text: text))
        }
        return WhisperResult(language: language, segments: segments)
    }

    /// Whisper sometimes locks onto one phrase for a whole file: every window returns the same few words.
    public static func isStuck(_ segments: [Segment]) -> Bool {
        guard segments.count >= 8 else { return false }
        var counts: [String: Int] = [:]
        for s in segments { counts[s.text, default: 0] += 1 }
        return Double(counts.values.max() ?? 0) >= 0.5 * Double(segments.count)
    }

    /// Reads `progress = 42%` lines printed by `whisper-cli -pp`.
    public static func progress(in line: String) -> Double? {
        guard let range = line.range(of: #"progress\s*=\s*(\d{1,3})%"#, options: .regularExpression) else { return nil }
        let digits = line[range].filter(\.isNumber)
        guard let value = Double(digits) else { return nil }
        return min(1, max(0, value / 100))
    }
}

public enum TimeFormat {
    public static func clock(_ seconds: Double, separator: Character = ",", forceHours: Bool = true) -> String {
        let ms = Int((max(0, seconds) * 1000).rounded())
        let h = ms / 3_600_000, m = ms % 3_600_000 / 60_000, s = ms % 60_000 / 1000, r = ms % 1000
        let base = forceHours || h > 0 ? String(format: "%02d:%02d:%02d", h, m, s) : String(format: "%02d:%02d", m, s)
        return base + String(separator) + String(format: "%03d", r)
    }

    public static func short(_ seconds: Double) -> String {
        let total = Int(max(0, seconds).rounded())
        let h = total / 3600, m = total % 3600 / 60, s = total % 60
        return h > 0 ? String(format: "%d:%02d:%02d", h, m, s) : String(format: "%d:%02d", m, s)
    }
}
