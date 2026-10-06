import AppKit
import CryptoKit
import Foundation
import Security

final class Updater: ObservableObject {
    static let shared = Updater()

    struct Release {
        let version: String
        let page: URL
        let download: URL?
        let signature: URL?
        let notes: String
    }

    enum Phase: Equatable {
        case idle
        case checking
        case upToDate
        case available
        case downloading
        case failed(String)
    }

    @Published private(set) var phase: Phase = .idle
    @Published private(set) var latest: Release?
    @Published var autoCheck: Bool {
        didSet { UserDefaults.standard.set(autoCheck, forKey: "autoCheckUpdates") }
    }

    private let api = URL(string: "https://api.github.com/repos/amirhp-com/Hush/releases/latest")!
    private var timer: Timer?

    var currentVersion: String {
        Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "0"
    }

    var updateAvailable: Bool {
        guard let latest else { return false }
        return Self.isNewer(latest.version, than: currentVersion)
    }

    private init() {
        autoCheck = UserDefaults.standard.object(forKey: "autoCheckUpdates") as? Bool ?? true
    }

    func startAutomaticChecks() {
        guard autoCheck else { return }
        check()
        timer?.invalidate()
        timer = Timer.scheduledTimer(withTimeInterval: 6 * 3600, repeats: true) { [weak self] _ in
            guard let self, self.autoCheck else { return }
            self.check(quiet: true)
        }
    }

    func check(quiet: Bool = false) {
        if phase == .checking || phase == .downloading { return }
        if !quiet { phase = .checking }
        var request = URLRequest(url: api)
        request.setValue("application/vnd.github+json", forHTTPHeaderField: "Accept")
        request.setValue("Hush/\(currentVersion)", forHTTPHeaderField: "User-Agent")
        URLSession.shared.dataTask(with: request) { data, _, error in
            let release = data.flatMap(Self.parse)
            DispatchQueue.main.async {
                guard let release else {
                    if !quiet { self.phase = .failed(error?.localizedDescription ?? L("Couldn't reach GitHub")) }
                    return
                }
                self.latest = release
                let newer = Self.isNewer(release.version, than: self.currentVersion)
                self.phase = newer ? .available : .upToDate
                if newer, UserDefaults.standard.string(forKey: "notifiedVersion") != release.version {
                    UserDefaults.standard.set(release.version, forKey: "notifiedVersion")
                    Task { @MainActor in Notifier.post(title: "Hush", body: L("Hush %@ is available. Open Settings → About to update.", release.version)) }
                }
            }
        }.resume()
    }

    func install() {
        guard let latest, let download = latest.download, let signatureURL = latest.signature else {
            if let page = latest?.page { NSWorkspace.shared.open(page) }
            return
        }
        phase = .downloading
        Task {
            do {
                let (signatureData, _) = try await URLSession.shared.data(from: signatureURL)
                let (location, _) = try await URLSession.shared.download(from: download)
                let archive = try Data(contentsOf: location)
                guard Self.verify(archive, signature: signatureData) else {
                    try? FileManager.default.removeItem(at: location)
                    throw UpdateError.message(L("The update isn't signed by Hush's release key."))
                }
                let app = try self.unpack(location)
                await MainActor.run { self.replaceAndRelaunch(with: app) }
            } catch {
                await MainActor.run { self.phase = .failed(error.localizedDescription) }
            }
        }
    }

    static func verify(_ data: Data, signature: Data) -> Bool {
        guard let keyText = Bundle.main.object(forInfoDictionaryKey: "HushPublicEDKey") as? String,
              let keyData = Data(base64Encoded: keyText),
              let key = try? Curve25519.Signing.PublicKey(rawRepresentation: keyData),
              let text = String(data: signature, encoding: .utf8),
              let raw = Data(base64Encoded: text.trimmingCharacters(in: .whitespacesAndNewlines)) else { return false }
        return key.isValidSignature(raw, for: data)
    }

