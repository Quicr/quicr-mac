// SPDX-FileCopyrightText: Copyright (c) 2024
// SPDX-License-Identifier: BSD-2-Clause

import Foundation

/// Video publish sink implementation using moxygen.
class MoxygenVideoSink: VideoPublishSink {
    private static let logger = DecimusLogger(MoxygenVideoSink.self)

    weak var delegate: VideoPublishSinkDelegate?

    private let publisher: MoxygenPublisher
    private var isConnected: Bool = true

    init(publisher: MoxygenPublisher) {
        self.publisher = publisher
        Self.logger.info("Created MoxygenVideoSink")
    }

    // MARK: - VideoPublishSink

    func canPublish() -> Bool {
        return isConnected
    }

    func publish(groupId: UInt64,
                 objectId: UInt64,
                 data: Data,
                 priority: UInt8,
                 ttl: UInt16,
                 extensions: HeaderExtensions?,
                 immutableExtensions: HeaderExtensions?) -> VideoPublishResult {
        let header = MoxygenObjectHeader()
        header.groupId = groupId
        header.subgroupId = 0
        header.objectId = objectId
        header.priority = priority

        let success = publisher.publishObject(header,
                                              data: data,
                                              extensions: extensions,
                                              immutableExtensions: immutableExtensions)
        return success ? .ok : .error
    }

    func close() {
        isConnected = false
        publisher.close()
    }
}
