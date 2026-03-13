// SPDX-FileCopyrightText: Copyright (c) 2023 Cisco Systems
// SPDX-License-Identifier: BSD-2-Clause

import Foundation

/// Type of activation that triggered the switch.
enum ActivationType: String {
    /// Fresh subscription created via publishReceived.
    case newSubscription = "new_subscription"
    /// Objects resumed on an existing subscription after idle.
    case reactivation = "reactivation"
    /// Existing subscription, existing handler.
    case existing = "existing"
}

/// Join strategy chosen for mid-stream join.
enum JoinStrategy: String {
    /// Fetch missing objects from start of group.
    case fetch = "fetch"
    /// Request a new group (IDR) from the relay.
    case newGroup = "new_group"
    /// Wait for a natural IDR to arrive.
    case wait = "wait"
    /// Started on an IDR.
    case idr = "idr"
}

/// Accumulates timestamps through the join flow for a single switch event.
/// Created on activation, populated through state machine, consumed at first frame enqueue.
struct SwitchContext {
    let activationType: ActivationType
    let activationTime: Ticks
    let groupDepth: UInt64

    var joinStrategy: JoinStrategy?
    var joinDecisionTime: Ticks?
    var joinCompleteTime: Ticks?
    var fetchObjectCount: UInt64?
    var decodeTime: Date?
}
