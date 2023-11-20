import AVFoundation

extension CMSampleBuffer {
     func getAttachmentValue(for key:  CMSampleBuffer.PerSampleAttachmentsDictionary.Key) -> Any? {
        for attachment in self.sampleAttachments {
            let val = attachment[key]
            if (val != nil) {
                return val
            }
        }
        return nil
    }
    
    func setAttachmentValue(atIndex index: Int, for key: CMSampleBuffer.PerSampleAttachmentsDictionary.Key, value: Any?) throws {
        guard self.sampleAttachments.count > index else {
            throw "Missing sampleAttachments dictionary"
        }
        self.sampleAttachments[index][key] = value
    }

    func isIDR() -> Bool {
        guard let value = self.getAttachmentValue(for: .dependsOnOthers) else { return false }
        guard let dependsOnOthers = value as? Bool else { return false }
        return !dependsOnOthers
    }
    
    func setGroupId(_ groupId: UInt32) throws {
        let keyString: CFString = "groupId" as CFString
        let key: CMSampleBuffer.PerSampleAttachmentsDictionary.Key = .init(rawValue: keyString)
        try self.setAttachmentValue(atIndex: 0, for: key, value: groupId)
    }
    
    func getGroupId() -> UInt32? {
        let keyString: CFString = "groupId" as CFString
        let key: CMSampleBuffer.PerSampleAttachmentsDictionary.Key = .init(rawValue: keyString)
        guard let value = self.getAttachmentValue(for: key) as? UInt32 else {
            return nil
        }
        return value
    }
    
    func setObjectId(_ objectId: UInt16) throws {
        let keyString: CFString = "objectId" as CFString
        let key: CMSampleBuffer.PerSampleAttachmentsDictionary.Key = .init(rawValue: keyString)
        try self.setAttachmentValue(atIndex: 0, for: key, value: objectId)
    }
    
    func getObjectId() -> UInt16? {
        let keyString: CFString = "objectId" as CFString
        let key: CMSampleBuffer.PerSampleAttachmentsDictionary.Key = .init(rawValue: keyString)
        guard let value = self.getAttachmentValue(for: key) as? UInt16 else {
            return nil
        }
        return value
    }
    
    func setSequenceNumber(_ sequenceNumber: UInt64) throws {
        let keyString: CFString = "sequenceNumber" as CFString
        let key: CMSampleBuffer.PerSampleAttachmentsDictionary.Key = .init(rawValue: keyString)
        try self.setAttachmentValue(atIndex: 0, for: key, value: sequenceNumber)
    }
    
    func getSequenceNumber() -> UInt64? {
        let keyString: CFString = "sequenceNumber" as CFString
        let key: CMSampleBuffer.PerSampleAttachmentsDictionary.Key = .init(rawValue: keyString)
        guard let value = self.getAttachmentValue(for: key) as? UInt64 else {
            return nil
        }
        return value
    }
    
    func setFPS(_ fps: UInt8) throws {
        let keyString: CFString = "FPS" as CFString
        let key: CMSampleBuffer.PerSampleAttachmentsDictionary.Key = .init(rawValue: keyString)
        try self.setAttachmentValue(atIndex: 0, for: key, value: fps)
    }
    
    func getFPS() -> UInt8? {
        let keyString: CFString = "FPS" as CFString
        let key: CMSampleBuffer.PerSampleAttachmentsDictionary.Key = .init(rawValue: keyString)
        guard let value = self.getAttachmentValue(for: key) as? UInt8 else {
            return nil
        }
        return value
    }
    
    func setOrientation(_ orientation: AVCaptureVideoOrientation) throws {
        let keyString: CFString = "Orientation" as CFString
        let key: CMSampleBuffer.PerSampleAttachmentsDictionary.Key = .init(rawValue: keyString)
        try self.setAttachmentValue(atIndex: 0, for: key, value: orientation)
    }
    
    func getOrientation() -> AVCaptureVideoOrientation? {
        let keyString: CFString = "Orientation" as CFString
        let key: CMSampleBuffer.PerSampleAttachmentsDictionary.Key = .init(rawValue: keyString)
        let value = self.getAttachmentValue(for: key) as? AVCaptureVideoOrientation
        return value
    }
    
    func setVerticalMirror(_ verticalMirror: Bool) throws {
        let keyString: CFString = "verticalMirror" as CFString
        let key: CMSampleBuffer.PerSampleAttachmentsDictionary.Key = .init(rawValue: keyString)
        try self.setAttachmentValue(atIndex: 0, for: key, value: verticalMirror)
    }
    
    func getVerticalMirror() -> Bool? {
        let keyString: CFString = "verticalMirror" as CFString
        let key: CMSampleBuffer.PerSampleAttachmentsDictionary.Key = .init(rawValue: keyString)
        let value = self.getAttachmentValue(for: key) as? Bool
        return value
    }
}
