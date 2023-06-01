import Foundation

class Publisher: QPublisherDelegateObjC {
    func allocatePub(byNamespace quicrNamepace: String!) -> Any! {
        return Publication()
    }

    func remove(byNamespace quicrNamepace: String!) -> Int32 {
        return 0
    }
}
