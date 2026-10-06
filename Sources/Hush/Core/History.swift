import AppKit
import Foundation
import HushCore

struct TranscriptRecord: Codable, Identifiable, Equatable {
    var id: UUID
    var title: String
    var sourcePath: String
    var created: Date
    var language: String
    var model: String
    var duration: Double
    var segments: [Segment]
    var outputs: [String]

    var text: String { segments.map(\.text).joined(separator: "\n") }
    var sourceURL: URL { URL(fileURLWithPath: sourcePath) }
}

@MainActor
final class History: ObservableObject {
    static let shared = History()
    @Published private(set) var records: [TranscriptRecord] = []

    private var folder: URL { Paths.folder("History") }

    private init() { load() }

    func load() {
        let files = (try? FileManager.default.contentsOfDirectory(at: folder, includingPropertiesForKeys: nil)) ?? []
        let decoder = JSONDecoder()
        records = files.filter { $0.pathExtension == "json" }
            .compactMap { try? decoder.decode(TranscriptRecord.self, from: Data(contentsOf: $0)) }
            .sorted { $0.created > $1.created }
    }

    func save(_ record: TranscriptRecord) {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted]
        if let data = try? encoder.encode(record) {
            try? data.write(to: folder.appendingPathComponent(record.id.uuidString + ".json"), options: .atomic)
        }
        if let i = records.firstIndex(where: { $0.id == record.id }) { records[i] = record } else { records.insert(record, at: 0) }
    }

    func delete(_ record: TranscriptRecord) {
        try? FileManager.default.removeItem(at: folder.appendingPathComponent(record.id.uuidString + ".json"))
        records.removeAll { $0.id == record.id }
    }

    func record(_ id: UUID?) -> TranscriptRecord? { records.first { $0.id == id } }
}

/// Writes a transcript in the chosen formats.
enum OutputWriter {
    static func folder(for source: URL, preferred: String) -> URL {
        if !preferred.isEmpty { return URL(fileURLWithPath: (preferred as NSString).expandingTildeInPath, isDirectory: true) }
        let parent = source.deletingLastPathComponent()
        if FileManager.default.isWritableFile(atPath: parent.path), !parent.path.hasPrefix(Paths.support.path), !parent.path.hasPrefix(Paths.temp.path) {
            return parent
        }
        return Paths.folder("Transcripts")
    }

    @MainActor
    static func write(_ record: TranscriptRecord, formats: [ExportFormat], to folder: URL) throws -> [URL] {
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        var urls: [URL] = []
        for format in formats {
            let url = folder.appendingPathComponent(record.title + format.fileSuffix).appendingPathExtension(format.fileExtension)
            try write(record, format: format, to: url)
            urls.append(url)
        }
        return urls
    }

    @MainActor
    static func write(_ record: TranscriptRecord, format: ExportFormat, to url: URL) throws {
        switch format {
        case .docx: try DocxWriter.write(record, to: url)
        case .pdf: try PDFWriter.write(record, to: url)
        default:
            let text = Exporter.render(format, segments: record.segments, title: record.title, language: record.language)
            try text.write(to: url, atomically: true, encoding: .utf8)
        }
    }
}

