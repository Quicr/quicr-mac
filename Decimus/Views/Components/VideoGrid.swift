// SPDX-FileCopyrightText: Copyright (c) 2023 Cisco Systems
// SPDX-License-Identifier: BSD-2-Clause

import SwiftUI
import WrappingHStack

/// View for display grid of videos
struct VideoGrid: View {
    private let maxColumns: Int = 4
    private let spacing: CGFloat = 10
    private let cornerRadius: CGFloat = 12

    @StateObject private var videoParticipants: VideoParticipants
    private var participants: [VideoParticipant] {
        return Array(videoParticipants.participants.values)
    }

    init(participants: VideoParticipants) {
        _videoParticipants = StateObject(wrappedValue: participants)
    }

    private func calcColumns() -> CGFloat {
        return .init(min(maxColumns, max(1, Int(ceil(sqrt(Double(participants.count)))))))
    }

    private func calcRows(_ columns: CGFloat) -> CGFloat {
        return .init(round(Float(participants.count) / Float(columns)))
    }

    var body: some View {
        let numColumns = calcColumns()
        GeometryReader { geo in
            WrappingHStack(alignment: .center) {
                ForEach(participants) { participant in
                    participant.view
                        .scaledToFill()
                        .frame(maxWidth: (geo.size.width / numColumns) - (2 * spacing),
                               maxHeight: abs(geo.size.height) / calcRows(numColumns))
                        .cornerRadius(cornerRadius)
                        .overlay(alignment: .bottom) {
                            Text(participant.label)
                                .padding(5)
                                .foregroundColor(.black)
                                .background(.white)
                                .cornerRadius(12)
                                .padding(.bottom)
                        }
                        .border(.green, width: participant.highlight ? 3 : 0)
                }
            }
            .cornerRadius(cornerRadius)
            .frame(height: geo.size.height)
        }
        .frame(maxHeight: .infinity)
        .padding([.horizontal, .bottom])
    }
}

struct VideoGrid_Previews: PreviewProvider {
    static let exampleParticipants: VideoParticipants = .init()
    static var previews: some View {
        VideoGrid(participants: exampleParticipants)
    }
}
