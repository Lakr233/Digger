import CryptoKit
import Foundation

public enum DiggerCache: Sendable {
    public nonisolated(unsafe) static var cachesDirectory: String = digger {
        willSet {
            createDirectory(atPath: newValue.cacheDir)
        }
    }

    static func tempPath(url: URL) -> String {
        url.absoluteString.digestHash().tmpDir
    }

    static func cachePath(url: URL) -> String {
        cachesDirectory.cacheDir + "/" + url.lastPathComponent
    }

    static func removeTempFile(with url: URL) {
        let path = tempPath(url: url)
        if isFileExist(atPath: path) {
            removeItem(atPath: path)
        }
    }

    static func removeCacheFile(with url: URL) {
        let path = cachePath(url: url)
        if isFileExist(atPath: path) {
            removeItem(atPath: path)
        }
    }

    public static func downloadedFilesSize() -> Int64 {
        guard isFileExist(atPath: cachesDirectory.cacheDir) else { return 0 }
        do {
            let subpaths = try FileManager.default.subpathsOfDirectory(atPath: cachesDirectory.cacheDir)
            return subpaths.reduce(into: Int64(0)) { total, subpath in
                total += fileSize(filePath: cachesDirectory.cacheDir + "/" + subpath)
            }
        } catch {
            diggerLog(error)
            return 0
        }
    }

    public static func cleanDownloadTempFiles() {
        do {
            let subpaths = try FileManager.default.subpathsOfDirectory(atPath: "".tmpDir)
            for subpath in subpaths {
                removeItem(atPath: "".tmpDir + "/" + subpath)
            }
        } catch {
            diggerLog(error)
        }
    }

    public static func cleanDownloadFiles() {
        removeItem(atPath: cachesDirectory.cacheDir)
        createDirectory(atPath: cachesDirectory.cacheDir)
    }

    public static func pathsOfDownloadedfiles() -> [String] {
        do {
            let subpaths = try FileManager.default.subpathsOfDirectory(atPath: cachesDirectory.cacheDir)
            return subpaths.map { cachesDirectory.cacheDir + "/" + $0 }
        } catch {
            diggerLog(error)
            return []
        }
    }
}

// MARK: - File Helpers

public extension DiggerCache {
    static func isFileExist(atPath filePath: String) -> Bool {
        FileManager.default.fileExists(atPath: filePath)
    }

    static func fileSize(filePath: String) -> Int64 {
        guard isFileExist(atPath: filePath),
              let attrs = try? FileManager.default.attributesOfItem(atPath: filePath),
              let size = attrs[.size] as? Int64
        else { return 0 }
        return size
    }

    static func moveItem(atPath: String, toPath: String) {
        do {
            try FileManager.default.moveItem(atPath: atPath, toPath: toPath)
        } catch {
            diggerLog(error)
        }
    }

    static func removeItem(atPath: String) {
        guard isFileExist(atPath: atPath) else { return }
        do {
            try FileManager.default.removeItem(atPath: atPath)
        } catch {
            diggerLog(error)
        }
    }

    static func createDirectory(atPath: String) {
        guard !isFileExist(atPath: atPath) else { return }
        do {
            try FileManager.default.createDirectory(atPath: atPath, withIntermediateDirectories: true)
        } catch {
            diggerLog(error)
        }
    }

    static func systemFreeSize() -> Int64 {
        do {
            let attrs = try FileManager.default.attributesOfFileSystem(forPath: NSHomeDirectory())
            return attrs[.systemFreeSize] as? Int64 ?? 0
        } catch {
            diggerLog(error)
            return 0
        }
    }
}

// MARK: - Sandbox Paths

public extension String {
    var cacheDir: String {
        let path = NSSearchPathForDirectoriesInDomains(.cachesDirectory, .userDomainMask, true).last!
        return (path as NSString).appendingPathComponent((self as NSString).lastPathComponent)
    }

    var docDir: String {
        let path = NSSearchPathForDirectoriesInDomains(.documentDirectory, .userDomainMask, true).last!
        return (path as NSString).appendingPathComponent((self as NSString).lastPathComponent)
    }

    var tmpDir: String {
        let path = NSTemporaryDirectory() as NSString
        return path.appendingPathComponent((self as NSString).lastPathComponent)
    }

    func digestHash() -> String {
        let data = Data(utf8)
        let digest = SHA256.hash(data: data)
        return digest.map { String(format: "%02x", $0) }.joined()
    }
}
