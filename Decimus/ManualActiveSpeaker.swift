// SPDX-FileCopyrightText: Copyright (c) 2023 Cisco Systems
// SPDX-License-Identifier: BSD-2-Clause

import OrderedCollections

/// Allows manual triggering of active speakers.
class ManualActiveSpeaker: ActiveSpeakerNotifier {
    private var callbacks: [CallbackToken: ActiveSpeakersChanged] = [:]
    private var token = 0

    func setActiveSpeakers(_ speakers: OrderedSet<ParticipantId>) {
        for callback in self.callbacks.values {
            callback(speakers)
        }
    }

    func registerActiveSpeakerCallback(_ callback: @escaping ActiveSpeakersChanged) -> CallbackToken {
        let token = self.token
        self.token += 1
        self.callbacks[token] = callback
        return token
    }

    func unregisterActiveSpeakerCallback(_ token: CallbackToken) {
        self.callbacks.removeValue(forKey: token)
    }
}
