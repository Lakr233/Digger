import Foundation

extension DispatchQueue {
    static let barrier = DispatchQueue(label: "wiki.qaq.digger.barrier", attributes: .concurrent)

    func safeAsync(_ block: @escaping @Sendable () -> Void) {
        if self === DispatchQueue.main, Thread.isMainThread {
            block()
        } else {
            async { block() }
        }
    }
}

extension OperationQueue {
    static func makeDiggerDelegateQueue() -> OperationQueue {
        let queue = OperationQueue()
        queue.name = "wiki.qaq.digger.delegateQueue"
        return queue
    }
}
