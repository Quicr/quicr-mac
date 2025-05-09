// SPDX-FileCopyrightText: Copyright (c) 2025 Cisco Systems
// SPDX-License-Identifier: BSD-2-Clause

import Synchronization

enum MediaState {
    case subscribed
    case received
    case rendered
}

/// Register interest in display notifications.
protocol DisplayNotification {
    typealias DisplayCallback = () -> Void
    /// Register interest in display events.
    /// - Parameter callback: Callback to fire on display.
    /// - Returns Token to be used for unregistering this callback.
    func registerDisplayCallback(_ callback: @escaping DisplayCallback) -> Int

    /// Unregister a previously registered callback.
    /// - Parameter token: Registration token identifying callback.
    func unregisterDisplayCallback(_ token: Int)

    // Get the current state of the media.
    func getMediaState() -> MediaState

    /// Fire all display callbacks.
    func fireDisplayCallbacks()
}

struct DisplayCallbacks {
    var callbacks: [Int: DisplayNotification.DisplayCallback] = [:]
    var currentToken = 0
}

extension Mutex<DisplayCallbacks> {
    func store(_ callback: @escaping DisplayNotification.DisplayCallback) -> Int {
        self.withLock { callbacks in
            let thisToken = callbacks.currentToken
            callbacks.callbacks[thisToken] = callback
            callbacks.currentToken += 1
            return thisToken
        }
    }

    func remove(_ token: Int) {
        self.withLock { _ = $0.callbacks.removeValue(forKey: token) }
    }

    func fire() {
        for callback in self.get().callbacks {
            callback.value()
        }
    }
}
