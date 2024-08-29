enum FullTrackNameError: Error {
    case parseError
}

struct FullTrackName: Hashable {
    let namespace: Data
    let name: Data

    init(namespace: String, name: String) throws {
        guard let namespace = namespace.data(using: .ascii) else {
            throw FullTrackNameError.parseError
        }
        self.namespace = namespace
        guard let name = name.data(using: .ascii) else {
            throw FullTrackNameError.parseError
        }
        self.name = name
    }

    func getNamespace() throws -> String {
        guard let namespace = String(data: self.namespace, encoding: .ascii) else {
            throw FullTrackNameError.parseError
        }
        return namespace
    }

    func getName() throws -> String {
        guard let name = String(data: self.name, encoding: .ascii) else {
            throw FullTrackNameError.parseError
        }
        return name
    }

    func get(_ closure: (QFullTrackName) -> Void) {
        self.namespace.withUnsafeBytes { namespace in
            let namespacePtr: UnsafePointer<CChar> = namespace.baseAddress!.bindMemory(to: CChar.self, capacity: namespace.count)
            self.name.withUnsafeBytes { name in
                let namePtr: UnsafePointer<CChar> = name.baseAddress!.bindMemory(to: CChar.self, capacity: name.count)

                let qFtn = QFullTrackName(nameSpace: namespacePtr,
                                          nameSpaceLength: self.namespace.count,
                                          name: namePtr,
                                          nameLength: self.name.count)
                closure(qFtn)
            }
        }
    }
}
