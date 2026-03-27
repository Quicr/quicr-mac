// SPDX-FileCopyrightText: Copyright (c) 2026 Cisco Systems
// SPDX-License-Identifier: BSD-2-Clause

/// Detects transitions in the audio activity state machine output
/// and signals when video should roll group (keyframe) or subgroup.
///
/// Upward transitions (activity increased) → rollGroup (triggers keyframe,
/// preparing for potential switch-in by the relay's top-N filter).
///
/// Downward transitions (activity decreased) → rollSubgroup (so the relay
/// can see the value change at subgroup boundaries).
struct VideoVADTransition {
    struct Result {
        let value: AudioActivityValue
        let rollGroup: Bool
        let rollSubgroup: Bool
    }

    private var committed: AudioActivityValue = .speechEnd

    /// Process a new state machine value. Returns the value to embed in headers
    /// along with whether to roll group or subgroup.
    ///
    /// Comparisons use raw value ordering (speechEnd=0, continuousSpeech=1, speechStart=2).
    /// This matches the relay's ranking — speechStart is highest because we want new
    /// speakers to outrank continuous speakers. The only keyframe-worthy transition is
    /// speechEnd → speechStart (raw value increase), when we go from silent to talking.
    mutating func update(_ value: AudioActivityValue) -> Result {
        if value > committed {
            committed = value
            return Result(value: value, rollGroup: true, rollSubgroup: false)
        }
        if value < committed {
            committed = value
            return Result(value: value, rollGroup: false, rollSubgroup: true)
        }
        return Result(value: value, rollGroup: false, rollSubgroup: false)
    }
}
