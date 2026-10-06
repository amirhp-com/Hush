import XCTest
@testable import HushCore

final class HushCoreTests: XCTestCase {
    let segs = [Segment(start: 0, end: 2.5, text: "Hello"), Segment(start: 2.5, end: 3661.25, text: "World, \"quoted\"")]

    func testSRT() {
        let srt = Exporter.render(.srt, segments: segs)
        XCTAssertTrue(srt.hasPrefix("1\n00:00:00,000 --> 00:00:02,500\nHello\n"))
        XCTAssertTrue(srt.contains("2\n00:00:02,500 --> 01:01:01,250\n"))
    }

    func testVTTAndLRCAndCSV() {
        XCTAssertTrue(Exporter.render(.vtt, segments: segs).hasPrefix("WEBVTT\n\n00:00:00.000 --> 00:00:02.500"))
        XCTAssertTrue(Exporter.render(.lrc, segments: segs).contains("[00:02.50]World"))
        XCTAssertTrue(Exporter.render(.csv, segments: segs).contains("\"World, \"\"quoted\"\"\""))
    }

    func testProgress() {
        XCTAssertEqual(WhisperOutput.progress(in: "whisper_print_progress_callback: progress =  45%"), 0.45)
        XCTAssertNil(WhisperOutput.progress(in: "something else"))
    }

    func testParseAndStuck() throws {
        let json = #"{"result":{"language":"fa"},"transcription":[{"offsets":{"from":0,"to":1500},"text":" سلام "},{"offsets":{"from":1500,"to":2000},"text":""}]}"#
        let r = try XCTUnwrap(WhisperOutput.parse(Data(json.utf8)))
        XCTAssertEqual(r.language, "fa")
        XCTAssertEqual(r.segments.count, 1)
        XCTAssertEqual(r.segments[0].end, 1.5)
        let stuck = (0..<10).map { _ in Segment(start: 0, end: 1, text: "same") }
        XCTAssertTrue(WhisperOutput.isStuck(stuck))
        XCTAssertFalse(WhisperOutput.isStuck(segs))
    }

    func testChunker() {
        let text = String(repeating: "word ", count: 2000)
        let parts = TextChunker.split(text, limit: 4096)
        XCTAssertTrue(parts.allSatisfy { $0.count <= 4096 })
        XCTAssertEqual(parts.joined(separator: " ").split(separator: " ").count, 2000)
    }

    func testPersian() {
        XCTAssertEqual(PersianText.normalize("مي شود كتاب ، خوب"), "می‌شود کتاب، خوب")
        XCTAssertTrue(Exporter.isRightToLeft("سلام دنیا hello"))
        XCTAssertFalse(Exporter.isRightToLeft("hello world"))
    }

    func testVersions() {
        XCTAssertTrue(Versions.isNewer("v1.10.0", than: "1.9.9"))
        XCTAssertFalse(Versions.isNewer("1.0", than: "1.0.0"))
    }

    func testModels() {
        let m = WhisperModel(file: "ggml-large-v3-turbo-q5_0.bin", bytes: 1)
        XCTAssertEqual(m.name, "large-v3-turbo-q5_0")
        XCTAssertEqual(m.family, "large-v3-turbo")
        XCTAssertEqual(m.quantized, "q5_0")
        XCTAssertTrue(m.isRecommended)
        XCTAssertTrue(WhisperModel(file: "ggml-base.en.bin", bytes: 1).englishOnly)
    }
}
