// SPDX-FileCopyrightText: Copyright (c) 2024
// SPDX-License-Identifier: BSD-2-Clause

import Foundation

/// Result of a video publish operation.
enum VideoPublishResult {
    case ok
    case notReady
    case error
}

/// Delegate for receiving publish sink status updates.
protocol VideoPublishSinkDelegate: AnyObject {
    /// Called when a key frame should be generated (e.g., new subscriber, subscription update).
    func sinkRequestsKeyFrame()
}

/// Protocol abstracting the video publish operation.
/// Allows H264Publication to work with either libquicr or moxygen backends.
protocol VideoPublishSink: AnyObject {
    /// Delegate for status callbacks.
    var delegate: VideoPublishSinkDelegate? { get set }

    /// Check if the sink is ready to publish.
    func canPublish() -> Bool

    /// Publish a video frame.
    /// - Parameters:
    ///   - groupId: The group ID (typically increments on IDR frames).
    ///   - objectId: The object ID within the group.
    ///   - data: The encoded frame data.
    ///   - priority: Frame priority (lower = higher priority, 0 for IDR).
    ///   - ttl: Time to live in milliseconds.
    ///   - extensions: Optional mutable header extensions.
    ///   - immutableExtensions: Optional immutable header extensions (capture timestamp, sequence, etc.).
    /// - Returns: Result of the publish operation.
    func publish(groupId: UInt64,
                 objectId: UInt64,
                 data: Data,
                 priority: UInt8,
                 ttl: UInt16,
                 extensions: HeaderExtensions?,
                 immutableExtensions: HeaderExtensions?) -> VideoPublishResult

    /// Close the sink and release resources.
    func close()
}
