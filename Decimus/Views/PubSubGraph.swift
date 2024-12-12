// SPDX-FileCopyrightText: Copyright (c) 2023 Cisco Systems
// SPDX-License-Identifier: BSD-2-Clause

import SwiftUI
import Grape

struct PubSubGraphState {
    let me: ParticipantId
    let relay: String
    let subscriptions: [SubscriptionSet]
    let publications: [String]
}

struct PubSubGraph: View {
    @State private var graph = ForceDirectedGraphState()
    @State private var state: PubSubGraphState

    init(_ state: PubSubGraphState) {
        self.state = state
    }

    var body: some View {
        ForceDirectedGraph(states: self.graph) {
            let me = "\(self.state.me)"
            // We exist.
            NodeMark(id: me)
                .label(Text("Me"), alignment: .center, offset: .zero)

            // Our relay exists.
            NodeMark(id: self.state.relay)
                .label(Text(self.state.relay), alignment: .center, offset: .zero)

            // Connect publications from us to the relay.
            Series(self.state.publications) {
                NodeMark(id: $0)
                    .label(Text($0), alignment: .center, offset: .zero)
                    .foregroundStyle(.blue)
                LinkMark(from: $0, to: self.state.relay)
                    .foregroundStyle(.blue)
                LinkMark(from: me, to: $0)
                    .foregroundStyle(.blue)
            }

            //            // Connect subscriptions from the relay to us.
            //            Series(self.state.subscriptions) { set in
            //                Series(Array(set.getHandlers().keys)) {
            //                    if let identifiable = $0.toUTF8() {
            //                        // Is this a mirror?
            //                        LinkMark(from: self.state.relay, to: me)
            //                    }
            //                }
            //            }

            //            let setParticipants = Set(self.state.subscriptions.map { $0.participantId })
            //            Series(Array(setParticipants)) {
            //                let part = "\($0)"
            //                NodeMark(id: part)
            //                    .label(Text(part), alignment: .center, offset: .zero)
            //            }
            //
            //            // Our subscriptions, from the relay to us.
            //            Series(self.state.subscriptions) { set in
            //                // Nodes for the set.
            //                NodeMark(id: set.sourceId)
            //                    .label(Text(set.sourceId), alignment: .center, offset: .zero)
            //                LinkMark(from: set.sourceId, to: self.state.relay)
            //
            //                // Nodes for actuals subscriptions.
            //                let participant = "\(set.participantId)"
            //                Series(Array(set.getHandlers().keys)) {
            //                    if let identifiable = $0.toUTF8() {
            //                        // Is this a mirror?
            //                        if self.state.publications.contains(identifiable) {
            //                            let id = "\(identifiable)-mirror"
            //                            NodeMark(id: id)
            //                                .foregroundStyle(.pink)
            //                            LinkMark(from: id, to: set.sourceId)
            //                            // TODO: Why is the participant different in the manifest?
            //                            LinkMark(from: id, to: "\(self.state.me)")
            //                        } else {
            //                            NodeMark(id: identifiable)
            //                            LinkMark(from: identifiable, to: set.sourceId)
            //                            LinkMark(from: identifiable, to: participant)
            //                        }
            //                    }
            //                }
            //            }
        } force: {
            LinkForce()
            CenterForce()
            ManyBodyForce()
        }
    }

    // @ViewBuilder
    private func setView(subscriptionSet: SubscriptionSet) -> some GraphContent {
        NodeMark(id: "hi")
    }
}
