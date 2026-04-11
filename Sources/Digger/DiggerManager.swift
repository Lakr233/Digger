import Foundation

// MARK: - Logging Hook

public enum DiggerLogging {
    public nonisolated(unsafe) static var handler: (@Sendable (_ message: String, _ file: String, _ function: String, _ line: Int) -> Void)?
}

// MARK: - Protocol

public protocol DiggerManagerProtocol {
    var logLevel: LogLevel { get set }
    var maxConcurrentTasksCount: Int { get set }
    var allowsCellularAccess: Bool { get set }
    var additionalHTTPHeaders: [String: String] { get set }
    var timeout: TimeInterval { get set }
    var startDownloadImmediately: Bool { get set }

    func startTask(for diggerURL: DiggerURL)
    func stopTask(for diggerURL: DiggerURL)
    func cancelTask(for diggerURL: DiggerURL)
    func startAllTasks()
    func stopAllTasks()
    func cancelAllTasks()
}

// MARK: - Manager

open class DiggerManager: DiggerManagerProtocol, @unchecked Sendable {

    // MARK: - Singleton

    nonisolated(unsafe) public static var shared = DiggerManager(name: digger)

    // MARK: - Properties

    public var logLevel: LogLevel = .high
    open var startDownloadImmediately = true
    open var timeout: TimeInterval = 100

    fileprivate var diggerSeeds = [URL: DiggerSeed]()
    fileprivate var session: URLSession
    fileprivate var diggerDelegate: DiggerDelegate?
    fileprivate let barrierQueue = DispatchQueue.barrier
    fileprivate let delegateQueue = OperationQueue.makeDiggerDelegateQueue()
    private let accessLock = NSLock()

    public var maxConcurrentTasksCount: Int = 3 {
        didSet {
            let count = maxConcurrentTasksCount == 0 ? 1 : maxConcurrentTasksCount
            session.invalidateAndCancel()
            session = setupSession(allowsCellularAccess, count, additionalHTTPHeaders)
        }
    }

    public var allowsCellularAccess: Bool = true {
        didSet {
            session.invalidateAndCancel()
            session = setupSession(allowsCellularAccess, maxConcurrentTasksCount, additionalHTTPHeaders)
        }
    }

    public var additionalHTTPHeaders: [String: String] = [:] {
        didSet {
            session.invalidateAndCancel()
            session = setupSession(allowsCellularAccess, maxConcurrentTasksCount, additionalHTTPHeaders)
        }
    }

    // MARK: - Lifecycle

    private init(name: String) {
        DiggerCache.cachesDirectory = digger
        precondition(!name.isEmpty, "DiggerManager must have a name")

        diggerDelegate = DiggerDelegate()
        session = URLSession(
            configuration: Self.makeConfiguration(
                allowsCellularAccess: true,
                maxConnections: 3,
                headers: [:]
            ),
            delegate: diggerDelegate,
            delegateQueue: delegateQueue
        )
    }

    deinit {
        session.invalidateAndCancel()
    }

    // MARK: - Session Factory

    private func setupSession(
        _ allowsCellularAccess: Bool,
        _ maxDownloadTasksCount: Int,
        _ additionalHTTPHeaders: [String: String]
    ) -> URLSession {
        diggerDelegate = DiggerDelegate()
        return URLSession(
            configuration: Self.makeConfiguration(
                allowsCellularAccess: allowsCellularAccess,
                maxConnections: maxDownloadTasksCount,
                headers: additionalHTTPHeaders
            ),
            delegate: diggerDelegate,
            delegateQueue: delegateQueue
        )
    }

    static func makeConfiguration(
        allowsCellularAccess: Bool,
        maxConnections: Int,
        headers: [String: String]
    ) -> URLSessionConfiguration {
        let config = URLSessionConfiguration.default
        config.allowsCellularAccess = allowsCellularAccess
        config.httpMaximumConnectionsPerHost = maxConnections
        config.httpAdditionalHeaders = headers
        return config
    }

    // MARK: - Download

    @discardableResult
    public func download(with diggerURL: DiggerURL) -> DiggerSeed {
        switch isDiggerURLCorrect(diggerURL) {
        case .success(let url):
            createDiggerSeed(with: url)
        case .failure:
            fatalError("Please make sure the url or urlString is correct")
        }
    }
}

// MARK: - Seed Control

