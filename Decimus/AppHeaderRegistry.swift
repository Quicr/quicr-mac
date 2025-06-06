// SPDX-FileCopyrightText: Copyright (c) 2025 Cisco Systems
// SPDX-License-Identifier: BSD-2-Clause

enum AppHeaderRegistry {
    case energyLevel
    case participantId

    private var uintValue: UInt {
        switch self {
        case .energyLevel: return 6
        case .participantId: return 8
        }
    }

    var rawValue: NSNumber {
        return .init(value: uintValue)
    }

    init?(rawValue: NSNumber) {
        guard let uintValue = UInt(exactly: rawValue) else { return nil }
        switch uintValue {
        case AppHeaderRegistry.energyLevel.uintValue:
            self = .energyLevel
        case AppHeaderRegistry.participantId.uintValue:
            self = .participantId
        default:
            return nil
        }
    }
}
