import Foundation

class Subscriber: QSubscriberDelegateObjC {
    let errorWriter: ErrorWriter

    init(errorWriter: ErrorWriter) {
        self.errorWriter = errorWriter
    }

    func allocateSub(byNamespace quicrNamepace: String!) -> Any! {
        return Subscription(errorWriter: errorWriter)
    }

    func remove(byNamespace quicrNamepace: String!) -> Int32 {
        return 0
    }
}