    private func unpack(_ zip: URL) throws -> URL {
        let fm = FileManager.default
        let work = fm.temporaryDirectory.appendingPathComponent("Hush-update-\(UUID().uuidString)", isDirectory: true)
        try fm.createDirectory(at: work, withIntermediateDirectories: true)
        let archive = work.appendingPathComponent("Hush.zip")
        try fm.moveItem(at: zip, to: archive)
        guard Self.runTool("/usr/bin/ditto", ["-x", "-k", archive.path, work.path]) == 0 else {
            throw UpdateError.message(L("Couldn't unzip the update."))
        }
        let app = work.appendingPathComponent("Hush.app")
        guard Bundle(url: app)?.bundleIdentifier == Bundle.main.bundleIdentifier else {
            throw UpdateError.message(L("The download doesn't look like Hush."))
        }
        guard Self.hasValidSignature(app) else {
            throw UpdateError.message("The update's code signature couldn't be verified")
        }
        return app
    }

    private func replaceAndRelaunch(with app: URL) {
        let current = Bundle.main.bundleURL
        guard FileManager.default.isWritableFile(atPath: current.deletingLastPathComponent().path) else {
            NSWorkspace.shared.activateFileViewerSelecting([app])
            phase = .failed(L("Couldn't write to %@. Drag the new app there yourself.", current.deletingLastPathComponent().path))
            return
        }
        let pid = ProcessInfo.processInfo.processIdentifier
        let script = """
        while kill -0 \(pid) 2>/dev/null; do sleep 0.2; done
        rm -rf \(Self.quoted(current.path))
        mv \(Self.quoted(app.path)) \(Self.quoted(current.path))
        open \(Self.quoted(current.path))
        """
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/bin/sh")
        process.arguments = ["-c", script]
        do {
            try process.run()
            NSApp.terminate(nil)
        } catch {
            phase = .failed(error.localizedDescription)
        }
    }

    private static func hasValidSignature(_ app: URL) -> Bool {
        var code: SecStaticCode?
        guard SecStaticCodeCreateWithPath(app as CFURL, [], &code) == errSecSuccess, let code else { return false }
        var requirement: SecRequirement?
        let text = "identifier \"\(Bundle.main.bundleIdentifier ?? "com.amirhp.Hush")\"" as CFString
        guard SecRequirementCreateWithString(text, [], &requirement) == errSecSuccess else { return false }
        let flags = SecCSFlags(rawValue: kSecCSCheckAllArchitectures | kSecCSStrictValidate | kSecCSCheckNestedCode)
        return SecStaticCodeCheckValidityWithErrors(code, flags, requirement, nil) == errSecSuccess
    }

    private static func parse(_ data: Data) -> Release? {
        guard let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let tag = json["tag_name"] as? String,
              let page = (json["html_url"] as? String).flatMap(URL.init(string:)) else { return nil }
        let assets = json["assets"] as? [[String: Any]] ?? []
        let zip = assets.first { ($0["name"] as? String)?.hasSuffix(".zip") == true }
        let download = (zip?["browser_download_url"] as? String).flatMap(URL.init(string:))
        let sig = assets.first { ($0["name"] as? String)?.hasSuffix(".zip.sig") == true }
        let signature = (sig?["browser_download_url"] as? String).flatMap(URL.init(string:))
        let version = tag.hasPrefix("v") ? String(tag.dropFirst()) : tag
        return Release(version: version, page: page, download: download, signature: signature, notes: json["body"] as? String ?? "")
    }

    static func quoted(_ s: String) -> String { "'" + s.replacingOccurrences(of: "'", with: "'\\''") + "'" }

    @discardableResult
    static func runTool(_ path: String, _ args: [String]) -> Int32 {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: path)
        p.arguments = args
        do { try p.run(); p.waitUntilExit(); return p.terminationStatus } catch { return -1 }
    }

    static func isNewer(_ candidate: String, than current: String) -> Bool {
        let a = candidate.split(separator: ".").map { Int($0) ?? 0 }
        let b = current.split(separator: ".").map { Int($0) ?? 0 }
        for i in 0..<max(a.count, b.count) {
            let x = i < a.count ? a[i] : 0
            let y = i < b.count ? b[i] : 0
            if x != y { return x > y }
        }
        return false
    }

    enum UpdateError: LocalizedError {
        case message(String)
        var errorDescription: String? {
            if case .message(let text) = self { return text }
            return nil
        }
    }
}
