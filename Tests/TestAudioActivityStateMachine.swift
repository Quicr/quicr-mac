// SPDX-FileCopyrightText: Copyright (c) 2025 Cisco Systems
// SPDX-License-Identifier: BSD-2-Clause

@testable import QuicR
import XCTest

final class TestAudioActivityStateMachine: XCTestCase {

    // MARK: - State Machine Tests

    func testIdleReturnsSpeechEnd() {
        let sm = AudioActivityStateMachine(minChangeInterval: 0.3)
        XCTAssertEqual(sm.update(voiceActive: false, now: .now), .speechEnd)
    }

    func testIdleToSpeaking() {
        let sm = AudioActivityStateMachine(minChangeInterval: 0.3)
        XCTAssertEqual(sm.update(voiceActive: true, now: .now), .speechStart)
    }

    func testContinuousAfterInterval() {
        let sm = AudioActivityStateMachine(minChangeInterval: 0.3)
        let start = Date.now
        XCTAssertEqual(sm.update(voiceActive: true, now: start), .speechStart)

        // Before interval: still speechStart (change rate-limited).
        XCTAssertEqual(sm.update(voiceActive: true, now: start.addingTimeInterval(0.1)), .speechStart)

        // After interval: transitions to continuousSpeech.
        XCTAssertEqual(sm.update(voiceActive: true, now: start.addingTimeInterval(0.35)), .continuousSpeech)
    }

    func testSpeakingToEnd() {
        let sm = AudioActivityStateMachine(minChangeInterval: 0.3)
        let start = Date.now
        XCTAssertEqual(sm.update(voiceActive: true, now: start), .speechStart)

        // Within rate limit — value holds at speechStart.
        XCTAssertEqual(sm.update(voiceActive: false, now: start.addingTimeInterval(0.1)), .speechStart)

        // After rate limit — changes to speechEnd.
        XCTAssertEqual(sm.update(voiceActive: false, now: start.addingTimeInterval(0.35)), .speechEnd)
    }

    func testEndResumesSpeaking() {
        let sm = AudioActivityStateMachine(minChangeInterval: 0.3)
        let start = Date.now
        XCTAssertEqual(sm.update(voiceActive: true, now: start), .speechStart)

        // Voice drops and changes after rate limit.
        XCTAssertEqual(sm.update(voiceActive: false, now: start.addingTimeInterval(0.35)), .speechEnd)

        // Voice resumes after another rate limit window.
        XCTAssertEqual(sm.update(voiceActive: true, now: start.addingTimeInterval(0.7)), .speechStart)
    }

    func testMultipleContinuousCycles() {
        let sm = AudioActivityStateMachine(minChangeInterval: 0.3)
        let start = Date.now
        XCTAssertEqual(sm.update(voiceActive: true, now: start), .speechStart)

        // First continuous.
        XCTAssertEqual(sm.update(voiceActive: true, now: start.addingTimeInterval(0.35)), .continuousSpeech)

        // Second continuous — same value, no change needed, no rate limit.
        XCTAssertEqual(sm.update(voiceActive: true, now: start.addingTimeInterval(0.4)), .continuousSpeech)
    }

    func testRateLimitHoldsValueDuringRapidChanges() {
        let sm = AudioActivityStateMachine(minChangeInterval: 0.3)
        let start = Date.now

        // Start speaking.
        XCTAssertEqual(sm.update(voiceActive: true, now: start), .speechStart)

        // Rapid VAD flicker within 300ms — value stays speechStart.
        XCTAssertEqual(sm.update(voiceActive: false, now: start.addingTimeInterval(0.05)), .speechStart)
        XCTAssertEqual(sm.update(voiceActive: true, now: start.addingTimeInterval(0.10)), .speechStart)
        XCTAssertEqual(sm.update(voiceActive: false, now: start.addingTimeInterval(0.15)), .speechStart)

        // After 300ms with voice off, change goes through.
        XCTAssertEqual(sm.update(voiceActive: false, now: start.addingTimeInterval(0.35)), .speechEnd)
    }

    func testEveryObjectGetsAValue() {
        let sm = AudioActivityStateMachine(minChangeInterval: 0.3)
        let start = Date.now

        // Every call returns a value — no nils, no "none".
        let v1 = sm.update(voiceActive: false, now: start)
        let v2 = sm.update(voiceActive: true, now: start.addingTimeInterval(0.35))
        let v3 = sm.update(voiceActive: true, now: start.addingTimeInterval(0.4))
        let v4 = sm.update(voiceActive: false, now: start.addingTimeInterval(0.7))

        XCTAssertEqual(v1, .speechEnd)
        XCTAssertEqual(v2, .speechStart)
        XCTAssertEqual(v3, .speechStart) // Not yet 300ms since change to start.
        XCTAssertEqual(v4, .speechEnd)
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
