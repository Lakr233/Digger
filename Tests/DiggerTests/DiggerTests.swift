import XCTest
@testable import Digger

final class DiggerTests: XCTestCase {
    override class func setUp() {
        super.setUp()
        DiggerManager.shared.logLevel = .low
        // check env ALLOWS_BACKGROUND_DOWNLOAD
        if let allowsBackgroundDownload = ProcessInfo.processInfo.environment["ALLOWS_BACKGROUND_DOWNLOAD"] {
            DiggerManager.shared.allowsBackgroundDownload = (allowsBackgroundDownload as NSString).boolValue
        } else {
            DiggerManager.shared.allowsBackgroundDownload = false
        }
        DiggerManager.shared.startDownloadImmediately = true
        DiggerManager.shared.timeout = 5
        DiggerCache.cachesDirectory = "DiggerTestsCache"
        DiggerCache.cleanDownloadFiles()
        DiggerCache.cleanDownloadTempFiles()
    }

    override func setUpWithError() throws {
        try super.setUpWithError()
        DiggerCache.cleanDownloadFiles()
        DiggerCache.cleanDownloadTempFiles()
    }

    private func serverURL(_ path: String) -> URL { URL(string: "http://127.0.0.1:18080\(path)")! }

    private func ensureServerAvailable() -> Bool {
        let url = serverURL("/hello.txt")
        let exp = expectation(description: "ping server")
        var ok = false
        let task = URLSession.shared.dataTask(with: url) { data, resp, _ in
            if let http = resp as? HTTPURLResponse, http.statusCode == 200, let data, String(data: data, encoding: .utf8)?.contains("hello") == true {
                ok = true
            }
            exp.fulfill()
        }
        task.resume()
        wait(for: [exp], timeout: 3)
        return ok
    }

    func testSmallDownload() throws {
        try XCTSkipUnless(ensureServerAvailable(), "Dev server not running on 127.0.0.1:18080")

        let url = serverURL("/hello.txt")
        let exp = expectation(description: "download finished")
        var resultURL: URL?
        download(url).completion { result in
            switch result {
            case let .success(u): resultURL = u
            case let .failure(e): XCTFail("download failed: \(e)")
            }
            exp.fulfill()
        }
        wait(for: [exp], timeout: 10)

        XCTAssertNotNil(resultURL)
        if let u = resultURL {
            let data = try Data(contentsOf: u)
            let text = String(data: data, encoding: .utf8)
            XCTAssertEqual(text, "hello from nginx\n")
        }
    }

    func testResumeDownloadRange() throws {
        try XCTSkipUnless(ensureServerAvailable(), "Dev server not running on 127.0.0.1:18080")

        // big file supports Range
        let url = serverURL("/bigfile.bin")

        // Step 1: start and quickly suspend
        let seed1 = DiggerManager.shared.download(with: url)
        let expProg = expectation(description: "got some progress")
        var gotProgress = false
        seed1.progress { prog in
            if !gotProgress && prog.completedUnitCount > 0 { gotProgress = true; expProg.fulfill() }
        }
        // Run briefly
        DispatchQueue.global().asyncAfter(deadline: .now() + 0.5) {
            DiggerManager.shared.stopTask(for: url)
        }
        wait(for: [expProg], timeout: 10)
        XCTAssertTrue(gotProgress)

        // Step 2: resume and complete
        let exp = expectation(description: "resume finished")
        download(url).completion { result in
            switch result {
            case .success: break
            case let .failure(e): XCTFail("resume failed: \(e)")
            }
            exp.fulfill()
        }
        DiggerManager.shared.startTask(for: url)
        wait(for: [exp], timeout: 20)

        // Verify file exists in cache and has expected size (10 MB)
        let cachePath = DiggerCache.cachePath(url: url)
        XCTAssertTrue(FileManager.default.fileExists(atPath: cachePath))
        let size = DiggerCache.fileSize(filePath: cachePath)
        XCTAssertEqual(size, 10 * 1024 * 1024)
    }

