import Foundation

public let digger = "Digger"

@discardableResult
public func download(_ url: DiggerURL) -> DiggerSeed {
    DiggerManager.shared.download(with: url)
}
