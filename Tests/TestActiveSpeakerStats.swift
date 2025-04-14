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
    let enqueue = set.addingTimeInterval(1)
    let result = await stats.imageEnqueued(id, when: enqueue)
    #expect(result.detected == detect)
    #expect(result.set == set)
    #expect(result.enqueued == enqueue)

    let empty = await stats.imageEnqueued(.init(1), when: enqueue)
    #expect(empty.detected == .none)
    #expect(empty.set == .none)
    #expect(empty.enqueued == enqueue)
}
