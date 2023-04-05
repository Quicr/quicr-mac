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

struct ActionPicker<Content>: View where Content: View {
    private let label: String
    private let icon: String
    private let action: () -> Void
    private let pickerAction: () -> Void
    private let content: () -> Content

    @Binding private var expanded: Bool

    init(_ label: String,
         icon: String,
         expanded: Binding<Bool>,
         action: @escaping () -> Void,
         pickerAction: @escaping () -> Void,
         @ViewBuilder content: @escaping () -> Content) {
        self.label = label
        self.icon = icon
        self.action = action
        self.pickerAction = pickerAction
        self.content = content
        self._expanded = expanded
    }

    init(_ label: String,
         icon: String,
         expanded: Binding<Bool>,
         action: @escaping () -> Void,
         @ViewBuilder content: @escaping () -> Content) {
        self.init(label,
                  icon: icon,
                  expanded: expanded,
                  action: action,
                  pickerAction: { expanded.wrappedValue.toggle() },
                  content: content)
    }

    init(_ label: String,
         icon: String,
         expanded: Binding<Bool>,
         action: @escaping () async -> Void,
         @ViewBuilder content: @escaping () -> Content) {
        self.init(label,
                  icon: icon,
                  expanded: expanded,
                  action: { Task { await action() }},
                  content: content)
    }

    init(_ label: String,
         icon: String,
         expanded: Binding<Bool>,
         action: @escaping () async -> Void,
         pickerAction: @escaping () async -> Void,
         @ViewBuilder content: @escaping () -> Content) {
        self.init(label,
                  icon: icon,
                  expanded: expanded,
                  action: { Task { await action() }},
                  pickerAction: { Task { await pickerAction() }},
                  content: content)
    }

    var body: some View {
        ZStack(alignment: .center) {
            ActionButton(styleConfig: ActionButtonStyleConfig(background: .black,
                                                              foreground: .white,
                                                              borderColour: .gray),
                         action: action) {
                HStack(alignment: .center) {
                    Image(systemName: icon)
                    Text(label)
                        .font(Font.system(size: 19, weight: .semibold))
                        .frame(alignment: .center)
                        .padding(.leading)
                    Spacer()
                }
            }
            HStack {
                Spacer().frame(maxWidth: .infinity)
                Button(action: { withAnimation(.spring()) { pickerAction() }},
                       label: {
                    Image(systemName: expanded ? "chevron.up" : "chevron.down")
                        .renderingMode(.original)
                        .foregroundColor(.white)
                        .frame(alignment: .trailing)
                        .padding()
                })
                .frame(alignment: .trailing)
                .background(.black)
                .cornerRadius(30)
            }
        }
        .float(above: MenuModal(presented: $expanded, content: content).padding(.bottom))
    }
}
