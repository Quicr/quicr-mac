// SPDX-FileCopyrightText: Copyright (c) 2023 Cisco Systems
// SPDX-License-Identifier: BSD-2-Clause

import SwiftUI

struct PublicationPopover: View {
    private let controller: MoqCallController

    init(_ controller: MoqCallController) {
        self.controller = controller
    }

    var body: some View {
        Text("Publications")
            .font(.title)
    }
}
