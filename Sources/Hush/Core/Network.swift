import Foundation

/// One URLSession setup for everything that goes online (models, voices, Telegram, updates),
/// so the proxy setting applies everywhere.
final class Network: @unchecked Sendable {
    static let shared = Network()
    private(set) var session: URLSession = .shared
    private(set) var longSession: URLSession = .shared

    private init() { rebuild() }

    func configuration(requestTimeout: TimeInterval, resourceTimeout: TimeInterval) -> URLSessionConfiguration {
        let config = URLSessionConfiguration.default
        config.timeoutIntervalForRequest = requestTimeout
        config.timeoutIntervalForResource = resourceTimeout
        config.waitsForConnectivity = false
        let s = AppSettings.shared
        switch s.proxyKind {
        case .none: break
        case .http:
            config.connectionProxyDictionary = [
                kCFNetworkProxiesHTTPEnable as String: 1, kCFNetworkProxiesHTTPProxy as String: s.proxyHost, kCFNetworkProxiesHTTPPort as String: s.proxyPort,
                kCFNetworkProxiesHTTPSEnable as String: 1, kCFNetworkProxiesHTTPSProxy as String: s.proxyHost, kCFNetworkProxiesHTTPSPort as String: s.proxyPort
            ]
        case .socks:
            config.connectionProxyDictionary = [
                kCFNetworkProxiesSOCKSEnable as String: 1, kCFNetworkProxiesSOCKSProxy as String: s.proxyHost, kCFNetworkProxiesSOCKSPort as String: s.proxyPort
            ]
        }
        return config
    }

    func rebuild() {
        session = URLSession(configuration: configuration(requestTimeout: 60, resourceTimeout: 3600))
        longSession = URLSession(configuration: configuration(requestTimeout: 70, resourceTimeout: 600))
        NotificationCenter.default.post(name: .networkChanged, object: nil)
    }
}

extension Notification.Name {
    static let networkChanged = Notification.Name("HushNetworkChanged")
}

/// Downloads a file with progress, cancel and resume.
final class FileDownload: NSObject, URLSessionDownloadDelegate, @unchecked Sendable {
    let url: URL
    let destination: URL
    var onProgress: ((Double, Int64, Int64) -> Void)?
    var onFinish: ((Error?) -> Void)?
    private var session: URLSession?
    private var task: URLSessionDownloadTask?
    private static var resumeData: [URL: Data] = [:]

    init(url: URL, destination: URL) {
        self.url = url
        self.destination = destination
    }

    func start() {
        let config = Network.shared.configuration(requestTimeout: 60, resourceTimeout: 24 * 3600)
        session = URLSession(configuration: config, delegate: self, delegateQueue: nil)
        if let data = Self.resumeData.removeValue(forKey: url) {
            task = session?.downloadTask(withResumeData: data)
        } else {
            task = session?.downloadTask(with: url)
        }
        task?.resume()
    }

    func cancel() {
        task?.cancel { data in
            if let data { FileDownload.resumeData[self.url] = data }
        }
    }

    func urlSession(_ session: URLSession, downloadTask: URLSessionDownloadTask, didWriteData _: Int64, totalBytesWritten: Int64, totalBytesExpectedToWrite: Int64) {
        let fraction = totalBytesExpectedToWrite > 0 ? Double(totalBytesWritten) / Double(totalBytesExpectedToWrite) : 0
        onProgress?(fraction, totalBytesWritten, totalBytesExpectedToWrite)
    }

    func urlSession(_ session: URLSession, downloadTask: URLSessionDownloadTask, didFinishDownloadingTo location: URL) {
        let status = (downloadTask.response as? HTTPURLResponse)?.statusCode ?? 200
        guard status < 400 else {
            onFinish?(MediaError.failed(L("The server answered with error %d.", status)))
            return
        }
        do {
            try FileManager.default.createDirectory(at: destination.deletingLastPathComponent(), withIntermediateDirectories: true)
            try? FileManager.default.removeItem(at: destination)
            try FileManager.default.moveItem(at: location, to: destination)
            onFinish?(nil)
        } catch {
            onFinish?(error)
        }
        session.finishTasksAndInvalidate()
    }

    func urlSession(_ session: URLSession, task: URLSessionTask, didCompleteWithError error: Error?) {
        guard let error else { return }
        if let data = (error as NSError).userInfo[NSURLSessionDownloadTaskResumeData] as? Data { Self.resumeData[url] = data }
        onFinish?(error)
        session.finishTasksAndInvalidate()
    }
}
