// SPDX-FileCopyrightText: Copyright (c) 2023 Cisco Systems
// SPDX-License-Identifier: BSD-2-Clause

// https://forums.swift.org/t/rawrepresentable-conformance-leads-to-crash/51912/3

import Foundation

struct AppSetting<Value> {
    let key: String
    let defaultValue: Value
}

enum VADTuningProfile: String, CaseIterable, Identifiable {
    case current
    case new
    case custom

    var id: Self { self }

    var label: String {
        switch self {
        case .current: "Current"
        case .new: "New"
        case .custom: "Custom"
        }
    }

    var values: Values? {
        switch self {
        case .current:
            .init(timeToSpeechStart: 0.15,
                  timeToContinuous: 0.5,
                  timeToDropStart: 0.25,
                  timeToDropContinuous: 0.6,
                  vadAggressiveness: 3)
        case .new:
            .init(timeToSpeechStart: 0.3,
                  timeToContinuous: 0.5,
                  timeToDropStart: 0.25,
                  timeToDropContinuous: 1.0,
                  vadAggressiveness: 2)
        case .custom:
            nil
        }
    }

    struct Values: Equatable {
        let timeToSpeechStart: TimeInterval
        let timeToContinuous: TimeInterval
        let timeToDropStart: TimeInterval
        let timeToDropContinuous: TimeInterval
        let vadAggressiveness: Int
    }
}

enum AppSettings {
    static let verbose = AppSetting(key: "verbose", defaultValue: false)
    static let recording = AppSetting(key: "recordCall", defaultValue: false)
    static let mediaInterop = AppSetting(key: "mediaInterop", defaultValue: false)
    static let useOverrideNamespace = AppSetting(key: "useOverrideNamespace", defaultValue: false)
    static let overrideNamespace = AppSetting(
        key: "overrideNamespace",
        defaultValue: "[\"moq://decimus.webex.com/v1/\", \"media-interop\", \"{s}\"]")
    static let subscribeNamespaceEnabled = AppSetting(key: "subscribeNamespaceEnabled", defaultValue: false)
    static let subscribeNamespace = AppSetting(
        key: "subscribeNamespace",
        defaultValue: "[\"moq://decimus.webex.com/v1/\"]")
    static let subscribeNamespaceAccept = AppSetting(
        key: "subscribeNamespaceAccept",
        defaultValue: "[\"moq://decimus.webex.com/v1/\", \"media-interop\"]")
    static let moqRole = AppSetting(key: "moqRole", defaultValue: MoQRole.both)
    static let appExtensionMode = AppSetting(key: "appExtensionMode", defaultValue: AppExtensionMode.mutable)
    static let demoEnabled = AppSetting(key: "demoEnabled", defaultValue: false)
    static let demoMeetingId = AppSetting(key: "demoMeetingId", defaultValue: "demo-meeting-1")
    static let demoMaxTracksSelected = AppSetting(key: "demoMaxTracksSelected", defaultValue: 2)
    static let demoTimeout = AppSetting(key: "demoMaxTimeSelected", defaultValue: TimeInterval(0.5))
    static let demoTimeToSpeechStart = AppSetting(key: "demoTimeToSpeechStart", defaultValue: TimeInterval(0.15))
    static let demoTimeToContinuous = AppSetting(key: "demoTimeToContinuous", defaultValue: TimeInterval(0.5))
    static let demoTimeToDropStart = AppSetting(key: "demoTimeToDropStart", defaultValue: TimeInterval(0.25))
    static let demoTimeToDropContinuous = AppSetting(key: "demoTimeToDropContinuous", defaultValue: TimeInterval(0.6))
    static let demoVadRollSubgroup = AppSetting(key: "demoVadRollSubgroup", defaultValue: false)
    static let demoVadAggressiveness = AppSetting(key: "demoVadAggressiveness", defaultValue: 3)
}

struct AppStorageWrapper<Value: Codable> {
    var value: Value
}

extension AppStorageWrapper: RawRepresentable {

    typealias RawValue = String

    var rawValue: RawValue {
        guard
            let data = try? JSONEncoder().encode(value),
            let string = String(data: data, encoding: .utf8)
        else {
            return ""
        }
        return string
    }

    init?(rawValue: RawValue) {
        guard
            let data = rawValue.data(using: .utf8),
            let decoded = try? JSONDecoder().decode(Value.self, from: data)
        else {
            return nil
        }
        value = decoded
    }
}