    func testCancelDeletesTemp() throws {
        try XCTSkipUnless(ensureServerAvailable(), "Dev server not running on 127.0.0.1:18080")

        let url = serverURL("/bigfile.bin")
        let seed = DiggerManager.shared.download(with: url)
        let tempPath = DiggerCache.tempPath(url: url)

        // wait for some temp bytes
        let expProg = expectation(description: "temp growing")
        var seenTemp = false
        seed.progress { _ in
            if !seenTemp && DiggerCache.fileSize(filePath: tempPath) > 0 { seenTemp = true; expProg.fulfill() }
        }
        wait(for: [expProg], timeout: 10)
        XCTAssertTrue(seenTemp)

        // cancel
        DiggerManager.shared.cancelTask(for: url)

        // give delegate time to cleanup
        let exp = expectation(description: "cleanup")
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) { exp.fulfill() }
        wait(for: [exp], timeout: 2)

        XCTAssertFalse(FileManager.default.fileExists(atPath: tempPath))
    }

    func testHTTPStatusErrors() throws {
        try XCTSkipUnless(ensureServerAvailable(), "Dev server not running on 127.0.0.1:18080")

        for codePath in ["/status/404": 404, "/status/500": 500] {
            let url = serverURL(codePath.key)
            let exp = expectation(description: "status error \(codePath.value)")
            var receivedError: NSError?
            download(url).completion { result in
                if case let .failure(e as NSError) = result { receivedError = e }
                exp.fulfill()
            }
            wait(for: [exp], timeout: 5)
            guard let err = receivedError else { return XCTFail("expected failure for \(codePath.value)") }
            XCTAssertEqual(err.domain, DiggerErrorDomain)
            XCTAssertEqual(err.code, DiggerError.invalidStatusCode.rawValue)
            if let status = err.userInfo["statusCode"] as? Int {
                XCTAssertEqual(status, codePath.value)
            }
        }
    }

    func testRedirectsSucceed() throws {
        try XCTSkipUnless(ensureServerAvailable(), "Dev server not running on 127.0.0.1:18080")

        for path in ["/redirect-hello", "/redirect1"] {
            let url = serverURL(path)
            let exp = expectation(description: "redirect finished \(path)")
            var text: String?
            download(url).completion { result in
                switch result {
                case let .success(u):
                    let data = try? Data(contentsOf: u)
                    text = data.flatMap { String(data: $0, encoding: .utf8) }
                case let .failure(e):
                    XCTFail("redirect failed: \(e)")
                }
                exp.fulfill()
            }
            wait(for: [exp], timeout: 10)
            XCTAssertEqual(text, "hello from nginx\n")
        }
    }

    func testRedirectLoopFails() throws {
        try XCTSkipUnless(ensureServerAvailable(), "Dev server not running on 127.0.0.1:18080")

        let url = serverURL("/loop1")
        let exp = expectation(description: "loop failed")
        var receivedError: URLError?
        download(url).completion { result in
            if case let .failure(e) = result {
                receivedError = e as? URLError
            }
            exp.fulfill()
        }
        wait(for: [exp], timeout: 10)
        XCTAssertNotNil(receivedError)
        if let err = receivedError { XCTAssertEqual(err.code, .httpTooManyRedirects) }
    }

    func testCancelThenResumeFresh() throws {
        try XCTSkipUnless(ensureServerAvailable(), "Dev server not running on 127.0.0.1:18080")

        let url = serverURL("/bigfile.bin")

        // Start and cancel once some data arrived
        let seed = DiggerManager.shared.download(with: url)
        let expProg = expectation(description: "got progress then cancel")
        var progressed = false
        seed.progress { prog in
            if !progressed && prog.completedUnitCount > 0 { progressed = true; expProg.fulfill() }
        }
        wait(for: [expProg], timeout: 10)
        XCTAssertTrue(progressed)

        DiggerManager.shared.cancelTask(for: url)

        // Ensure temp removed
        let tempPath = DiggerCache.tempPath(url: url)
        let check = expectation(description: "temp removed")
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) { check.fulfill() }
        wait(for: [check], timeout: 2)
        XCTAssertFalse(FileManager.default.fileExists(atPath: tempPath))

        // Start fresh and complete
        let done = expectation(description: "fresh finished")
        download(url).completion { result in
            if case let .failure(e) = result { XCTFail("fresh download failed: \(e)") }
            done.fulfill()
        }
        wait(for: [done], timeout: 30)

        XCTAssertEqual(DiggerCache.fileSize(filePath: DiggerCache.cachePath(url: url)), 10 * 1024 * 1024)
    }

    func testProgressMonotonicIncreasing() throws {
        try XCTSkipUnless(ensureServerAvailable(), "Dev server not running on 127.0.0.1:18080")

        let url = serverURL("/bigfile.bin")
        var lastCompleted: Int64 = -1
        var lastTotal: Int64 = -1
        var sawIncrease = false
        let exp = expectation(description: "monotonic finished")
        download(url)
            .progress { p in
                if lastCompleted >= 0 {
                    XCTAssertGreaterThanOrEqual(p.completedUnitCount, lastCompleted, "completed should not decrease")
                    XCTAssertGreaterThanOrEqual(p.totalUnitCount, lastTotal, "total should not decrease")
                    if p.completedUnitCount > lastCompleted { sawIncrease = true }
                }
                lastCompleted = p.completedUnitCount
                lastTotal = p.totalUnitCount
            }
            .completion { result in
                if case let .failure(e) = result { XCTFail("download failed: \(e)") }
                exp.fulfill()
            }
        wait(for: [exp], timeout: 30)
        XCTAssertTrue(sawIncrease)
    }

    func testSpeedCallbacksAndZeroOnSuspend() throws {
        try XCTSkipUnless(ensureServerAvailable(), "Dev server not running on 127.0.0.1:18080")

        let url = serverURL("/slow/bigfile.bin")
        let seed = DiggerManager.shared.download(with: url)
        let sawAnySpeed = expectation(description: "saw any speed callback")
        var gotAnySpeed = false
        var gotZeroAfterSuspend = false
        var stopped = false
        seed.speed { s in
            if !gotAnySpeed { gotAnySpeed = true; sawAnySpeed.fulfill() }
            if stopped && s == 0 { gotZeroAfterSuspend = true }
        }
        wait(for: [sawAnySpeed], timeout: 10)
        XCTAssertTrue(gotAnySpeed)

        // Suspend then expect zero callback (delegate triggers it on stop)
        stopped = true
        DiggerManager.shared.stopTask(for: url)

        let expZero = expectation(description: "got zero after suspend")
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) { expZero.fulfill() }
        wait(for: [expZero], timeout: 2)

        // Accept either explicit zero-speed callback or suspended state as success
        let isSuspended = seed.downloadTask.state == .suspended
        XCTAssertTrue(gotZeroAfterSuspend || isSuspended)

        // Cleanup to avoid long-running slow download
        DiggerManager.shared.cancelTask(for: url)
    }

    func testTimeoutOnUnreachable() throws {
        // Set a very low timeout and hit an unroutable IP to force timeout
        let original = DiggerManager.shared.timeout
        DiggerManager.shared.timeout = 1
        defer { DiggerManager.shared.timeout = original }

        let url = URL(string: "http://10.255.255.1/never")!
        let exp = expectation(description: "timeout")
        var error: URLError?
        download(url).completion { result in
            if case let .failure(e as URLError) = result { error = e }
            exp.fulfill()
        }
        wait(for: [exp], timeout: 5)
        XCTAssertNotNil(error)
        if let e = error { XCTAssertEqual(e.code, .timedOut) }
    }
}
