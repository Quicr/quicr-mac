// SPDX-FileCopyrightText: Copyright (c) 2025 Cisco Systems
// SPDX-License-Identifier: BSD-2-Clause

@testable import QuicR
import XCTest

final class TestAudioActivityStateMachine: XCTestCase {

    // MARK: - State Machine Tests

    func testIdleToSpeaking() {
        let sm = AudioActivityStateMachine()
        let now = Date.now
        let action = sm.update(voiceActive: true, now: now)
        guard case .sendExtension(let value) = action else {
            XCTFail("Expected sendExtension, got \(action)")
            return
        }
        XCTAssertEqual(value, .speechStart)
    }

    func testIdleStaysSilent() {
        let sm = AudioActivityStateMachine()
        let action = sm.update(voiceActive: false, now: .now)
        guard case .silent = action else {
            XCTFail("Expected silent, got \(action)")
            return
        }
    }

    func testSpeakingContinuousAfterInterval() {
        let sm = AudioActivityStateMachine()
        let start = Date.now
        _ = sm.update(voiceActive: true, now: start)

        // Before interval: should be .none
        let beforeAction = sm.update(voiceActive: true,
                                     now: start.addingTimeInterval(0.1))
        guard case .none = beforeAction else {
            XCTFail("Expected .none before interval, got \(beforeAction)")
            return
        }

        // After interval: should send continuous
        let afterAction = sm.update(voiceActive: true,
                                    now: start.addingTimeInterval(0.35))
        guard case .sendExtension(let value) = afterAction else {
            XCTFail("Expected sendExtension, got \(afterAction)")
            return
        }
        XCTAssertEqual(value, .continuousSpeech)
    }

    func testSpeakingToEndingSpeech() {
        let sm = AudioActivityStateMachine()
        let start = Date.now
        _ = sm.update(voiceActive: true, now: start)

        let action = sm.update(voiceActive: false,
                               now: start.addingTimeInterval(0.1))
        guard case .sendExtension(let value) = action else {
            XCTFail("Expected sendExtension, got \(action)")
            return
        }
        XCTAssertEqual(value, .speechEnd)
    }

    func testEndingSpeechResumesSpeaking() {
        let sm = AudioActivityStateMachine()
        let start = Date.now
        _ = sm.update(voiceActive: true, now: start)
        _ = sm.update(voiceActive: false, now: start.addingTimeInterval(0.1))

        // Voice resumes during ending period.
        let action = sm.update(voiceActive: true,
                               now: start.addingTimeInterval(0.2))
        guard case .sendExtension(let value) = action else {
            XCTFail("Expected sendExtension, got \(action)")
            return
        }
        XCTAssertEqual(value, .speechStart)
    }

    func testEndingSpeechRepeatsDuringWindow() {
        let sm = AudioActivityStateMachine()
        let start = Date.now
        _ = sm.update(voiceActive: true, now: start)
        _ = sm.update(voiceActive: false, now: start.addingTimeInterval(0.1))

        // Still within end repeat duration.
        let action = sm.update(voiceActive: false,
                               now: start.addingTimeInterval(0.3))
        guard case .sendExtension(let value) = action else {
            XCTFail("Expected sendExtension, got \(action)")
            return
        }
        XCTAssertEqual(value, .speechEnd)
    }

    func testEndingSpeechTransitionsToIdle() {
        let sm = AudioActivityStateMachine()
        let start = Date.now
        _ = sm.update(voiceActive: true, now: start)
        _ = sm.update(voiceActive: false, now: start.addingTimeInterval(0.1))

        // Past end repeat duration.
        let action = sm.update(voiceActive: false,
                               now: start.addingTimeInterval(0.7))
        guard case .silent = action else {
            XCTFail("Expected silent, got \(action)")
            return
        }

        // Confirm we're back to idle: next voice should be speechStart.
        let nextAction = sm.update(voiceActive: true,
                                   now: start.addingTimeInterval(0.8))
        guard case .sendExtension(let value) = nextAction else {
            XCTFail("Expected sendExtension, got \(nextAction)")
            return
        }
        XCTAssertEqual(value, .speechStart)
    }

    func testMultipleContinuousCycles() {
        let sm = AudioActivityStateMachine()
        let start = Date.now
        _ = sm.update(voiceActive: true, now: start)

        // First continuous.
        let first = sm.update(voiceActive: true, now: start.addingTimeInterval(0.35))
        guard case .sendExtension(.continuousSpeech) = first else {
            XCTFail("Expected continuous, got \(first)")
            return
        }

        // Second continuous (another 300ms+).
        let second = sm.update(voiceActive: true, now: start.addingTimeInterval(0.7))
        guard case .sendExtension(.continuousSpeech) = second else {
            XCTFail("Expected continuous, got \(second)")
            return
        }
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
