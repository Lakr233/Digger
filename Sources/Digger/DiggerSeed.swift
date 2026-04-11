import Foundation

public typealias ProgressCallback = @Sendable (_ progress: Progress) -> Void
public typealias SpeedCallback = @Sendable (_ speedBytes: Int64) -> Void
public typealias CompletionCallback = @Sendable (_ completion: DiggerResult) -> Void

public typealias Callback = (progress: ProgressCallback?, speed: SpeedCallback?, completion: CompletionCallback?)

public class DiggerSeed: @unchecked Sendable {
    var downloadTask: URLSessionDataTask
    var url: URL
    var progress = Progress()
    var callbacks = [Callback]()
    var cancelSemaphore: DispatchSemaphore?

    var tempPath: String {
        DiggerCache.tempPath(url: url)
    }

    var cachePath: String {
        DiggerCache.cachePath(url: url)
    }

    var cacheFileURL: URL {
        URL(fileURLWithPath: DiggerCache.cachePath(url: url))
    }

    var outputStream: OutputStream?

    init(session: URLSession, url: URL, timeout: TimeInterval) {
        downloadTask = session.dataTask(with: url, timeout: timeout)
        self.url = url
    }

    @discardableResult
    public func progress(_ progress: @escaping ProgressCallback) -> Self {
        var callback = Callback(nil, nil, nil)
        callback.progress = progress
        callbacks.append(callback)
        return self
    }

    @discardableResult
    public func speed(_ speed: @escaping SpeedCallback) -> Self {
        var callback = Callback(nil, nil, nil)
        callback.speed = speed
        callbacks.append(callback)
        return self
    }

    @discardableResult
    public func completion(_ completion: @escaping CompletionCallback) -> Self {
        var callback = Callback(nil, nil, nil)
        callback.completion = completion
        callbacks.append(callback)
        return self
    }
}
