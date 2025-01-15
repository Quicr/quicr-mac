// SPDX-FileCopyrightText: Copyright (c) 2023 Cisco Systems
// SPDX-License-Identifier: BSD-2-Clause

class Fetch: QFetchTrackHandlerObjC, QSubscribeTrackHandlerCallbacks {
    private let logger = DecimusLogger(Fetch.self)

    init(_ ftn: FullTrackName,
         priority: UInt8,
         groupOrder: QGroupOrder,
         startGroup: UInt64,
         endGroup: UInt64,
         startObject: UInt64,
         endObject: UInt64) {
        super.init(fullTrackName: ftn,
                   priority: priority,
                   groupOrder: groupOrder,
                   startGroup: startGroup,
                   endGroup: endGroup,
                   startObject: startObject,
                   endObject: endObject)
        super.setCallbacks(self)
    }

    func statusChanged(_ status: QSubscribeTrackHandlerStatus) {
        self.logger.info("Status changed: \(status)")
    }

    func objectReceived(_ objectHeaders: QObjectHeaders, data: Data, extensions: [NSNumber: Data]?) {
        self.logger.info("FETCH - Object received")
    }

    func partialObjectReceived(_ objectHeaders: QObjectHeaders, data: Data, extensions: [NSNumber: Data]?) {
        assert(false)
    }

    func metricsSampled(_ metrics: QSubscribeTrackMetrics) {
        self.logger.info("FETCH - Metrics")
    }
}
