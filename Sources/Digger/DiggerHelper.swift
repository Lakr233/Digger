import Foundation

// MARK: - Result

public typealias DiggerResult = Swift.Result<URL, any Error>

// MARK: - Error

public let DiggerErrorDomain = "DiggerError"

public enum DiggerError: Int, Sendable {
    case badURL = 9981
    case fileIsExist = 9982
    case fileInfoError = 9983
    case invalidStatusCode = 9984
    case diskOutOfSpace = 9985
    case downloadCanceled = -999
}

// MARK: - Log Level

public enum LogLevel: Sendable {
    case high, low, none
}

public func diggerLog(_ info: some Any, file: String = #file, method: String = #function, line: Int = #line) {
    let message: String
    switch DiggerManager.shared.logLevel {
    case .none:
        return
    case .low:
        message = "[Digger] \(info)"
    case .high:
        let fileName = (file as NSString).lastPathComponent
        message = "[Digger] \(fileName):\(line) \(method) — \(info)"
    }

    if let handler = DiggerLogging.handler {
        handler(message, file, method, line)
    } else {
        print(message)
    }
}

// MARK: - URL Helper

public protocol DiggerURL: Sendable {
    func asURL() throws -> URL
}

extension String: DiggerURL {
    public func asURL() throws -> URL {
        guard let url = URL(string: self) else {
            throw NSError(
                domain: DiggerErrorDomain,
                code: DiggerError.badURL.rawValue,
                userInfo: [NSLocalizedDescriptionKey: "Invalid URL"],
            )
        }
        return url
    }
}

extension URL: DiggerURL {
    public func asURL() throws -> URL {
        self
    }
}
