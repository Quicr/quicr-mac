// SPDX-FileCopyrightText: Copyright (c) 2025 Cisco Systems
// SPDX-License-Identifier: BSD-2-Clause

@testable import QuicR
import XCTest

final class TestAudioActivityStateMachine: XCTestCase {

    // MARK: - State Machine Tests

    func testIdleReturnsSpeechEnd() {
        let sm = AudioActivityStateMachine(speechStartInterval: 0.3, continuousSpeechInterval: 0.3)
        XCTAssertEqual(sm.update(voiceActive: false, now: .now), .speechEnd)
    }

    func testIdleToSpeaking() {
        let sm = AudioActivityStateMachine(speechStartInterval: 0.3, continuousSpeechInterval: 0.3)
        XCTAssertEqual(sm.update(voiceActive: true, now: .now), .speechStart)
    }

    func testContinuousAfterInterval() {
        let sm = AudioActivityStateMachine(speechStartInterval: 0.3, continuousSpeechInterval: 0.3)
        let start = Date.now
        XCTAssertEqual(sm.update(voiceActive: true, now: start), .speechStart)

        // Before interval: still speechStart (change rate-limited).
        XCTAssertEqual(sm.update(voiceActive: true, now: start.addingTimeInterval(0.1)), .speechStart)

        // After interval: transitions to continuousSpeech.
        XCTAssertEqual(sm.update(voiceActive: true, now: start.addingTimeInterval(0.35)), .continuousSpeech)
    }

    func testSpeakingToEnd() {
        let sm = AudioActivityStateMachine(speechStartInterval: 0.3, continuousSpeechInterval: 0.3)
        let start = Date.now
        XCTAssertEqual(sm.update(voiceActive: true, now: start), .speechStart)

        // Drop to speechEnd is immediate (no rate limit on downward transition).
        XCTAssertEqual(sm.update(voiceActive: false, now: start.addingTimeInterval(0.1)), .speechEnd)
    }

    func testEndResumesSpeaking() {
        let sm = AudioActivityStateMachine(speechStartInterval: 0.3, continuousSpeechInterval: 0.3)
        let start = Date.now
        XCTAssertEqual(sm.update(voiceActive: true, now: start), .speechStart)

        // Voice drops — immediate transition to speechEnd.
        XCTAssertEqual(sm.update(voiceActive: false, now: start.addingTimeInterval(0.1)), .speechEnd)

        // Voice resumes after speechStart rate limit window from the drop.
        XCTAssertEqual(sm.update(voiceActive: true, now: start.addingTimeInterval(0.45)), .speechStart)
    }

    func testMultipleContinuousCycles() {
        let sm = AudioActivityStateMachine(speechStartInterval: 0.3, continuousSpeechInterval: 0.3)
        let start = Date.now
        XCTAssertEqual(sm.update(voiceActive: true, now: start), .speechStart)

        // First continuous.
        XCTAssertEqual(sm.update(voiceActive: true, now: start.addingTimeInterval(0.35)), .continuousSpeech)

        // Second continuous — same value, no change needed, no rate limit.
        XCTAssertEqual(sm.update(voiceActive: true, now: start.addingTimeInterval(0.4)), .continuousSpeech)
    }

    func testRateLimitHoldsValueDuringRapidChanges() {
        let sm = AudioActivityStateMachine(speechStartInterval: 0.3, continuousSpeechInterval: 0.3)
        let start = Date.now

        // Start speaking.
        XCTAssertEqual(sm.update(voiceActive: true, now: start), .speechStart)

        // Drop is immediate, then re-start is rate-limited.
        XCTAssertEqual(sm.update(voiceActive: false, now: start.addingTimeInterval(0.05)), .speechEnd)
        // Back to true but rate-limited (last change was at 0.05).
        XCTAssertEqual(sm.update(voiceActive: true, now: start.addingTimeInterval(0.10)), .speechEnd)
        // Still rate-limited.
        XCTAssertEqual(sm.update(voiceActive: true, now: start.addingTimeInterval(0.15)), .speechEnd)

        // After 300ms from last change, speechStart goes through.
        XCTAssertEqual(sm.update(voiceActive: true, now: start.addingTimeInterval(0.4)), .speechStart)
    }

    func testEveryObjectGetsAValue() {
        let sm = AudioActivityStateMachine(speechStartInterval: 0.3, continuousSpeechInterval: 0.3)
        let start = Date.now

        // Every call returns a value — no nils, no "none".
        let v1 = sm.update(voiceActive: false, now: start)
        let v2 = sm.update(voiceActive: true, now: start.addingTimeInterval(0.35))
        let v3 = sm.update(voiceActive: true, now: start.addingTimeInterval(0.4))
        let v4 = sm.update(voiceActive: false, now: start.addingTimeInterval(0.7))

        XCTAssertEqual(v1, .speechEnd)
        XCTAssertEqual(v2, .speechStart)
        XCTAssertEqual(v3, .speechStart) // Not yet 300ms since change to speechStart.
        XCTAssertEqual(v4, .speechEnd)   // Immediate drop.
    }

    // MARK: - Header Round-Trip Tests

    func testHeaderRoundTripSpeechStart() throws {
        var extensions = HeaderExtensions()
        try extensions.setHeader(.audioActivityIndicator(AudioActivityValue.speechStart.rawValue))
        let decoded = try extensions.getHeader(.audioActivityIndicator)
        guard case .audioActivityIndicator(let value) = decoded else {
            XCTFail("Expected audioActivityIndicator")
            return
        }
        XCTAssertEqual(value, AudioActivityValue.speechStart.rawValue)
    }

    func testHeaderRoundTripSpeechEnd() throws {
        var extensions = HeaderExtensions()
        try extensions.setHeader(.audioActivityIndicator(AudioActivityValue.speechEnd.rawValue))
        let decoded = try extensions.getHeader(.audioActivityIndicator)
        guard case .audioActivityIndicator(let value) = decoded else {
            XCTFail("Expected audioActivityIndicator")
            return
        }
        XCTAssertEqual(value, AudioActivityValue.speechEnd.rawValue)
    }

    func testHeaderRoundTripContinuous() throws {
        var extensions = HeaderExtensions()
        try extensions.setHeader(.audioActivityIndicator(AudioActivityValue.continuousSpeech.rawValue))
        let decoded = try extensions.getHeader(.audioActivityIndicator)
        guard case .audioActivityIndicator(let value) = decoded else {
            XCTFail("Expected audioActivityIndicator")
            return
        }
        XCTAssertEqual(value, AudioActivityValue.continuousSpeech.rawValue)
    }

    // MARK: - SharedVoiceActivityState Tests

    func testSharedStateProduceConsume() {
        let state = SharedVoiceActivityState()
        XCTAssertNil(state.consumeActivity())

        state.postActivity(.speechStart)
        XCTAssertEqual(state.consumeActivity(), .speechStart)

        // Consume-once: second consume should be nil.
        XCTAssertNil(state.consumeActivity())
    }

    func testSharedStateOverwrite() {
        let state = SharedVoiceActivityState()
        state.postActivity(.speechStart)
        state.postActivity(.speechEnd)

        // Should get the latest value.
        XCTAssertEqual(state.consumeActivity(), .speechEnd)
        XCTAssertNil(state.consumeActivity())
    }
}
