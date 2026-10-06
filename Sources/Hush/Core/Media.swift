import Foundation
import UniformTypeIdentifiers

struct MediaInfo: Codable, Equatable {
    var duration: Double
    var hasAudio: Bool
    var hasVideo: Bool
}

enum MediaError: LocalizedError {
    case missingTool(String)
    case failed(String)
    var errorDescription: String? {
        switch self {
        case .missingTool(let t): return L("%@ isn't installed. Open Settings → Tools to install it.", t)
        case .failed(let m): return m
        }
    }
}

enum Media {
    static let audioExtensions: Set<String> = ["ogg", "oga", "opus", "wav", "mp3", "m4a", "aac", "flac", "wma", "aif", "aiff", "caf", "amr", "weba"]
    static let videoExtensions: Set<String> = ["mp4", "mkv", "mov", "m4v", "webm", "avi", "3gp", "mts", "m2ts", "mpg", "mpeg", "wmv", "flv", "ts"]
    static var allExtensions: Set<String> { audioExtensions.union(videoExtensions) }

    static var contentTypes: [UTType] {
        allExtensions.compactMap { UTType(filenameExtension: $0) } + [.audio, .movie, .audiovisualContent]
    }

    static func isSupported(_ url: URL) -> Bool { allExtensions.contains(url.pathExtension.lowercased()) }
    static func isVideo(_ url: URL) -> Bool { videoExtensions.contains(url.pathExtension.lowercased()) }

    static func probe(_ url: URL) async throws -> MediaInfo {
        guard let ffprobe = await ToolManager.shared.ffprobe else { throw MediaError.missingTool("ffprobe") }
        let r = await Shell.run(ffprobe, ["-v", "error", "-show_format", "-show_streams", "-of", "json", url.path])
        guard r.ok, let json = try? JSONSerialization.jsonObject(with: Data(r.output.utf8)) as? [String: Any] else {
            throw MediaError.failed(L("Couldn't read this file. It may be damaged or not a media file."))
        }
        let streams = json["streams"] as? [[String: Any]] ?? []
        let format = json["format"] as? [String: Any] ?? [:]
        let duration = Double(format["duration"] as? String ?? "") ?? 0
        let audio = streams.contains { $0["codec_type"] as? String == "audio" }
        let video = streams.contains { s in
            s["codec_type"] as? String == "video" && ((s["disposition"] as? [String: Any])?["attached_pic"] as? Int) != 1
        }
        return MediaInfo(duration: duration, hasAudio: audio, hasVideo: video)
    }

    /// 16 kHz mono 16-bit WAV, the format whisper.cpp reads.
    static func toWhisperWAV(_ url: URL, runner: ((ProcessRunner) -> Void)? = nil) async throws -> URL {
        guard let ffmpeg = await ToolManager.shared.ffmpeg else { throw MediaError.missingTool("ffmpeg") }
        let out = Paths.temp.appendingPathComponent(UUID().uuidString + ".wav")
        let p = ProcessRunner(executable: ffmpeg, arguments: ["-v", "error", "-nostdin", "-y", "-i", url.path, "-vn", "-ar", "16000", "-ac", "1", "-c:a", "pcm_s16le", out.path])
        runner?(p)
        let r = await p.run()
        guard r.ok else { throw MediaError.failed(p.cancelled ? L("Cancelled") : L("Couldn't convert the audio: %@", String(r.output.suffix(300)))) }
        return out
    }

    enum AudioFormat: String, CaseIterable, Identifiable {
        case ogg, m4a, mp3, wav
        var id: String { rawValue }
        var args: [String] {
            switch self {
            case .ogg: return ["-c:a", "libopus", "-b:a", "48k", "-ac", "1"]
            case .m4a: return ["-c:a", "aac", "-b:a", "128k"]
            case .mp3: return ["-c:a", "libmp3lame", "-q:a", "4"]
            case .wav: return ["-c:a", "pcm_s16le"]
            }
        }
    }

    static func convertAudio(_ url: URL, to format: AudioFormat, destination: URL? = nil, bitrate: String? = nil) async throws -> URL {
        guard let ffmpeg = await ToolManager.shared.ffmpeg else { throw MediaError.missingTool("ffmpeg") }
        let out = destination ?? Paths.temp.appendingPathComponent(url.deletingPathExtension().lastPathComponent + "-" + UUID().uuidString.prefix(6) + "." + format.rawValue)
        var args = format.args
        if let bitrate, let i = args.firstIndex(of: "-b:a") { args[i + 1] = bitrate }
        let r = await Shell.run(ffmpeg, ["-v", "error", "-nostdin", "-y", "-i", url.path, "-vn"] + args + [out.path])
        guard r.ok else { throw MediaError.failed(L("Couldn't convert the audio: %@", String(r.output.suffix(300)))) }
        return out
    }

    /// Splits audio into parts no bigger than `maxBytes` (Telegram bots may upload 50 MB).
    static func splitForUpload(_ url: URL, maxBytes: Int64, duration: Double) async throws -> [URL] {
        let size = (try? FileManager.default.attributesOfItem(atPath: url.path)[.size] as? Int64) ?? 0
        guard size > maxBytes, duration > 0, let ffmpeg = await ToolManager.shared.ffmpeg else { return [url] }
        let parts = Int((Double(size) / Double(maxBytes) * 1.1).rounded(.up))
        let seconds = Int(duration / Double(parts)) + 1
        let folder = Paths.temp.appendingPathComponent("split-" + UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let pattern = folder.appendingPathComponent(url.deletingPathExtension().lastPathComponent + " part %02d." + url.pathExtension).path
        let r = await Shell.run(ffmpeg, ["-v", "error", "-nostdin", "-y", "-i", url.path, "-f", "segment", "-segment_time", "\(seconds)", "-c", "copy", pattern])
        guard r.ok else { throw MediaError.failed(r.output) }
        return (try FileManager.default.contentsOfDirectory(at: folder, includingPropertiesForKeys: nil)).sorted { $0.lastPathComponent < $1.lastPathComponent }
    }
}
