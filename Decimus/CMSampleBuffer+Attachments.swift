import AVFoundation

extension CMSampleBuffer {
    /// Check if this frame is an IDR (does NOT depend on others).
    /// - Returns: `true` if this sample is an IDR.
    func isIDR() -> Bool {
        guard let value = self.getAttachmentValue(for: .dependsOnOthers) else { return false }
        guard let dependsOnOthers = value as? Bool else { return false }
        return !dependsOnOthers
    }

    /// Check if this frame is discontinuous (a preceeding dependent frame is missing).
    /// - Returns: `true` if this sample is discontinous.
    var discontinous: Bool {
        get {
            guard let value = self.getAttachmentValue(for: .discontinous) else { return false }
            return (value as? Bool) ?? false
        }
        set(value) {
            try? setAttachmentValue(atIndex: 0, for: .discontinous, value: value as CFBoolean)
        }
    }

    private func getAttachmentValue(for key: CMSampleBuffer.PerSampleAttachmentsDictionary.Key) -> Any? {
        for attachment in self.sampleAttachments {
            let val = attachment[key]
            if val != nil {
                return val
            }
        }
        return nil
    }

    private func setAttachmentValue(atIndex index: Int,
                                    for key: CMSampleBuffer.PerSampleAttachmentsDictionary.Key,
                                    value: Any?) throws {
        guard self.sampleAttachments.count > index else {
            throw "Missing sampleAttachments dictionary"
        }
        self.sampleAttachments[index][key] = value
    }
}

extension CMSampleBuffer.PerSampleAttachmentsDictionary.Key {
    /// Set if a preceeding dependent of this frame is missing.
    public static let discontinous: CMSampleBuffer.PerSampleAttachmentsDictionary.Key = .init(rawValue: "decimus_discontinous" as CFString)
}
