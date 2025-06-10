// SPDX-FileCopyrightText: Copyright (c) 2025 Cisco Systems
// SPDX-License-Identifier: BSD-2-Clause

import SwiftUI

struct ChatView: View {
    typealias MessageToSend = (String) -> Void
    @Environment(TextSubscriptions.self) private var textSubscriptions

    @State private var toSend: String = ""
    @FocusState private var focus: Bool
    let callback: MessageToSend

    var body: some View {
        VStack {
            Text("Chat").padding().font(.title)

            // List the messages.
            if self.textSubscriptions.messages.isEmpty {
                Text("No messages yet").font(.subheadline)
            } else {
                List(self.textSubscriptions.messages) { message in
                    VStack(alignment: .leading) {
                        HStack {
                            let author = switch message.author {
                            case .me:
                                "You"
                            case .participant(let participant):
                                participant != nil ? "\(participant!.participantId)" : "Unknown"
                            }
                            Text(author)
                            Text("-")
                            Text(message.dateReceived.formatted())
                        }
                        .foregroundColor(.secondary)
                        Text(message.message)
                    }
                }
                .defaultScrollAnchor(.bottom)
            }

            Spacer()

            // Make a text entry to send messages.
            HStack(alignment: .bottom) {
                Form {
                    HStack {
                        TextField("Type a message...", text: self.$toSend)
                            .focused(self.$focus)
                            .onAppear { self.focus = true }
                        Button(action: {
                            self.submit()
                        }, label: {
                            Image(systemName: "paperplane.circle")
                        })
                    }
                    .padding()
                    .onSubmit { self.submit() }
                }
            }
        }
    }

    private func submit() {
        guard !self.toSend.isEmpty else { return }
        self.textSubscriptions.messages.append(.init(author: .me, message: self.toSend, dateReceived: .now))
        self.callback(self.toSend)
        self.toSend = ""
        self.focus = true
    }
}

#if DEBUG
private func makeSubscriptions() -> TextSubscriptions {
    let subscriptions = TextSubscriptions(sframeContext: nil)
    subscriptions.messages.append(.init(author: .participant(.init(1)),
                                        message: "Hello World",
                                        dateReceived: .now))
    subscriptions.messages.append(.init(author: .me,
                                        message: "Second Message",
                                        dateReceived: .now))
    return subscriptions
}

#Preview("Messages") {
    ChatView(callback: { print($0) })
        .environment(makeSubscriptions())
}

#endif

#Preview("No Messages") {
    ChatView(callback: { print($0) })
        .environment(TextSubscriptions(sframeContext: nil))
}
