//
//  DiggerDelegate.swift
//  Digger
//
//  Created by ant on 2017/10/25.
//  Copyright © 2017年 github.cornerant. All rights reserved.
//

import Foundation

public class DiggerDelegate: NSObject {
    var manager: DiggerManager?
}

// MARK: -  SessionDelegate

extension DiggerDelegate: URLSessionDataDelegate, URLSessionDelegate {
    public func urlSession(_: URLSession, dataTask: URLSessionDataTask, didReceive response: URLResponse, completionHandler: @escaping (URLSession.ResponseDisposition) -> Void) {
        guard let manager,
              let url = dataTask.originalRequest?.url,
              let diggerSeed = manager.findDiggerSeed(with: url)
        else {
            completionHandler(.cancel)
            return
        }

        var completionHandlerCalled = false
        defer {
            if !completionHandlerCalled {
                let error = NSError(
                    domain: DiggerErrorDomain,
                    code: DiggerError.downloadCanceled.rawValue,
                    userInfo: [
                        NSLocalizedDescriptionKey: "Unknown Error",
                    ]
                )
                notifyCompletionCallback(Result.failure(error), diggerSeed)
                completionHandler(.cancel)
            }
        }

        // the file has been downloaded
        if DiggerCache.isFileExist(atPath: DiggerCache.cachePath(url: url)) {
            let cachesURL = URL(fileURLWithPath: DiggerCache.cachePath(url: url))
            dataTask.cancel()
            notifyCompletionCallback(.success(cachesURL), diggerSeed)
            return
        }

        /// status code
        if let statusCode = (response as? HTTPURLResponse)?.statusCode,
           !(200 ..< 400).contains(statusCode)
        {
            let error = NSError(
                domain: DiggerErrorDomain,
                code: DiggerError.invalidStatusCode.rawValue,
                userInfo: [
                    "statusCode": statusCode,
                    NSLocalizedDescriptionKey: HTTPURLResponse.localizedString(forStatusCode: statusCode),
                ]
            )
            notifyCompletionCallback(Result.failure(error), diggerSeed)
            return
        }

        guard let responseHeaders = (response as? HTTPURLResponse)?.allHeaderFields as? [String: String] else {
            return
        }

        // rangeString    String    "bytes 9660646-72300329/72300330"
        if let fullRange = responseHeaders["Content-Range"],
           let total = fullRange.components(separatedBy: "/").last,
           let value = Int64(total)
        {
            diggerSeed.progress.totalUnitCount = value
        } else if diggerSeed.progress.completedUnitCount == 0 {
            diggerSeed.progress.totalUnitCount = response.expectedContentLength
        }

        if let completedBytesString = responseHeaders["Content-Range"]?
            .components(separatedBy: "-")
            .first?
            .components(separatedBy: " ")
            .last,
            let completedBytes = Int64(completedBytesString)
        { diggerSeed.progress.completedUnitCount = completedBytes }

        diggerSeed.outputStream = OutputStream(toFileAtPath: diggerSeed.tempPath, append: true)
        diggerSeed.outputStream?.open()
        diggerLog("start to download  \n" + url.absoluteString)
        completionHandlerCalled = true
        completionHandler(.allow)
    }

    public func urlSession(_: URLSession, dataTask: URLSessionDataTask, didReceive data: Data) {
        guard let manager else { return }

        guard let url = dataTask.originalRequest?.url, let diggerSeed = manager.findDiggerSeed(with: url) else {
            return
        }

        diggerSeed.progress.completedUnitCount += Int64((data as NSData).length)
        let buffer = [UInt8](data)

        diggerSeed.outputStream?.write(buffer, maxLength: (data as NSData).length)
        notifyProgressCallback(diggerSeed)
    }

    public func urlSession(_: URLSession, task: URLSessionTask, didCompleteWithError error: Error?) {
        guard let manager else { return }

        guard let url = task.originalRequest?.url, let diggerSeed = manager.findDiggerSeed(with: url) else {
            return
        }

        // Close stream before any file move/delete to avoid handle locking issues
        diggerSeed.outputStream?.close()

        // Skip if already notified
        if diggerSeed.didNotifyCompletion { return }

        // Prefer specific completionError if set in didFinishDownloadingTo
        let surfacedError = diggerSeed.completionError ?? error

        if let errorInfo = surfacedError {
            notifyCompletionCallback(Result.failure(errorInfo), diggerSeed)

        } else {
            // For background (download task) flow, the file should already be at temp path; for data task, data was written via stream
            if DiggerCache.isFileExist(atPath: diggerSeed.tempPath) {
                notifyCompletionCallback(Result.success(diggerSeed.cacheFileURL), diggerSeed)
            } else {
                // If no temp file found, treat as error
                let error = NSError(
                    domain: DiggerErrorDomain,
                    code: DiggerError.fileInfoError.rawValue,
                    userInfo: [NSLocalizedDescriptionKey: "Downloaded file not found"]
                )
                notifyCompletionCallback(.failure(error), diggerSeed)
            }
        }

    }
}

