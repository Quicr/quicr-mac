// SPDX-FileCopyrightText: Copyright (c) 2024
// SPDX-License-Identifier: BSD-2-Clause

import Foundation

/// MoQ sink implementation using moxygen.
class MoxygenVideoSink: MoQSink {
    private static let logger = DecimusLogger(MoxygenVideoSink.self)

    weak var delegate: MoQSinkDelegate?

    let fullTrackName: FullTrackName
    private let publisher: MoxygenPublisher
    private var isConnected: Bool = true
    private var currentStatus: QPublishTrackHandlerStatus = .ok

    init(publisher: MoxygenPublisher, fullTrackName: FullTrackName) {
        self.publisher = publisher
        self.fullTrackName = fullTrackName
        Self.logger.info("Created MoxygenVideoSink")
    }

    var status: QPublishTrackHandlerStatus {
        self.currentStatus
    }

    var canPublish: Bool {
        self.isConnected
    }

    func publishObject(_ headers: QObjectHeaders,
                       data: Data,
                       extensions: HeaderExtensions?,
                       immutableExtensions: HeaderExtensions?) -> QPublishObjectStatus {
        guard self.isConnected else {
            return .noSubscribers
        }
        let header = MoxygenObjectHeader()
        header.groupId = headers.groupId
        header.subgroupId = 0
        header.objectId = headers.objectId
        if let priority = headers.priority?.pointee {
            header.priority = priority
        }

        let success = publisher.publishObject(header,
                                              data: data,
                                              extensions: extensions,
                                              immutableExtensions: immutableExtensions)
        return success ? .ok : .noSubscribers
    }

    func close() {
        isConnected = false
        self.updateStatus(.notConnected)
        publisher.close()
    }

    deinit {
        self.close()
    }

    private func updateStatus(_ status: QPublishTrackHandlerStatus) {
        guard self.currentStatus != status else { return }
        self.currentStatus = status
        self.delegate?.sinkStatusChanged(status)
    }
}
