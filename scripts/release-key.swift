import CryptoKit
import Foundation

let keyPath = ProcessInfo.processInfo.environment["HUSH_KEY"]
    ?? FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".config/hush/ed25519.key").path

func fail(_ message: String) -> Never {
    FileHandle.standardError.write(Data((message + "\n").utf8))
    exit(1)
}

func loadKey() -> Curve25519.Signing.PrivateKey {
    guard let text = try? String(contentsOfFile: keyPath, encoding: .utf8),
          let raw = Data(base64Encoded: text.trimmingCharacters(in: .whitespacesAndNewlines)),
          let key = try? Curve25519.Signing.PrivateKey(rawRepresentation: raw) else {
        fail("No signing key at \(keyPath). Run: swift scripts/release-key.swift generate")
    }
    return key
}

let args = CommandLine.arguments.dropFirst()
switch args.first {
case "generate":
    if FileManager.default.fileExists(atPath: keyPath) { fail("A key already exists at \(keyPath)") }
    let key = Curve25519.Signing.PrivateKey()
    let folder = (keyPath as NSString).deletingLastPathComponent
    try FileManager.default.createDirectory(atPath: folder, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
    FileManager.default.createFile(atPath: keyPath, contents: Data(key.rawRepresentation.base64EncodedString().utf8), attributes: [.posixPermissions: 0o600])
    print(key.publicKey.rawRepresentation.base64EncodedString())
case "public":
    print(loadKey().publicKey.rawRepresentation.base64EncodedString())
case "sign":
    guard let file = args.dropFirst().first, let data = FileManager.default.contents(atPath: file) else { fail("usage: release-key.swift sign <file>") }
    let signature = try loadKey().signature(for: data)
    try Data(signature.base64EncodedString().utf8).write(to: URL(fileURLWithPath: file + ".sig"))
    print("Signed \(file)")
default:
    fail("usage: release-key.swift generate | public | sign <file>")
}
