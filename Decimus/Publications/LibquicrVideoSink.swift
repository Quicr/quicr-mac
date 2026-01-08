// SPDX-FileCopyrightText: Copyright (c) 2024
// SPDX-License-Identifier: BSD-2-Clause

import Foundation

/// Video publish sink implementation using libquicr.
/// Inherits from QPublishTrackHandlerObjC to integrate with the existing controller system.
class LibquicrVideoSink: QPublishTrackHandlerObjC, QPublishTrackHandlerCallbacks, VideoPublishSink {
    private static let logger = DecimusLogger(LibquicrVideoSink.self)

    weak var delegate: VideoPublishSinkDelegate?

    private let profile: Profile
    private let measurement: MeasurementRegistration<TrackMeasurement>?
    private let keyFrameOnUpdate: Bool

    init(profile: Profile,
         trackMode: QTrackMode,
         defaultPriority: UInt8,
         defaultTTL: UInt16,
         submitter: MetricsSubmitter?,
         endpointId: String,
         relayId: String,
         useAnnounce: Bool,
         keyFrameOnUpdate: Bool) throws {
        self.profile = profile
        self.keyFrameOnUpdate = keyFrameOnUpdate

        if let submitter = submitter {
            let measurement = TrackMeasurement(type: .publish,
                                               endpointId: endpointId,
                                               relayId: relayId,
                                               namespace: profile.namespace.joined())
            self.measurement = .init(measurement: measurement, submitter: submitter)
        } else {
            self.measurement = nil
        }

        super.init(fullTrackName: try profile.getFullTrackName(),
                   trackMode: trackMode,
                   defaultPriority: defaultPriority,
                   defaultTTL: UInt32(defaultTTL))
        super.setCallbacks(self)
        super.setUseAnnounce(useAnnounce)
    }

    // MARK: - VideoPublishSink

    func publish(groupId: UInt64,
                 objectId: UInt64,
                 data: Data,
                 priority: UInt8,
                 ttl: UInt16,
                 extensions: HeaderExtensions?,
                 immutableExtensions: HeaderExtensions?) -> VideoPublishResult {
        var mutablePriority = priority
        var mutableTTL = ttl
        let headers = QObjectHeaders(groupId: groupId,
                                     objectId: objectId,
                                     payloadLength: UInt64(data.count),
                                     priority: &mutablePriority,
                                     ttl: &mutableTTL)
        let status = self.publishObject(headers, data: data, extensions: extensions, immutableExtensions: immutableExtensions)
        switch status {
        case .ok:
            return .ok
        case .notAnnounced, .noSubscribers, .paused:
            return .notReady
        default:
            return .error
        }
    }

    func close() {
        // Libquicr handles cleanup through the controller
    }

    // MARK: - QPublishTrackHandlerCallbacks

    func statusChanged(_ status: QPublishTrackHandlerStatus) {
        Self.logger.info("[\(self.profile.namespace.joined())] Status changed to: \(status)")

        // Request key frame on subscription update or new group request
        if (status == .subscriptionUpdated && self.keyFrameOnUpdate) || status == .newGroupRequested {
            delegate?.sinkRequestsKeyFrame()
        }
    }

    func metricsSampled(_ metrics: QPublishTrackMetrics) {
        if let measurement = self.measurement?.measurement {
            Task(priority: .utility) {
                await measurement.record(metrics)
            }
        }
    }
}
