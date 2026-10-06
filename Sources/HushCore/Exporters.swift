import Foundation

public enum ExportFormat: String, CaseIterable, Codable, Identifiable, Sendable {
    case txt, timestamped, srt, vtt, lrc, csv, json, md, docx, pdf

    public var id: String { rawValue }

    public var fileExtension: String {
        switch self {
        case .timestamped: return "txt"
        default: return rawValue
        }
    }

    public var title: String {
        switch self {
        case .txt: return "Plain text (.txt)"
        case .timestamped: return "Text with times (.txt)"
        case .srt: return "Subtitles (.srt)"
        case .vtt: return "Web subtitles (.vtt)"
        case .lrc: return "Lyrics (.lrc)"
        case .csv: return "Spreadsheet (.csv)"
        case .json: return "JSON (.json)"
        case .md: return "Markdown (.md)"
        case .docx: return "Word (.docx)"
        case .pdf: return "PDF (.pdf)"
        }
    }

    /// Formats that HushCore renders as text. DOCX and PDF are built by the app.
    public var isText: Bool { self != .docx && self != .pdf }

    public var fileSuffix: String { self == .timestamped ? ".timed" : "" }
}

public enum Exporter {
    public static func render(_ format: ExportFormat, segments: [Segment], title: String = "", language: String? = nil) -> String {
        switch format {
        case .txt:
            return segments.map(\.text).joined(separator: "\n") + "\n"
        case .timestamped:
            return segments.map { "[\(TimeFormat.short($0.start))] \($0.text)" }.joined(separator: "\n") + "\n"
        case .srt:
            return segments.enumerated().map { i, s in
                "\(i + 1)\n\(TimeFormat.clock(s.start)) --> \(TimeFormat.clock(s.end))\n\(s.text)\n"
            }.joined(separator: "\n")
        case .vtt:
            let body = segments.map { s in
                "\(TimeFormat.clock(s.start, separator: ".")) --> \(TimeFormat.clock(s.end, separator: "."))\n\(s.text)\n"
            }.joined(separator: "\n")
            return "WEBVTT\n\n" + body
        case .lrc:
            var lines: [String] = []
            if !title.isEmpty { lines.append("[ti:\(title)]") }
            for s in segments {
                let cs = Int((s.start * 100).rounded())
                lines.append(String(format: "[%02d:%02d.%02d]", cs / 6000, cs % 6000 / 100, cs % 100) + s.text)
            }
            return lines.joined(separator: "\n") + "\n"
        case .csv:
            var lines = ["start,end,text"]
            for s in segments {
                let text = "\"" + s.text.replacingOccurrences(of: "\"", with: "\"\"") + "\""
                lines.append(String(format: "%.2f,%.2f,", s.start, s.end) + text)
            }
            return lines.joined(separator: "\n") + "\n"
        case .json:
            let payload: [String: Any] = [
                "title": title,
                "language": language ?? "",
                "segments": segments.map { ["start": $0.start, "end": $0.end, "text": $0.text] }
            ]
            let data = (try? JSONSerialization.data(withJSONObject: payload, options: [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes])) ?? Data()
            return String(decoding: data, as: UTF8.self) + "\n"
        case .md:
            var out = title.isEmpty ? "" : "# \(title)\n\n"
            out += segments.map { "**\(TimeFormat.short($0.start))** \($0.text)" }.joined(separator: "\n\n")
            return out + "\n"
        case .docx, .pdf:
            return segments.map(\.text).joined(separator: "\n")
        }
    }

    public static func isRightToLeft(_ text: String) -> Bool {
        var rtl = 0, ltr = 0
        for scalar in text.unicodeScalars.prefix(4000) {
            switch scalar.value {
            case 0x0590...0x08FF, 0xFB1D...0xFDFF, 0xFE70...0xFEFF: rtl += 1
            case 0x41...0x5A, 0x61...0x7A: ltr += 1
            default: break
            }
        }
        return rtl > ltr
    }
}

public enum TextChunker {
    /// Splits text into pieces no longer than `limit`, preferring line breaks, then spaces.
    public static func split(_ text: String, limit: Int) -> [String] {
        var chunks: [String] = []
        var rest = Substring(text.trimmingCharacters(in: .whitespacesAndNewlines))
        while rest.count > limit {
            let window = rest.prefix(limit)
            var cut = window.lastIndex(of: "\n") ?? window.lastIndex(of: " ")
            if let c = cut, rest.distance(from: rest.startIndex, to: c) < limit / 3 { cut = nil }
            let end = cut ?? window.endIndex
            chunks.append(String(rest[..<end]).trimmingCharacters(in: .whitespacesAndNewlines))
            rest = rest[end...].drop { $0 == " " || $0 == "\n" }
        }
        if !rest.isEmpty { chunks.append(String(rest)) }
        return chunks.filter { !$0.isEmpty }
    }

    /// Telegram captions are limited to 1024 characters.
    public static func fitsCaption(_ text: String, limit: Int = 1024) -> Bool { text.count <= limit }
}
