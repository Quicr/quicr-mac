import SwiftUI

private struct Above<AboveContent: View>: ViewModifier {
    let aboveContent: AboveContent

    func body(content: Content) -> some View {
        content.overlay(
            GeometryReader { proxy in
                Rectangle().fill(.clear).overlay(
                    self.aboveContent.offset(x: 0, y: -proxy.size.height),
                    alignment: .bottomTrailing
                )
            },
            alignment: .bottomTrailing
        )
    }
}

private extension View {
    func float<Content: View>(above: Content) -> ModifiedContent<Self, Above<Content>> {
        self.modifier(Above(aboveContent: above))
    }
}

struct MenuModal<Content>: View where Content: View {
    private let presented: Binding<Bool>
    @ViewBuilder private let content: () -> Content

    init(presented: Binding<Bool>, @ViewBuilder content: @escaping () -> Content) {
        self.presented = presented
        self.content = content
    }

    var body: some View {
        ZStack {
            if presented.wrappedValue {
                RoundedRectangle(cornerRadius: 20)
                    .stroke(.gray, lineWidth: 1)
                    .background(.black)

                VStack(alignment: .leading) {
                    self.content()
                }
                .padding()
            }
        }
        .cornerRadius(20)
        .frame(maxWidth: .infinity)
    }
}

struct ActionPicker<SelectionValue, Content>: View where SelectionValue: Hashable, Content: View {
    private let label: String
    private let icon: String
    private let input: Binding<SelectionValue>
    private let action: () -> Void
    private let content: () -> Content

    @State private var expanded: Bool = false

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

    init(_ label: String,
         icon: String,
         input: Binding<SelectionValue>,
         action: @escaping () async -> Void,
         @ViewBuilder content: @escaping () -> Content) {
        self.init(label,
                  icon: icon,
                  input: input,
                  action: { Task { await action() }},
                  content: content)
    }

    var body: some View {
        ZStack(alignment: .center) {
            ActionButton(colours: ActionButtonStyleConfig(background: .black,
                                                          foreground: .white,
                                                          borderColour: .gray),
                         action: action) {
                HStack {
                    Image(systemName: icon)
                    Text(label).frame(maxWidth: .infinity)
                    Spacer()
                }
            }
            HStack {
                Spacer().frame(maxWidth: .infinity)
                Button(action: { withAnimation(.spring()) { expanded.toggle() }},
                       label: {
                    Image(systemName: expanded ? "chevron.up" : "chevron.down")
                        .renderingMode(.original)
                        .foregroundColor(.white)
                        .frame(alignment: .trailing)
                })
                .frame(alignment: .trailing)
                .padding(.trailing, 20)
            }
        }
        .font(Font.system(size: 19, weight: .semibold))
        .float(above: MenuModal(presented: $expanded, content: content))
    }
}
