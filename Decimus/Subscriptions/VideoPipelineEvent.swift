// SPDX-FileCopyrightText: Copyright (c) 2026 Cisco Systems
// SPDX-License-Identifier: BSD-2-Clause

import Foundation

enum VideoPipelineRejection: String, Sendable {
    case intercepted
    case stopped
    case paused
    case inactiveFetch
    case handlerUnavailable
    case unprotect
    case joinState
    case depacketize
    case unusable
    case jitterFull
    case jitterOld
    case nameDiscontinuity
    case missingFormat
    case decoder
    case displayLayer
}

enum VideoHandlerStopReason: String, Sendable {
    case inactiveCleanup
    case subscriptionStopped
}

struct VideoJitterDequeueTiming: Sendable {
    let scheduledWaitSeconds: TimeInterval
    let deadlineLatenessSeconds: TimeInterval?
    let bufferDepthSeconds: TimeInterval?
    let resumedFromEmpty: Bool
}

struct VideoDisplayEnqueueTiming: Sendable {
    let presentationSeconds: TimeInterval
    let frameAgeSeconds: TimeInterval
    let mainActorQueueDelaySeconds: TimeInterval
    let scheduledPresentationLeadSeconds: TimeInterval?
    let displayImmediately: Bool
    let readyForMoreMediaData: Bool
}

struct VideoPipelineEvent: Sendable {
    enum Kind: Sendable {
        case subscriptionStatus(String)
        case objectReceived(cached: Bool, activity: UInt8?)
        case objectUsable(presentationSeconds: TimeInterval)
        case objectRejected(VideoPipelineRejection, String?)
        case handlerCreated(ActivationType)
        case handlerStopped(VideoHandlerStopReason)
        case joinDecision(JoinStrategy)
        case fetchRequested(startObject: UInt64, endObject: UInt64)
        case fetchStatus(String)
        case fetchCompleted
        case newGroupRequested
        case jitterAdmitted
        case jitterRejected(VideoPipelineRejection)
        case jitterDequeued(VideoJitterDequeueTiming)
        case nameGate(accepted: Bool, previousGroup: UInt64?, previousObject: UInt64?)
        case decoderSubmitted(presentationSeconds: TimeInterval)
        case decoderOutput(presentationSeconds: TimeInterval)
        case decoderError(String)
        case simulreceiveCandidate(presentationSeconds: TimeInterval)
        case simulreceiveSelected(displayed: Bool, presentationSeconds: TimeInterval)
        case displayEnqueued(presentationSeconds: TimeInterval)
        case displayEnqueueTiming(VideoDisplayEnqueueTiming)
        case displayError(String)
    }

    let occurredAt: Ticks
    let fullTrackName: FullTrackName
    let handlerGeneration: UInt64?
    let renderEpoch: UInt64?
    let groupId: UInt64?
    let subgroupId: UInt64?
    let objectId: UInt64?
    let kind: Kind
}

typealias VideoPipelineEventCallback = @Sendable (VideoPipelineEvent) -> Void

struct VideoObjectIngress: Sendable {
    let fullTrackName: FullTrackName
    let groupId: UInt64
    let subgroupId: UInt64
    let objectId: UInt64
    let payloadLength: UInt64
    let status: QObjectStatus
    let activity: UInt8?
    let cached: Bool
}

enum VideoObjectIngressDecision: Sendable {
    case deliver
    case drop(reason: String)
    case delay(seconds: TimeInterval, reason: String)
}

typealias VideoObjectIngressInterceptor =
    @Sendable (VideoObjectIngress) -> VideoObjectIngressDecision
