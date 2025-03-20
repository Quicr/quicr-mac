// SPDX-FileCopyrightText: Copyright (c) 2025 Cisco Systems
// SPDX-License-Identifier: BSD-2-Clause

import SwiftUI

struct PushToTalkButton: View {
    let title: String
    let start: () -> Void
    let end: () -> Void
    @State private var started = false

    init(_ title: String, start: @escaping () -> Void, end: @escaping () -> Void) {
        self.title = title
        self.start = start
        self.end = end
    }

    var body: some View {
        ZStack {
            if self.started {
                Circle()
                    .foregroundStyle(.foreground)
            } else {
                Circle()
                    .foregroundStyle(.background)
            }
            Text(self.title)
                .foregroundStyle(.primary)
                .font(.title)
        }
        .gesture(DragGesture(minimumDistance: 0)
                    .onChanged { _ in
                        guard !self.started else { return }
                        self.started = true
                        self.start()
                    }
                    .onEnded { _ in
                        assert(self.started)
                        self.started = false
                        self.end()
                    })
    }
}

#Preview {
    let start: () -> Void = { print("Start") }
    let end: () -> Void = { print("Start") }
    PushToTalkButton("Button", start: start, end: end)
}
