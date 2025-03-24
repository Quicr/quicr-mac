// SPDX-FileCopyrightText: Copyright (c) 2025 Cisco Systems
// SPDX-License-Identifier: BSD-2-Clause

import Synchronization
import Testing

struct MutexTests {
    private class Example {
        var value = 0
    }
    private typealias MutexCall = (borrowing Mutex<Example?>) -> Void
    private enum ClearType { case native, custom }
    private static let native: MutexCall = { $0.withLock { $0 = nil } }
    private static let custom: MutexCall = { $0.clear() }
    private static let dict: [ClearType: MutexCall] = [.native: native, .custom: custom]

    @Test("Safe Retrieval", arguments: [ClearType.native, ClearType.custom])
    private func safeRetrieval(_ call: ClearType) {
        let mutex = Mutex<Example?>(.init())
        mutex.withLock { $0!.value += 1 }

        let arcSafe = mutex.get()
        #expect(arcSafe != nil)
        #expect(arcSafe!.value == 1)

        mutex.withLock { $0!.value += 1 }
        #expect(arcSafe != nil)
        #expect(arcSafe!.value == 2)

        Self.dict[call]?(mutex)
        #expect(arcSafe != nil)
        #expect(arcSafe!.value == 2)
    }
}