extension DiggerManager {
    func createDiggerSeed(with url: URL) -> DiggerSeed {
        if let seed = findDiggerSeed(with: url) {
            return seed
        }

        barrierQueue.sync(flags: .barrier) {
            let timeout = self.timeout == 0.0 ? 100 : self.timeout
            let diggerSeed = DiggerSeed(session: session, url: url, timeout: timeout)
            diggerSeeds[url] = diggerSeed
        }

        let diggerSeed = findDiggerSeed(with: url)!
        diggerDelegate?.manager = self
        if startDownloadImmediately {
            diggerSeed.downloadTask.resume()
        }
        return diggerSeed
    }

    public func removeDigeerSeed(for url: URL) {
        barrierQueue.sync(flags: .barrier) {
            diggerSeeds.removeValue(forKey: url)
            if diggerSeeds.isEmpty { diggerDelegate = nil }
        }
    }

    func isDiggerURLCorrect(_ diggerURL: DiggerURL) -> Swift.Result<URL, any Error> {
        do {
            let url = try diggerURL.asURL()
            return .success(url)
        } catch {
            diggerLog(error)
            return .failure(error)
        }
    }

    func findDiggerSeed(with diggerURL: DiggerURL) -> DiggerSeed? {
        switch isDiggerURLCorrect(diggerURL) {
        case .success(let url):
            var seed: DiggerSeed?
            barrierQueue.sync { seed = diggerSeeds[url] }
            return seed
        case .failure:
            return nil
        }
    }
}

// MARK: - Task Control

public extension DiggerManager {
    func cancelTask(for diggerURL: DiggerURL) {
        guard case .success(let url) = isDiggerURLCorrect(diggerURL) else { return }
        barrierQueue.sync(flags: .barrier) {
            guard let diggerSeed = diggerSeeds[url] else { return }
            diggerSeed.downloadTask.cancel()
        }
    }

    func stopTask(for diggerURL: DiggerURL) {
        guard case .success(let url) = isDiggerURLCorrect(diggerURL) else { return }
        barrierQueue.sync(flags: .barrier) {
            guard let diggerSeed = diggerSeeds[url] else { return }
            if diggerSeed.downloadTask.state == .running {
                diggerSeed.downloadTask.suspend()
                diggerDelegate?.notifySpeedZeroCallback(diggerSeed)
            }
        }
    }

    func startTask(for diggerURL: DiggerURL) {
        guard case .success(let url) = isDiggerURLCorrect(diggerURL) else { return }
        barrierQueue.sync(flags: .barrier) {
            guard let diggerSeed = diggerSeeds[url] else { return }
            if diggerSeed.downloadTask.state != .running {
                diggerSeed.downloadTask.resume()
                self.diggerDelegate?.notifySpeedCallback(diggerSeed)
            }
        }
    }

    func startAllTasks() {
        accessLock.withLock { Array(diggerSeeds.keys) }
            .forEach { startTask(for: $0) }
    }

    func stopAllTasks() {
        accessLock.withLock { Array(diggerSeeds.keys) }
            .forEach { stopTask(for: $0) }
    }

    func cancelAllTasks() {
        accessLock.withLock { Array(diggerSeeds.keys) }
            .forEach { cancelTask(for: $0) }
    }

    func obtainAllTasks() -> [URL] {
        accessLock.withLock { Array(diggerSeeds.keys) }
    }
}

// MARK: - URLSession Resume Support

public extension URLSession {
    func dataTask(with url: URL, timeout: TimeInterval) -> URLSessionDataTask {
        var request = URLRequest(url: url, cachePolicy: .reloadIgnoringLocalCacheData, timeoutInterval: timeout)
        // Disable HTTP/3 (QUIC) to avoid VPN compatibility issues.
        // QUIC packets may exceed the reduced MTU inside VPN tunnels (e.g. MSS 1236),
        // causing connection aborts (-1005) on large file downloads. Forcing HTTP/2
        // over TCP avoids this entirely.
        request.assumesHTTP3Capable = false
        let range = DiggerCache.fileSize(filePath: DiggerCache.tempPath(url: url))
        if range > 0 {
            let headRange = "bytes=\(range)-"
            request.setValue(headRange, forHTTPHeaderField: "Range")
        }
        let task = dataTask(with: request)
        task.priority = URLSessionTask.defaultPriority
        return task
    }
}
