import SwiftUI

struct ActionPicker<SelectionValue, Content>: View where SelectionValue: Hashable, Content: View {
    private let label: String
    private let icon: String
    private let input: Binding<SelectionValue>
    private let action: () -> Void
    private let content: () -> Content

    init(_ label: String,
         icon: String,
         input: Binding<SelectionValue>,
         action: @escaping () -> Void,
         @ViewBuilder content: @escaping () -> Content) {
        self.label = label
        self.icon = icon
        self.input = input
        self.action = action
        self.content = content
    }

    var body: some View {
        ActionButton(colours: StyleColours(background: .black, foreground: .white), action: action) {
            HStack {
                Image(systemName: icon)
                Text(label).frame(maxWidth: .infinity)
                Menu(content: content) {
                    Image(systemName: "chevron.down")
                        .renderingMode(.original)
                        .foregroundColor(.white)
                }
                .frame(alignment: .trailing)
            }
        }
    }
}
