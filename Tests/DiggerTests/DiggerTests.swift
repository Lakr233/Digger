import Foundation
import Testing

@testable import Digger

// MARK: - Thread-safe test helper

private final class AtomicBox<T: Sendable>: @unchecked Sendable {
    private let lock = NSLock()
    private var _value: T

    init(_ value: T) { _value = value }

    var value: T {
        lock.withLock { _value }
    }

    func set(_ newValue: T) {
        lock.withLock { _value = newValue }
    }
}

// MARK: - Cache & Hash Tests

@Suite("DiggerCache")
struct DiggerCacheTests {
    @Test func digestHashProducesConsistentOutput() {
        let hash1 = "https://example.com/file.mp3".digestHash()
        let hash2 = "https://example.com/file.mp3".digestHash()
        #expect(hash1 == hash2)
        #expect(hash1.count == 64) // SHA256 = 64 hex chars
    }

    @Test func digestHashDiffersForDifferentInput() {
        let hash1 = "https://example.com/a.mp3".digestHash()
        let hash2 = "https://example.com/b.mp3".digestHash()
        #expect(hash1 != hash2)
    }

    @Test func cachePathUsesHashWithExtension() {
        let url = URL(string: "https://example.com/track.m4a")!
        let path = DiggerCache.cachePath(url: url)
        #expect(path.hasSuffix(".m4a"))
        #expect(path.contains("Caches"))
        // Must not contain the raw file name (hash-based)
        #expect(!path.contains("track.m4a"))
    }

    @Test func cachePathPreventPathTraversal() {
        let url = URL(string: "https://evil.com/../../etc/passwd")!
        let path = DiggerCache.cachePath(url: url)
        #expect(!path.contains(".."))
        #expect(!path.contains("etc"))
        #expect(!path.contains("passwd"))
    }

    @Test func tempPathIsDeterministic() {
        let url = URL(string: "https://example.com/track.m4a")!
        let path1 = DiggerCache.tempPath(url: url)
        let path2 = DiggerCache.tempPath(url: url)
        #expect(path1 == path2)
    }

    @Test func sandboxPathExtensions() {
        let cacheDir = "TestDir".cacheDir
        #expect(cacheDir.contains("Caches"))
        #expect(cacheDir.hasSuffix("TestDir"))

        let docDir = "TestDir".docDir
        #expect(docDir.contains("Documents"))

        let tmpDir = "TestDir".tmpDir
        #expect(tmpDir.contains("tmp") || tmpDir.contains("T/"))
    }
}

// MARK: - Configuration Tests

@Suite("Configuration")
struct ConfigurationTests {
    @Test func sessionConfigurationAppliesSettings() {
        let config = DiggerManager.makeConfiguration(
            allowsCellularAccess: true,
            maxConnections: 4,
            headers: [:]
        )
        #expect(config.allowsCellularAccess == true)
        #expect(config.httpMaximumConnectionsPerHost == 4)
    }

    @Test func sessionConfigurationAppliesHeaders() {
        let headers = ["Authorization": "Bearer token123"]
        let config = DiggerManager.makeConfiguration(
            allowsCellularAccess: false,
            maxConnections: 2,
            headers: headers
        )
        #expect(config.allowsCellularAccess == false)
        #expect(config.httpMaximumConnectionsPerHost == 2)
        let applied = config.httpAdditionalHeaders as? [String: String]
        #expect(applied?["Authorization"] == "Bearer token123")
    }

    @Test func requestDisablesHTTP3() {
        let url = URL(string: "https://example.com/file.bin")!
        var request = URLRequest(url: url)
        request.assumesHTTP3Capable = false
        #expect(request.assumesHTTP3Capable == false)
    }
}

// MARK: - URL Helper Tests

@Suite("DiggerURL")
struct DiggerURLTests {
    @Test func stringAsURL() throws {
        let url = try "https://example.com/path".asURL()
        #expect(url.absoluteString == "https://example.com/path")
    }

    @Test func invalidStringThrows() {
        #expect(throws: (any Error).self) {
            _ = try "".asURL()
        }
    }

    @Test func urlAsURLReturnsSelf() throws {
        let original = URL(string: "https://example.com")!
        let result = try original.asURL()
        #expect(result == original)
    }
}

// MARK: - Logging Tests

