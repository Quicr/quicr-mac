// SPDX-FileCopyrightText: Copyright (c) 2023 Cisco Systems
// SPDX-License-Identifier: BSD-2-Clause

import SwiftUI
import WrappingHStack

/// View for display grid of videos
struct VideoGrid: View {
    private let maxColumns: Int = 4
    private let spacing: CGFloat = 10
    private let cornerRadius: CGFloat = 12
    let showLabels: Bool
    @Binding var connecting: Bool
    @Binding var blur: Bool
    let restrictedCount: Int?
    @State var videoParticipants: VideoParticipants
    private var participants: [VideoParticipants.Weak<VideoParticipant>] { self.videoParticipants.participants }

    private func calcColumns() -> CGFloat {
        let denom: Int
        if let restrictedCount = self.restrictedCount {
            denom = min(restrictedCount, self.participants.count)
        } else {
            denom = self.participants.count
        }
        return .init(min(maxColumns, max(1, Int(ceil(sqrt(Double(denom)))))))
    }

    private func calcRows(_ columns: CGFloat) -> CGFloat {
        let numerator: Int
        if let restrictedCount = self.restrictedCount {
            numerator = min(restrictedCount, self.participants.count)
        } else {
            numerator = self.participants.count
        }
        return .init(round(Float(numerator) / Float(columns)))
    }

    var body: some View {
        if self.participants.isEmpty {
            // Waiting for other participants / connecting.
            ZStack {
                Image("RTMC-Background")
                    .resizable()
                    .frame(maxHeight: .infinity,
                           alignment: .center)
                    .cornerRadius(self.cornerRadius)
                    .padding([.horizontal, .bottom])
                #if os(tvOS)
                .ignoresSafeArea()
                #endif
                if self.connecting {
                    ProgressView()
                        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .center)
                }
            }
        } else {
            let numColumns = self.calcColumns()
            GeometryReader { geo in
                WrappingHStack(alignment: .center) {
                    ForEach(self.participants) { participant in
                        if let participant = participant.value {
                            participant.view
                                .scaledToFill()
                                .frame(maxWidth: (geo.size.width / numColumns) - (2 * self.spacing),
                                       maxHeight: abs(geo.size.height) / self.calcRows(numColumns))
                                .cornerRadius(self.cornerRadius)
                                .conditionalModifier(self.showLabels) {
                                    $0.overlay(alignment: .bottom) {
                                        Text(participant.label)
                                            .padding(5)
                                            .foregroundColor(.black)
                                            .background(.white)
                                            .cornerRadius(self.cornerRadius)
                                            .padding(.bottom)
                                    }
                                }
                                .conditionalModifier(self.showLabels && participant.view.joinToFirstFrame != nil) {
                                    $0.overlay(alignment: .topTrailing) {
                                        VStack(alignment: .leading) {
                                            Text("From Join: \(participant.view.joinToFirstFrame!)s")
                                            Text("From Subscribe: \(participant.view.subscribeToFirstFrame!)s")
                                        }
                                        .background()
                                        .padding()
                                    }
                                }
                                .border(.green, width: participant.highlight ? 3 : 0)
                                .conditionalModifier(self.blur) {
                                    $0.blur(radius: self.cornerRadius)
                                }
                        }
                    }
                }
                .cornerRadius(cornerRadius)
                .frame(height: geo.size.height)
            }
            .frame(maxHeight: .infinity)
            .padding([.horizontal, .bottom])
            #if os(tvOS)
            .ignoresSafeArea()
            #endif
        }
    }
}

struct VideoGrid_Previews: PreviewProvider {
    static let exampleParticipants: VideoParticipants = .init()
    static var previews: some View {
        VideoGrid(showLabels: true,
                  connecting: .constant(true),
                  blur: .constant(false),
                  restrictedCount: nil,
                  videoParticipants: .init())
    }
}
