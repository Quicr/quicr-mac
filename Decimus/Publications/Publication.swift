// SPDX-FileCopyrightText: Copyright (c) 2023 Cisco Systems
// SPDX-License-Identifier: BSD-2-Clause

/// Common interface for concrete publication types backed by a ``MoQSink``.
protocol PublicationInstance: AnyObject {
    /// The sink responsible for publishing media for this instance.
    var sink: MoQSink { get }
}

class Publication: PublicationInstance, MoQSinkDelegate {
    enum Incrementing {
        case group
        case object
    }

    internal let profile: Profile
    private let logger: DecimusLogger
    private let measurement: MeasurementRegistration<TrackMeasurement>?
    internal let defaultPriority: UInt8
    internal let defaultTTL: UInt16
    internal let sink: MoQSink

    init(profile: Profile,
         sink: MoQSink,
         defaultPriority: UInt8,
         defaultTTL: UInt16,
         submitter: MetricsSubmitter?,
         endpointId: String,
         relayId: String,
         logger: DecimusLogger) {
        self.profile = profile
        self.defaultPriority = defaultPriority
        self.defaultTTL = defaultTTL
        self.sink = sink
        self.logger = logger
        if let submitter = submitter {
            let measurement = TrackMeasurement(type: .publish,
                                               endpointId: endpointId,
                                               relayId: relayId,
                                               namespace: profile.namespace.joined())
            self.measurement = .init(measurement: measurement, submitter: submitter)
        } else {
            self.measurement = nil
        }
        self.sink.delegate = self
    }

    /// Forward publish requests to the sink.
    func publishObject(_ headers: QObjectHeaders,
                       data: Data,
                       extensions: HeaderExtensions?,
                       immutableExtensions: HeaderExtensions?) -> QPublishObjectStatus {
        self.sink.publishObject(headers,
                                data: data,
                                extensions: extensions,
                                immutableExtensions: immutableExtensions)
    }

    /// Whether the underlying handler can currently publish.
    func canPublish() -> Bool {
        self.sink.canPublish
    }

    /// Current status of the underlying handler.
    func getStatus() -> QPublishTrackHandlerStatus {
        self.sink.status
    }

    /// Retrieve the priority value from this publication's priority array at
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

    /// Retrieve the TTL / expiry value from this publication's expiry array at
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

    func sinkStatusChanged(_ status: QPublishTrackHandlerStatus) {
        self.logger.info("[\(self.profile.namespace.joined())] Status changed to: \(status)")
    }

    func sinkMetricsSampled(_ metrics: QPublishTrackMetrics) {
        if let measurement = self.measurement?.measurement {
            Task(priority: .utility) {
                await measurement.record(metrics)
            }
        }
    }
}