// MARK: - Download Delegate (background/URLSessionDownloadTask)

extension DiggerDelegate: URLSessionDownloadDelegate {
    public func urlSession(_ session: URLSession, downloadTask: URLSessionDownloadTask, didFinishDownloadingTo location: URL) {
        guard let manager,
              let url = downloadTask.originalRequest?.url,
              let diggerSeed = manager.findDiggerSeed(with: url)
        else { return }

        // If already completed (safeguard), do nothing
        if diggerSeed.didNotifyCompletion { return }

        // Validate HTTP status code first
        if let statusCode = (downloadTask.response as? HTTPURLResponse)?.statusCode,
           !(200 ..< 400).contains(statusCode)
        {
            let error = NSError(
                domain: DiggerErrorDomain,
                code: DiggerError.invalidStatusCode.rawValue,
                userInfo: [
                    "statusCode": statusCode,
                    NSLocalizedDescriptionKey: HTTPURLResponse.localizedString(forStatusCode: statusCode),
                ]
            )
            diggerSeed.completionError = error
            return
        }

        // If file already cached, short-circuit success (do not overwrite)
        if DiggerCache.isFileExist(atPath: diggerSeed.cachePath) {
            notifyCompletionCallback(.success(diggerSeed.cacheFileURL), diggerSeed)
            return
        }

        // Persist downloaded data into our tempPath: append if partial exists, else move
        do {
            // Ensure temp directory exists
            DiggerCache.createDirectory(atPath: "".tmpDir)

            let tempPath = diggerSeed.tempPath
            let tempURL = URL(fileURLWithPath: tempPath)
            if FileManager.default.fileExists(atPath: tempPath) {
                // Append newly downloaded chunk to existing partial file
                let currentSize = DiggerCache.fileSize(filePath: tempPath)
                // Check Content-Range start matches current size
                if let httpResponse = downloadTask.response as? HTTPURLResponse,
                   let contentRange = httpResponse.allHeaderFields["Content-Range"] as? String {
                    // Expected format: bytes <start>-<end>/<total>
                    let parts = contentRange.components(separatedBy: " ")
                    let rangePart = parts.count > 1 ? parts[1] : contentRange
                    let startStr = rangePart.components(separatedBy: "-").first?.components(separatedBy: "/").first
                    if let startStr, let start = Int64(startStr), start != currentSize {
                        // Inconsistent start; reset partial to avoid corruption
                        DiggerCache.removeTempFile(with: url)
                        try FileManager.default.moveItem(at: location, to: tempURL)
                    } else {
                        let readHandle = try FileHandle(forReadingFrom: location)
                        defer { try? readHandle.close() }
                        let writeHandle = try FileHandle(forWritingTo: tempURL)
                        try writeHandle.seekToEnd()
                        defer { try? writeHandle.close() }

                        // Copy in 1MB chunks
                        let chunkSize = 1 << 20
                        while true {
                            let data = try readHandle.read(upToCount: chunkSize)
                            if let data, !data.isEmpty {
                                try writeHandle.write(contentsOf: data)
                            } else {
                                break
                            }
                        }
                    }
                } else {
                    // No Content-Range header; fallback to reset and replace
                    DiggerCache.removeTempFile(with: url)
                    try FileManager.default.moveItem(at: location, to: tempURL)
                }
            } else {
                // No partial exists, move the whole file
                try FileManager.default.moveItem(at: location, to: tempURL)
            }

            // Update progress after persist
            let fileSize = DiggerCache.fileSize(filePath: tempPath)
            diggerSeed.progress.totalUnitCount = fileSize
            diggerSeed.progress.completedUnitCount = fileSize
            notifyProgressCallback(diggerSeed)
        } catch {
            diggerSeed.completionError = error
        }
    }