enum DocxWriter {
    static func write(_ record: TranscriptRecord, to url: URL) throws {
        let rtl = Exporter.isRightToLeft(record.text)
        func esc(_ s: String) -> String {
            s.replacingOccurrences(of: "&", with: "&amp;").replacingOccurrences(of: "<", with: "&lt;").replacingOccurrences(of: ">", with: "&gt;")
        }
        func para(_ text: String, bold: Bool = false, size: Int = 24, color: String? = nil) -> String {
            let pPr = rtl ? "<w:pPr><w:bidi/><w:jc w:val=\"start\"/></w:pPr>" : ""
            var rPr = "<w:rFonts w:ascii=\"Helvetica\" w:hAnsi=\"Helvetica\" w:cs=\"Geeza Pro\"/>"
            if bold { rPr += "<w:b/><w:bCs/>" }
            if let color { rPr += "<w:color w:val=\"\(color)\"/>" }
            rPr += "<w:sz w:val=\"\(size)\"/><w:szCs w:val=\"\(size)\"/>"
            if rtl { rPr += "<w:rtl/>" }
            return "<w:p>\(pPr)<w:r><w:rPr>\(rPr)</w:rPr><w:t xml:space=\"preserve\">\(esc(text))</w:t></w:r></w:p>"
        }
        var body = para(record.title, bold: true, size: 32)
        for s in record.segments {
            body += para(TimeFormat.short(s.start), size: 18, color: "888888")
            body += para(s.text)
        }
        let sect = rtl ? "<w:sectPr><w:bidi/></w:sectPr>" : "<w:sectPr/>"
        let document = """
        <?xml version="1.0" encoding="UTF-8" standalone="yes"?>
        <w:document xmlns:w="http://schemas.openxmlformats.org/wordprocessingml/2006/main"><w:body>\(body)\(sect)</w:body></w:document>
        """
        let files: [String: String] = [
            "[Content_Types].xml": """
            <?xml version="1.0" encoding="UTF-8" standalone="yes"?>
            <Types xmlns="http://schemas.openxmlformats.org/package/2006/content-types"><Default Extension="rels" ContentType="application/vnd.openxmlformats-package.relationships+xml"/><Default Extension="xml" ContentType="application/xml"/><Override PartName="/word/document.xml" ContentType="application/vnd.openxmlformats-officedocument.wordprocessingml.document.main+xml"/></Types>
            """,
            "_rels/.rels": """
            <?xml version="1.0" encoding="UTF-8" standalone="yes"?>
            <Relationships xmlns="http://schemas.openxmlformats.org/package/2006/relationships"><Relationship Id="rId1" Type="http://schemas.openxmlformats.org/officeDocument/2006/relationships/officeDocument" Target="word/document.xml"/></Relationships>
            """,
            "word/document.xml": document
        ]
        let work = Paths.temp.appendingPathComponent("docx-" + UUID().uuidString, isDirectory: true)
        defer { try? FileManager.default.removeItem(at: work) }
        for (path, content) in files {
            let f = work.appendingPathComponent(path)
            try FileManager.default.createDirectory(at: f.deletingLastPathComponent(), withIntermediateDirectories: true)
            try content.write(to: f, atomically: true, encoding: .utf8)
        }
        try? FileManager.default.removeItem(at: url)
        let zip = Process()
        zip.executableURL = URL(fileURLWithPath: "/usr/bin/zip")
        zip.currentDirectoryURL = work
        zip.arguments = ["-q", "-X", "-r", url.path, "[Content_Types].xml", "_rels", "word"]
        try zip.run()
        zip.waitUntilExit()
        guard zip.terminationStatus == 0 else { throw MediaError.failed(L("Couldn't create the Word file.")) }
    }
}

enum PDFWriter {
    @MainActor
    static func write(_ record: TranscriptRecord, to url: URL) throws {
        let rtl = Exporter.isRightToLeft(record.text)
        let style = NSMutableParagraphStyle()
        style.alignment = rtl ? .right : .left
        style.baseWritingDirection = rtl ? .rightToLeft : .leftToRight
        style.paragraphSpacing = 6
        style.lineHeightMultiple = 1.25
        let text = NSMutableAttributedString(string: record.title + "\n\n", attributes: [.font: NSFont.boldSystemFont(ofSize: 18), .paragraphStyle: style])
        for s in record.segments {
            text.append(NSAttributedString(string: TimeFormat.short(s.start) + "\n", attributes: [.font: NSFont.monospacedDigitSystemFont(ofSize: 9, weight: .regular), .foregroundColor: NSColor.gray, .paragraphStyle: style]))
            text.append(NSAttributedString(string: s.text + "\n", attributes: [.font: NSFont.systemFont(ofSize: 12), .paragraphStyle: style]))
        }
        let info = NSPrintInfo()
        info.paperSize = NSSize(width: 595, height: 842)
        info.topMargin = 50; info.bottomMargin = 50; info.leftMargin = 50; info.rightMargin = 50
        info.horizontalPagination = .fit
        info.verticalPagination = .automatic
        info.jobDisposition = .save
        info.dictionary()[NSPrintInfo.AttributeKey.jobSavingURL] = url
        let view = NSTextView(frame: NSRect(x: 0, y: 0, width: 495, height: 742))
        view.textStorage?.setAttributedString(text)
        view.sizeToFit()
        let op = NSPrintOperation(view: view, printInfo: info)
        op.showsPrintPanel = false
        op.showsProgressPanel = false
        guard op.run() else { throw MediaError.failed(L("Couldn't create the PDF.")) }
    }
}
