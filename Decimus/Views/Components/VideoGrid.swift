import SwiftUI

/// View for display grid of videos
struct VideoGrid: View {
    private let maxColumns: Int = 4
    private let spacing: CGFloat = 10

    @StateObject private var participants: VideoParticipants

    init(participants: VideoParticipants) {
        _participants = StateObject(wrappedValue: participants)
    }

    private func calcColumns() -> CGFloat {
        return .init(min(maxColumns, max(1, Int(ceil(sqrt(Double(participants.participants.values.count)))))))
    }

    private func calcRows(_ columns: CGFloat) -> CGFloat {
        return .init(round(Float(Array(participants.participants.values).count) / Float(columns)))
    }

    var body: some View {
        GeometryReader { geo in
            let numColumns = calcColumns()
            let numRows = calcRows(numColumns)

            let width = (geo.size.width) / numColumns
            let height = abs(geo.size.height) / numRows
            let columns = Array(repeating: GridItem(.adaptive(minimum: width, maximum: width)),
                                count: Int(numColumns))

            LazyVGrid(columns: columns, spacing: spacing) {
                ForEach(Array(participants.participants.values)) { participant in
                    participant.view
                        .scaledToFit()
                        .cornerRadius(12)
                        .frame(maxHeight: height)
                }
            }
            .cornerRadius(12)
            .frame(height: geo.size.height)
        }
        .frame(maxHeight: .infinity)
        .padding([.horizontal, .top])
    }
}

struct VideoGrid_Previews: PreviewProvider {
    static let exampleParticipants: VideoParticipants = .init()
    init() {
        _ = VideoGrid_Previews.exampleParticipants.getOrMake(identifier: "1")
        _ = VideoGrid_Previews.exampleParticipants.getOrMake(identifier: "2")
    }
    static var previews: some View {
        VideoGrid(participants: exampleParticipants)
    }
}
