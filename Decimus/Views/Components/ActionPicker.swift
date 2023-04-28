import SwiftUI

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
        HStack(spacing: 0) {
            Button(action: action) {
                HStack(alignment: .center) {
                    Image(systemName: icon)
                        .foregroundColor(.white)
                    Text(label)
                        .font(.body).bold()
                        .frame(alignment: .center)
                        .foregroundColor(.white)
                        .lineLimit(1)
                }
                .padding()
            }
            .background(.black)
            .cornerRadius(30, corners: [.topLeft, .bottomLeft])
            Button(action: pickerAction) {
                Image(systemName: "chevron.\(expanded ? "up" : "down")")
                    .renderingMode(.original)
                    .foregroundColor(.white)
                    .frame(alignment: .trailing)
                    .padding(.trailing)
                    .padding(.vertical, 22)
            }
            .background(.black)
            .cornerRadius(20, corners: [.topRight, .bottomRight])
        }
        .overlay(RoundedRectangle(cornerRadius: 30).stroke(.white, lineWidth: 1))
#if targetEnvironment(macCatalyst)
        .float(above: MenuModal(presented: $expanded, content: content)
            .padding(.bottom))
#else
        .sheet(isPresented: $expanded) {
            MenuModal(presented: $expanded, content: content)
        }
#endif
    }
}
