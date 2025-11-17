// SPDX-FileCopyrightText: Copyright (c) 2023 Cisco Systems
// SPDX-License-Identifier: BSD-2-Clause

@testable import QuicR
import Testing

/// Ensure status changes propagate to the callback correctly.
@Test("Status Callback", arguments: QSubscribeTrackHandlerStatus.allCases)
func testStatusCallback(_ status: QSubscribeTrackHandlerStatus) throws {
    func test(_ callback: Subscription.StatusCallback?) throws {
        let subscription = try Subscription(profile: .init(qualityProfile: "",
                                                           expiry: nil,
                                                           priorities: nil,
                                                           namespace: ["abc"]),
                                            endpointId: "1",
                                            relayId: "2",
                                            metricsSubmitter: nil,
                                            priority: 0,
                                            groupOrder: .originalPublisherOrder,
                                            filterType: .none,
                                            publisherInitiated: false,
                                            statusCallback: callback)

        // Mock status change.
        subscription.statusChanged(status)
    }

    // Check callback fires properly.
    try test { incoming in
        #expect(incoming == status)
    }

    // Sanity check for optional.
    try test(nil)
}
