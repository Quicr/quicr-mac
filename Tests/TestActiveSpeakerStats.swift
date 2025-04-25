// SPDX-FileCopyrightText: Copyright (c) 2023 Cisco Systems
// SPDX-License-Identifier: BSD-2-Clause

@testable import QuicR
import Testing

@Test("Active Speaker Stats")
func testActiveSpeakerStats() async {
    let stats = ActiveSpeakerStats(nil)
    let id = ParticipantId(0)
    let detect = Date.now
    await stats.audioDetected(id, when: detect)
    let set = detect.addingTimeInterval(1)
    await stats.activeSpeakerSet(id, when: set)
    let dropped = set.addingTimeInterval(1)
    await stats.dataDropped(id, when: dropped)
    let received = dropped.addingTimeInterval(1)
    await stats.dataReceived(id, when: received)
    let enqueue = received.addingTimeInterval(1)
    let result = await stats.imageEnqueued(id, when: enqueue)
    #expect(result.detected == detect)
    #expect(result.set == set)
    #expect(result.dropped == dropped)
    #expect(result.received == received)
    #expect(result.enqueued == enqueue)

    let next = ParticipantId(1)
    await stats.dataReceived(next, when: received)
    let empty = await stats.imageEnqueued(next, when: enqueue)
    #expect(empty.detected == .none)
    #expect(empty.set == .none)
    #expect(empty.dropped == .none)
    #expect(empty.received == received)
    #expect(empty.enqueued == enqueue)
}