    public func urlSession(_ session: URLSession, downloadTask: URLSessionDownloadTask, didWriteData bytesWritten: Int64, totalBytesWritten: Int64, totalBytesExpectedToWrite: Int64) {
        guard let manager,
              let url = downloadTask.originalRequest?.url,
              let diggerSeed = manager.findDiggerSeed(with: url)
        else { return }

        if totalBytesExpectedToWrite > 0 {
            diggerSeed.progress.totalUnitCount = totalBytesExpectedToWrite
        }
        
        diggerSeed.progress.completedUnitCount = totalBytesWritten
        notifyProgressCallback(diggerSeed)
    }

    public func urlSession(_ session: URLSession, downloadTask: URLSessionDownloadTask, didResumeAtOffset fileOffset: Int64, expectedTotalBytes: Int64) {
        guard let manager,
              let url = downloadTask.originalRequest?.url,
              let diggerSeed = manager.findDiggerSeed(with: url)
        else { return }

        if expectedTotalBytes > 0 {
            diggerSeed.progress.totalUnitCount = expectedTotalBytes
        }
        
        diggerSeed.progress.completedUnitCount = max(0, fileOffset)
        notifyProgressCallback(diggerSeed)
    }
}

// MARK: -  notifyCallback

extension DiggerDelegate {
    func notifyProgressCallback(_ diggerSeed: DiggerSeed) {
        if diggerSeed.progress.totalUnitCount < diggerSeed.progress.completedUnitCount {
            diggerSeed.progress.totalUnitCount = diggerSeed.progress.completedUnitCount
        }

        notifySpeedCallback(diggerSeed)

        DispatchQueue.main.safeAsync {
            _ = diggerSeed.callbacks.map { $0.progress?(diggerSeed.progress) }
        }
    }

    func notifyCompletionCallback(_ result: Result<URL>, _ diggerSeed: DiggerSeed) {
        guard let manager else { return }

        // Prevent double notifications
        if diggerSeed.didNotifyCompletion { return }

        switch result {
        case let .failure(error as NSError):
            if error.code == DiggerError.downloadCanceled.rawValue {
                // If a task is cancelled, the temporary file will be deleted
                DiggerCache.removeItem(atPath: diggerSeed.tempPath)
            }

            diggerLog(error)

        case let .success(url):
            // Move temp to cache only if temp exists (skip when short-circuiting cached success)
            if DiggerCache.isFileExist(atPath: diggerSeed.tempPath) {
                DiggerCache.moveItem(atPath: diggerSeed.tempPath, toPath: diggerSeed.cachePath)
            }

            diggerLog("download success \n" + url.absoluteString)
        }

        manager.removeDiggerSeed(for: diggerSeed.url)
        diggerSeed.didNotifyCompletion = true

        DispatchQueue.main.safeAsync {
            _ = diggerSeed.callbacks.map { $0.completion?(result) }
        }
        
        notifySpeedZeroCallback(diggerSeed)
    }

    func notifySpeedCallback(_ diggerSeed: DiggerSeed) {
        let progress = diggerSeed.progress
        var dataCount = progress.completedUnitCount
        let time = Double(NSDate().timeIntervalSince1970)
        var lastData: Int64 = 0
        var lastTime: Double = 0

        if progress.userInfo[.throughputKey] != nil {
            lastData = progress.userInfo[.fileCompletedCountKey] as! Int64
        } else {
            dataCount = 0
        }

        if progress.userInfo[.estimatedTimeRemainingKey] != nil {
            lastTime = progress.userInfo[.estimatedTimeRemainingKey] as! Double
        }

        if (time - lastTime) <= 1.0 {
            return
        }
        let speed = Int64(Double(dataCount - lastData) / (time - lastTime))
        progress.setUserInfoObject(dataCount, forKey: .fileCompletedCountKey)
        progress.setUserInfoObject(time, forKey: .estimatedTimeRemainingKey)
        progress.setUserInfoObject(speed, forKey: .throughputKey)

        if let speed = progress.userInfo[.throughputKey] as? Int64 {
            DispatchQueue.main.safeAsync {
                _ = diggerSeed.callbacks.map { $0.speed?(speed) }
            }
        }
    }

    /// speed should be zero, when cancel or suspend

    public func notifySpeedZeroCallback(_ diggerSeed: DiggerSeed) {
        DispatchQueue.main.safeAsync {
            _ = diggerSeed.callbacks.map { $0.speed?(0) }
        }
    }
}
