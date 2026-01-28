// SPDX-FileCopyrightText: Copyright (c) 2025 Cisco Systems
// SPDX-License-Identifier: BSD-2-Clause

/// Publishes text messages.
class TextPublication: PublicationInstance, MoQSinkDelegate {
    private let incrementing: Incrementing
    private let participantId: ParticipantId
    private let logger: DecimusLogger
    private let sframeContext: SendSFrameContext?
    let sink: MoQSink
    private let trackMeasurement: MeasurementRegistration<TrackMeasurement>?

    private var currentGroupId: UInt64
    private var currentObjectId: UInt64 = 0

    /// Creates a new TextPublication.
    init(participantId: ParticipantId,
         incrementing: Incrementing,
         profile: Profile,
         submitter: (any MetricsSubmitter)?,
         endpointId: String,
         relayId: String,
         sframeContext: SendSFrameContext?,
         startingGroupId: UInt64,
         sink: MoQSink) throws {
        self.logger = .init(TextPublication.self, prefix: "\(sink.fullTrackName)")
        self.participantId = participantId
        self.incrementing = incrementing
        self.sframeContext = sframeContext
        self.currentGroupId = startingGroupId
        self.sink = sink
        self.trackMeasurement = {
            guard let submitter = submitter else { return nil }
            let measurement = TrackMeasurement(type: .publish,
                                               endpointId: endpointId,
                                               relayId: relayId,
                                               namespace: profile.namespace.joined())
            return .init(measurement: measurement, submitter: submitter)
        }()
        self.sink.delegate = self
    }

    func sendMessage(_ message: String) {
        let data: Data
        if let sframeContext = self.sframeContext {
            do {
                data = try sframeContext.context.mutex.withLock { context in
                    try context.protect(epochId: sframeContext.currentEpoch,
                                        senderId: sframeContext.senderId,
                                        plaintext: .init(message.utf8))
                }
            } catch {
                self.logger.error("Failed to protect message: \(error.localizedDescription)")
                return
            }
        } else {
            data = Data(message.utf8)
        }

        let endOfGroup = self.incrementing == .group
        let headers = QObjectHeaders(groupId: self.currentGroupId,
                                     subgroupId: 0,
                                     objectId: self.currentObjectId,
                                     payloadLength: UInt64(data.count),
                                     priority: nil,
                                     ttl: nil,
                                     endOfSubgroup: endOfGroup,
                                     endOfGroup: endOfGroup)
        var extensions = HeaderExtensions()
        try? extensions.setHeader(.participantId(self.participantId))
        let status = self.sink.publishObject(headers,
                                             data: data,
                                             extensions: nil,
                                             immutableExtensions: extensions)
        switch status {
        case .ok:
            break
        case .noSubscribers:
            self.logger.warning("No subscribers")
        default:
            self.logger.error("Failed to send message: \(status)")
            return
        }

        switch self.incrementing {
        case .group:
            self.currentGroupId += 1
        case .object:
            self.currentObjectId += 1
        }
    }

    func sinkStatusChanged(_ status: QPublishTrackHandlerStatus) {
        self.logger.info("[\(self.sink.fullTrackName)] Status changed to: \(status)")
    }

    func sinkMetricsSampled(_ metrics: QPublishTrackMetrics) {
        if let measurement = self.trackMeasurement?.measurement {
            Task(priority: .utility) {
                await measurement.record(metrics)
            }
        }
    }
}
