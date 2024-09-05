// SPDX-FileCopyrightText: Copyright (c) 2023 Cisco Systems
// SPDX-License-Identifier: BSD-2-Clause

/// Provides handling of names.
protocol NameGate {
    func handle(groupId: UInt64, objectId: UInt64, lastGroup: UInt64?, lastObject: UInt64?) -> Bool
}

/// A NameGate that allows anything.
class AllowAllNameGate: NameGate {
    func handle(groupId: UInt64, objectId: UInt64, lastGroup: UInt64?, lastObject: UInt64?) -> Bool {
        true
    }
}

/// A NameGate that only allows sequential object inside a group, and incrementing groups when their object == 0.
class SequentialObjectBlockingNameGate: NameGate {
    func handle(groupId: UInt64, objectId: UInt64, lastGroup: UInt64?, lastObject: UInt64?) -> Bool {
        // 0th object of a newer group can always be written.
        if (lastGroup == nil || groupId > lastGroup!) && objectId == 0 {
            return true
        }

        guard let lastObject = lastObject else {
            // If we don't have a last object, we can't write this non 0th.
            return false
        }

        // Otherwise, we write sequential objects only.
        return groupId == lastGroup && objectId == lastObject + 1
    }
}
