import SwiftUI

struct RadioButton<Selection>: View where Selection: Hashable {
    let label: String
    @Binding var selection: Selection
    let tag: Selection
    var body: some View {
        HStack {
            ZStack {
                if selection == tag {
                    Circle()
                        .fill(.blue.gradient)
                        .frame(width: 25, height: 25)
                    Circle()
                        .foregroundColor(Color.white)
                        .frame(width: 10, height: 10)
                } else {
                    Circle()
                        .fill(.gray.gradient)
                        .frame(width: 25, height: 25)
                }
            }
            Text(label)
                .padding(.horizontal)
                .foregroundColor(.white)
        }
        .contentShape(Rectangle())
        .onTapGesture { selection = tag }
    }
}

struct RadioButtonGroup<Selection>: View where Selection: Hashable {
    private let label: String
    @Binding private var selection: Selection
    private let tags: [Selection]
    private let labels: [String]

    init(_ label: String, selection: Binding<Selection>, tags: [Selection]) {
        self.label = label
        _selection = selection
        self.tags = tags
        self.labels = []
    }

    init(_ label: String, selection: Binding<Selection>, labels: [String], tags: [Selection]) {
        self.label = label
        _selection = selection
        self.tags = tags
        self.labels = labels
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(self.label)
                .padding(.horizontal)
                .foregroundColor(.white)
            Divider()
                .padding()
                .frame(maxHeight: 1)
                .overlay(Color.gray)
            HStack {
                ForEach(tags, id: \.self) { tag in
                    RadioButton<Selection>(label: labels.isEmpty ?
                                            String(describing: tag) :
                                            labels[tags.firstIndex(of: tag) ?? 0],
                                           selection: $selection, tag: tag)
                }
            }
            .padding([.horizontal, .top])
        }
    }
}
