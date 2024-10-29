// SPDX-FileCopyrightText: Copyright (c) 2023 Cisco Systems
// SPDX-License-Identifier: BSD-2-Clause

import XCTest
@testable import QuicR

final class TestOpusPublication: XCTestCase {
    func testMetrics() throws {
        //        let publication = try! OpusPublication(profile: .init(qualityProfile: "",
        //                                                              expiry: nil,
        //                                                              priorities: nil,
        //                                                              namespace: ""),
        //                                               metricsSubmitter: nil,
        //                                               opusWindowSize: .twentyMs,
        //                                               reliable: true,
        //                                               engine: .init(),
        //                                               granularMetrics: true,
        //                                               config: .init(codec: .opus, bitrate: 24000),
        //                                               endpointId: "",
        //                                               relayId: "")
        //        publication.metricsSampled(.init())
    }

    #if os(macOS) || (os(iOS) && targetEnvironment(macCatalyst))
    func testAudioTimestamp() throws {
        let exampleHostTime: UInt64 = 2243357893184
        let mac = getAudioDateMac(exampleHostTime)
        let ios = try getAudioDateiOS(exampleHostTime)
        XCTAssertEqual(mac, ios)
    }
    #endif
}
