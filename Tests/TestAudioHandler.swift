// SPDX-FileCopyrightText: Copyright (c) 2025 Cisco Systems
// SPDX-License-Identifier: BSD-2-Clause

import Testing

struct AudioHandlerTests {
    @Test("Pointer copy realloc")
    func testAudioHandler() {
        var buffer: UnsafeMutableBufferPointer<Float32>?
        buffer = UnsafeMutableBufferPointer<Float32>.allocate(capacity: 10)
        if let unwrapped = buffer {
            unwrapped.deallocate()
            buffer = .allocate(capacity: 20)
        }
        buffer?.deallocate()
    }
}
