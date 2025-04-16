// SPDX-FileCopyrightText: Copyright (c) 2025 Cisco Systems
// SPDX-License-Identifier: BSD-2-Clause

import SwiftUI

struct ChannelRepresentation {
    let name: String
    let icon: Image
}

struct ChannelBlock: View {
    let channel: ChannelRepresentation

    var body: some View {
        ZStack {
            RoundedRectangle(cornerRadius: 10)
            VStack {
                HStack {
                    self.channel.icon
                    Text(self.channel.name)
                }

                Divider()
            }
        }
    }
}

#Preview {
    let repr = ChannelRepresentation(name: "Gardening",
                                     icon: Image(systemName: "leaf"))
    ChannelBlock(channel: repr)
}
