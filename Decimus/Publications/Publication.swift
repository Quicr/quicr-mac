// SPDX-FileCopyrightText: Copyright (c) 2023 Cisco Systems
// SPDX-License-Identifier: BSD-2-Clause

import Atomics

class Publication: QPublishTrackHandlerObjC, QPublishTrackHandlerCallbacks {
    internal var publish = ManagedAtomic(false)
    internal let profile: Profile
    private let logger = DecimusLogger(Publication.self)
    private let measurement: MeasurementRegistration<TrackMeasurement>?
    internal let defaultPriority: UInt8
    internal let defaultTTL: UInt16
    internal var currentStatus: QPublishTrackHandlerStatus?

    init(profile: Profile,
         trackMode: QTrackMode,
         defaultPriority: UInt8,
         defaultTTL: UInt16,
         submitter: MetricsSubmitter?,
         endpointId: String,
         relayId: String) throws {
        self.profile = profile
        self.defaultPriority = defaultPriority
        self.defaultTTL = defaultTTL
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
    }

    internal func statusChanged(_ status: QPublishTrackHandlerStatus) {
        self.logger.info("[\(self.profile.namespace.joined())] Status changed to: \(status)")
        self.currentStatus = status
        let publish = switch status {
        case .announceNotAuthorized:
            false
        case .noSubscribers:
            false
        case .notAnnounced:
            false
        case .notConnected:
            false
        case .ok:
            true
        case .pendingAnnounceResponse:
            false
        case .sendingUnannounce:
            false
        case .subscriptionUpdated:
            true
        @unknown default:
            false
        }
        self.publish.store(publish, ordering: .releasing)
    }

    /// Retrieve the priority value from this publications' priority array at
    /// the given index, if one exists.
    /// - Parameter index: Offset into the priority array.
    /// - Returns: Priority value, or the default value.
    public func getPriority(_ index: Int) -> UInt8 {
        guard let priorities = profile.priorities,
              index < priorities.count,
              priorities[index] <= UInt8.max,
              priorities[index] >= UInt8.min else {
            return self.defaultPriority
        }
        return UInt8(priorities[index])
    }

    /// Retrieve the TTL / expiry value from this publications' expiry array at
    /// the given index, if one exists.
    /// - Parameter index: Offset into the expiry array.
    /// - Returns: TTL/Expiry value, or the default value.
    public func getTTL(_ index: Int) -> UInt16 {
        guard let ttls = profile.expiry,
              index < ttls.count,
              ttls[index] <= UInt16.max,
              ttls[index] >= UInt16.min else {
            return self.defaultTTL
        }
        return UInt16(ttls[index])
    }

    func metricsSampled(_ metrics: QPublishTrackMetrics) {
        if let measurement = self.measurement?.measurement {
            Task(priority: .utility) {
                await measurement.record(metrics)
            }
        }
    }
}
