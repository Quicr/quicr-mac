// SPDX-FileCopyrightText: Copyright (c) 2025 Cisco Systems
// SPDX-License-Identifier: BSD-2-Clause

@testable import QuicR
import XCTest

final class TestAudioActivityStateMachine: XCTestCase {

    private func makeSM(timeToSpeechStart: TimeInterval = 0.15,
                        timeToContinuous: TimeInterval = 0.5,
                        timeToDropStart: TimeInterval = 0.25,
                        timeToDropContinuous: TimeInterval = 0.6) -> AudioActivityStateMachine {
        .init(timeToSpeechStart: timeToSpeechStart,
              timeToContinuous: timeToContinuous,
              timeToDropStart: timeToDropStart,
              timeToDropContinuous: timeToDropContinuous)
    }

    // Use a small base to avoid floating point loss when adding intervals to Date.now.
    private let start = Date(timeIntervalSinceReferenceDate: 0)
    private func t(_ offset: TimeInterval) -> Date { self.start.addingTimeInterval(offset) }

    // MARK: - Basic Transitions

    func testSilenceStaysSpeechEnd() {
        let sm = makeSM()
        XCTAssertEqual(sm.update(voiceActive: false, now: t(0)), .speechEnd)
        XCTAssertEqual(sm.update(voiceActive: false, now: t(1.0)), .speechEnd)
    }

    func testVoiceBeforeThresholdStaysSpeechEnd() {
        let sm = makeSM()
        XCTAssertEqual(sm.update(voiceActive: true, now: t(0)), .speechEnd)
        XCTAssertEqual(sm.update(voiceActive: true, now: t(0.10)), .speechEnd)
    }

    func testSustainedVoiceTransitionsToSpeechStart() {
        let sm = makeSM()
        XCTAssertEqual(sm.update(voiceActive: true, now: t(0)), .speechEnd)
        XCTAssertEqual(sm.update(voiceActive: true, now: t(0.16)), .speechStart)
    }

    func testSustainedVoicePromotesToContinuous() {
        let sm = makeSM()
        // Rise to speechStart.
        XCTAssertEqual(sm.update(voiceActive: true, now: t(0)), .speechEnd)
        XCTAssertEqual(sm.update(voiceActive: true, now: t(0.16)), .speechStart)
        // Not yet continuous.
        XCTAssertEqual(sm.update(voiceActive: true, now: t(0.50)), .speechStart)
        // Now continuous (0.5s+ after entering speechStart).
        XCTAssertEqual(sm.update(voiceActive: true, now: t(0.67)), .continuousSpeech)
    }

    // MARK: - Hangover (Falling Edge)

    func testSpeechStartHangover() {
        let sm = makeSM()
        // Get into speechStart.
        sm.update(voiceActive: true, now: t(0))
        XCTAssertEqual(sm.update(voiceActive: true, now: t(0.16)), .speechStart)

        // Silence starts — still speechStart during hangover.
        XCTAssertEqual(sm.update(voiceActive: false, now: t(0.20)), .speechStart)
        XCTAssertEqual(sm.update(voiceActive: false, now: t(0.35)), .speechStart)
        // After hangover from start (0.25s+ of silence), drops.
        XCTAssertEqual(sm.update(voiceActive: false, now: t(0.46)), .speechEnd)
    }

    func testContinuousHangover() {
        let sm = makeSM()
        // Get into continuousSpeech.
        sm.update(voiceActive: true, now: t(0))
        sm.update(voiceActive: true, now: t(0.16))
        XCTAssertEqual(sm.update(voiceActive: true, now: t(0.67)), .continuousSpeech)

        // Silence — still continuous during hangover.
        XCTAssertEqual(sm.update(voiceActive: false, now: t(0.70)), .continuousSpeech)
        XCTAssertEqual(sm.update(voiceActive: false, now: t(1.0)), .continuousSpeech)
        // After hangover (0.6s+ of silence), drops to speechEnd.
        XCTAssertEqual(sm.update(voiceActive: false, now: t(1.31)), .speechEnd)
    }

