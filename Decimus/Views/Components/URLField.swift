// SPDX-FileCopyrightText: Copyright (c) 2023 Cisco Systems
// SPDX-License-Identifier: BSD-2-Clause

import SwiftUI

struct URLField: View {

    let name: String
    let validation: ((URL) -> String?)?
    @Binding var url: URL
    @State private var error: String?

    var body: some View {
        VStack {
            TextField(
                self.name,
                text: Binding(
                    get: {
                        self.url.absoluteString
                    },
                    set: {
                        guard let url = URL(string: $0) else {
                            self.error = "Invalid URL"
                            return
                        }
                        if let validation = self.validation,
                           let error = validation(url) {
                            self.error = error
                            return
                        }
                        self.error = nil
                        self.url = url
                    }))
                .keyboardType(.URL)
                .textContentType(.URL)
                .autocorrectionDisabled(true)
                .textInputAutocapitalization(.never)

            if let error = self.error {
                HStack {
                    Text(error).foregroundStyle(.red)
                    Spacer()
                }
            }
        }
    }
}

#Preview {
    Form {
        LabeledContent("URL") {
            URLField(name: "Preview",
                     validation: nil,
                     url: .constant(.init(string: "http://example.org")!))
        }
    }
}
