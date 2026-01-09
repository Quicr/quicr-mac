// SPDX-FileCopyrightText: Copyright (c) 2026 Cisco Systems
// SPDX-License-Identifier: BSD-2-Clause

/// Controls whether group IDs or object IDs auto-increment after publishing an object.
enum Incrementing {
    case group
    case object
}

/// Helper for retrieving per-object defaults from a publication profile.
struct PublicationDefaults {
    let profile: Profile
    let defaultPriority: UInt8
    let defaultTTL: UInt16

    init(profile: Profile,
         defaultPriority: UInt8,
         defaultTTL: UInt16) {
        self.profile = profile
        self.defaultPriority = defaultPriority
        self.defaultTTL = defaultTTL
    }

    /// Resolve the priority for the given index or fall back to the default.
    func priority(at index: Int) -> UInt8 {
        guard let priorities = profile.priorities,
              index < priorities.count,
              priorities[index] <= UInt8.max,
              priorities[index] >= UInt8.min else {
            return self.defaultPriority
        }
        return UInt8(priorities[index])
    }

    /// Resolve the TTL for the given index or fall back to the default.
    func ttl(at index: Int) -> UInt16 {
        guard let ttls = profile.expiry,
              index < ttls.count,
              ttls[index] <= UInt16.max,
              ttls[index] >= UInt16.min else {
            return self.defaultTTL
        }
        return UInt16(ttls[index])
    }
}
