import AVFAudio
import CoreAudio
import os

class OpusSubscription: QSubscriptionDelegateObjC {
    private static let logger = DecimusLogger(OpusSubscription.self)

    let sourceId: SourceIDType
    private let measurement: _Measurement?
    private let reliable: Bool
    private let granularMetrics: Bool
    private var seq: UInt32 = 0
    private let handler: OpusHandler

    init(sourceId: SourceIDType,
         profileSet: QClientProfileSet,
         engine: DecimusAudioEngine,
         submitter: MetricsSubmitter?,
         jitterDepth: TimeInterval,
         jitterMax: TimeInterval,
         opusWindowSize: OpusWindowSize,
         reliable: Bool,
         granularMetrics: Bool) throws {
        self.sourceId = sourceId
        if let submitter = submitter {
            self.measurement = .init(namespace: self.sourceId, submitter: submitter)
        } else {
            self.measurement = nil
        }
        self.reliable = reliable
        self.granularMetrics = granularMetrics
        self.handler = try .init(sourceId: sourceId,
                                 engine: engine,
                                 measurement: self.measurement,
                                 jitterDepth: jitterDepth,
                                 jitterMax: jitterMax,
                                 opusWindowSize: opusWindowSize,
                                 granularMetrics: granularMetrics)

        Self.logger.info("Subscribed to OPUS stream")
    }

    func prepare(_ sourceID: SourceIDType!,
                 label: String!,
                 profileSet: QClientProfileSet,
                 reliable: UnsafeMutablePointer<Bool>!) -> Int32 {
        reliable.pointee = self.reliable
        return SubscriptionError.none.rawValue
    }

    func update(_ sourceId: SourceIDType!, label: String!, profileSet: QClientProfileSet) -> Int32 {
        return SubscriptionError.noDecoder.rawValue
    }

    func subscribedObject(_ name: String!,
                          data: UnsafeRawPointer!,
                          length: Int,
                          groupId: UInt32,
                          objectId: UInt16) -> Int32 {
        // Metrics.
        let date: Date? = self.granularMetrics ? .now : nil

        // TODO: Handle sequence rollover.
        if groupId > self.seq {
            let missing = groupId - self.seq - 1
            let currentSeq = self.seq
            if let measurement = measurement {
                Task(priority: .utility) {
                    await measurement.receivedBytes(received: UInt(length), timestamp: date)
                    if missing > 0 {
                        Self.logger.warning("LOSS! \(missing) packets. Had: \(currentSeq), got: \(groupId)")
                        await measurement.missingSeq(missingCount: UInt64(missing), timestamp: date)
                    }
                }
            }
            self.seq = groupId
        }

        do {
            try handler.submitEncodedAudio(data: .init(bytesNoCopy: .init(mutating: data),
                                                       count: length,
                                                       deallocator: .none),
                                           sequence: groupId,
                                           date: date)
        } catch {
            Self.logger.error("Failed to handle encoded audio: \(error.localizedDescription)")
        }
        return SubscriptionError.none.rawValue
    }
}
