// SPDX-FileCopyrightText: Copyright (c) 2023 Cisco Systems
// SPDX-License-Identifier: BSD-2-Clause

import SwiftUI

struct LabeledToggle: View {
    private let title: String
    private let isOn: Binding<Bool>

    init(_ title: String, isOn: Binding<Bool>) {
        self.title = title
        self.isOn = isOn
    }

    var body: some View {
        #if os(macOS)
        LabeledContent(self.title) {
            Toggle(self.title, isOn: self.isOn)
                .labelsHidden()
        }
        #else
        HStack {
            Text(self.title)
            Toggle(isOn: self.isOn) {}
        }
        #endif
    }
}

struct LabeledToggle_Previews: PreviewProvider {
    @State private static var value: Bool = false

    static var previews: some View {

        LabeledToggle("Title",
                      isOn: Self.$value)
            .padding()
    }
}