    func testContinuousHangoverResetByVoice() {
        let sm = makeSM()
        // Get into continuousSpeech.
        sm.update(voiceActive: true, now: t(0))
        sm.update(voiceActive: true, now: t(0.16))
        XCTAssertEqual(sm.update(voiceActive: true, now: t(0.67)), .continuousSpeech)

        // Brief silence then voice resumes — hangover resets.
        XCTAssertEqual(sm.update(voiceActive: false, now: t(0.80)), .continuousSpeech)
        XCTAssertEqual(sm.update(voiceActive: true, now: t(0.90)), .continuousSpeech)
        // Even much later, still continuous because the hangover was reset.
        XCTAssertEqual(sm.update(voiceActive: false, now: t(1.20)), .continuousSpeech)
        // Now 0.6s+ of continuous silence from 1.20.
        XCTAssertEqual(sm.update(voiceActive: false, now: t(1.81)), .speechEnd)
    }

    // MARK: - Flicker Rejection

    func testFlickerDuringRiseDoesNotStart() {
        let sm = makeSM()
        // Voice active, then drops before threshold.
        XCTAssertEqual(sm.update(voiceActive: true, now: t(0)), .speechEnd)
        XCTAssertEqual(sm.update(voiceActive: false, now: t(0.05)), .speechEnd)
        // Restart — timer should have reset.
        XCTAssertEqual(sm.update(voiceActive: true, now: t(0.10)), .speechEnd)
        XCTAssertEqual(sm.update(voiceActive: true, now: t(0.20)), .speechEnd)
        // Full threshold from the restart at 0.10.
        XCTAssertEqual(sm.update(voiceActive: true, now: t(0.26)), .speechStart)
    }

    func testFlickerInSpeechStartResetsTimers() {
        let sm = makeSM()
        // Get into speechStart.
        sm.update(voiceActive: true, now: t(0))
        XCTAssertEqual(sm.update(voiceActive: true, now: t(0.16)), .speechStart)

        // Flicker: voice, silence, voice — neither promotion nor demotion should complete.
        XCTAssertEqual(sm.update(voiceActive: true, now: t(0.20)), .speechStart)
        XCTAssertEqual(sm.update(voiceActive: false, now: t(0.30)), .speechStart)
        XCTAssertEqual(sm.update(voiceActive: true, now: t(0.40)), .speechStart)
        // Still speechStart — the silence reset the promotion timer, the voice reset the demotion timer.
        XCTAssertEqual(sm.update(voiceActive: true, now: t(0.50)), .speechStart)
    }

    // MARK: - Every Update Returns a Value

    func testEveryUpdateReturnsAValue() {
        let sm = makeSM()
        // Every call returns a valid value regardless of input pattern.
        let values: [AudioActivityValue] = [
            sm.update(voiceActive: false, now: t(0)),
            sm.update(voiceActive: true, now: t(0.1)),
            sm.update(voiceActive: true, now: t(0.3)),
            sm.update(voiceActive: false, now: t(0.4)),
            sm.update(voiceActive: true, now: t(1.0)),
            sm.update(voiceActive: true, now: t(2.0))
        ]
        for value in values {
            XCTAssertTrue([.speechEnd, .speechStart, .continuousSpeech].contains(value))
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

    func testSharedStateLatestRead() {
        let state = SharedVoiceActivityState()
        XCTAssertNil(state.latestActivity())

        state.postActivity(.speechStart)
        XCTAssertEqual(state.latestActivity(), .speechStart)

        // Latest-value: repeated reads return the same value.
        XCTAssertEqual(state.latestActivity(), .speechStart)
    }

    func testSharedStateOverwrite() {
        let state = SharedVoiceActivityState()
        state.postActivity(.speechStart)
        state.postActivity(.speechEnd)

        // Should get the latest value.
        XCTAssertEqual(state.latestActivity(), .speechEnd)
        // Still there on re-read.
        XCTAssertEqual(state.latestActivity(), .speechEnd)
    }
}