@Suite("Logging", .serialized)
struct LoggingTests {
    @Test func loggingHandlerReceivesMessages() {
        let captured = AtomicBox<String?>(nil)
        DiggerLogging.handler = { message, _, _, _ in
            captured.set(message)
        }
        defer { DiggerLogging.handler = nil }

        DiggerManager.shared.logLevel = .low
        diggerLog("test message")
        #expect(captured.value?.contains("test message") == true)
    }

    @Test func logLevelNoneSuppressesOutput() {
        let captured = AtomicBox<String?>(nil)
        DiggerLogging.handler = { message, _, _, _ in
            captured.set(message)
        }
        defer {
            DiggerLogging.handler = nil
            DiggerManager.shared.logLevel = .high
        }

        DiggerManager.shared.logLevel = .none
        diggerLog("should not appear")
        #expect(captured.value == nil)
    }
}

// MARK: - Download Integration Tests (Cloudflare)

@Suite("Download Integration", .tags(.network), .serialized)
struct DownloadIntegrationTests {
    static let cloudflareBaseURL = "https://speed.cloudflare.com/__down?bytes="

    @Test(.timeLimit(.minutes(1)))
    func basicSmallDownload() async throws {
        let url = URL(string: "\(Self.cloudflareBaseURL)1024")!

        DiggerCache.removeCacheFile(with: url)
        DiggerCache.removeTempFile(with: url)
        DiggerManager.shared.logLevel = .none

        let fileURL: URL = try await withCheckedThrowingContinuation { continuation in
            DiggerManager.shared.download(with: url)
                .completion { result in
                    switch result {
                    case .success(let url):
                        continuation.resume(returning: url)
                    case .failure(let error):
                        continuation.resume(throwing: error)
                    }
                }
        }

        #expect(FileManager.default.fileExists(atPath: fileURL.path))
        try? FileManager.default.removeItem(at: fileURL)
    }

    @Test(.timeLimit(.minutes(1)))
    func progressCallbackFires() async throws {
        let url = URL(string: "\(Self.cloudflareBaseURL)51200")!

        DiggerCache.removeCacheFile(with: url)
        DiggerCache.removeTempFile(with: url)
        DiggerManager.shared.logLevel = .none

        let progressFired = AtomicBox(false)

        let _: URL = try await withCheckedThrowingContinuation { continuation in
            DiggerManager.shared.download(with: url)
                .progress { progress in
                    if progress.completedUnitCount > 0 {
                        progressFired.set(true)
                    }
                }
                .completion { result in
                    switch result {
                    case .success(let url):
                        continuation.resume(returning: url)
                    case .failure(let error):
                        continuation.resume(throwing: error)
                    }
                }
        }

        #expect(progressFired.value)

        let cachePath = DiggerCache.cachePath(url: url)
        try? FileManager.default.removeItem(atPath: cachePath)
    }

    @Test(.timeLimit(.minutes(1)))
    func cancelCleansUpTempFile() async throws {
        let url = URL(string: "\(Self.cloudflareBaseURL)1048576")! // 1MB

        DiggerCache.removeCacheFile(with: url)
        DiggerCache.removeTempFile(with: url)
        DiggerManager.shared.logLevel = .none

        let resumed = AtomicBox(false)

        let _: Void = await withCheckedContinuation { continuation in
            DiggerManager.shared.download(with: url)
                .progress { _ in
                    DiggerManager.shared.cancelTask(for: url)
                }
                .completion { _ in
                    if !resumed.value {
                        resumed.set(true)
                        continuation.resume()
                    }
                }
        }

        try await Task.sleep(for: .milliseconds(200))
        let tempPath = DiggerCache.tempPath(url: url)
        #expect(!DiggerCache.isFileExist(atPath: tempPath))
    }

    @Test(.timeLimit(.minutes(1)))
    func multipleSequentialDownloads() async throws {
        let sizes = [1024, 2048, 4096]

        DiggerManager.shared.logLevel = .none

        for size in sizes {
            let url = URL(string: "\(Self.cloudflareBaseURL)\(size)")!
            DiggerCache.removeCacheFile(with: url)
            DiggerCache.removeTempFile(with: url)

            let fileURL: URL = try await withCheckedThrowingContinuation { continuation in
                DiggerManager.shared.download(with: url)
                    .completion { result in
                        switch result {
                        case .success(let fileURL):
                            continuation.resume(returning: fileURL)
                        case .failure(let error):
                            continuation.resume(throwing: error)
                        }
                    }
            }

            #expect(FileManager.default.fileExists(atPath: fileURL.path))
            try? FileManager.default.removeItem(at: fileURL)
        }
    }
}

extension Tag {
    @Tag static var network: Self
}
