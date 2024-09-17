// SPDX-FileCopyrightText: Copyright (c) 2023 Cisco Systems
// SPDX-License-Identifier: BSD-2-Clause

import SwiftUI

struct URLField: View {

    let name: String
    @Binding var url: URL

    var body: some View {
        TextField(
            self.name,
            text: Binding(
                get: {
                    self.url.absoluteString
                },
                set: {
                    self.url = .init(string: $0) ?? self.url
                }))
            .keyboardType(.URL)
            .textContentType(.URL)
            .autocorrectionDisabled(true)
            .textInputAutocapitalization(.never)
    }
}

#Preview {
    Form {
        LabeledContent("URL") {
            URLField(name: "Preview",
                     url: .constant(.init(string: "http://example.org")!))
        }
    }
}
