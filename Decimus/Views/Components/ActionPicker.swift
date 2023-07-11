import SwiftUI

struct MenuModal<Content>: View where Content: View {
    @Binding var presented: Bool
    @ViewBuilder let content: () -> Content

    var body: some View {
        if presented {
            VStack(alignment: .leading, content: self.content)
            .frame(maxWidth: .infinity)
            .padding()
            .background(.black)
            .cornerRadius(20)
            .overlay(RoundedRectangle(cornerRadius: 20)
                .stroke(.gray, lineWidth: 1)
            )
        }
    }
}

struct ActionPicker<Content>: View where Content: View {
    private let label: String
    private let icon: String
    private let action: () -> Void
    private let pickerAction: () -> Void
    private let content: () -> Content
    private let role: ButtonRole?

    @State var isDisabled: Bool = false

    @Binding private var expanded: Bool

    init(_ label: String,
         icon: String,
         role: ButtonRole? = nil,
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
        self.role = role
    }

    init(_ label: String,
         icon: String,
         role: ButtonRole? = nil,
         expanded: Binding<Bool>,
         action: @escaping () -> Void,
         @ViewBuilder content: @escaping () -> Content) {
        self.init(label,
                  icon: icon,
                  role: role,
                  expanded: expanded,
                  action: action,
                  pickerAction: { expanded.wrappedValue.toggle() },
                  content: content)
    }

    init(_ label: String,
         icon: String,
         role: ButtonRole? = nil,
         expanded: Binding<Bool>,
         action: @escaping () async -> Void,
         @ViewBuilder content: @escaping () -> Content) {
        self.init(label,
                  icon: icon,
                  role: role,
                  expanded: expanded,
                  action: { Task { await action() }},
                  content: content)
    }

    init(_ label: String,
         icon: String,
         role: ButtonRole? = nil,
         expanded: Binding<Bool>,
         action: @escaping () async -> Void,
         pickerAction: @escaping () async -> Void,
         @ViewBuilder content: @escaping () -> Content) {
        self.init(label,
                  icon: icon,
                  role: role,
                  expanded: expanded,
                  action: { Task { await action() }},
                  pickerAction: { Task { await pickerAction() }},
                  content: content)
    }

    var body: some View {
        HStack(alignment: .center, spacing: 0) {
            Button(action: action) {
                HStack(alignment: .center) {
                    Image(icon)
                        .renderingMode(.template)
                        .resizable()
                        .foregroundColor(role == .destructive ? .red : .white)
                        .frame(width: 20, height: 20)
                    Text(label)
                        .font(.custom("CiscoSansTTRegular", size: 16))
                        .frame(alignment: .center)
                        .foregroundColor(.white)
                        .lineLimit(1)
                }
                .padding()
            }
            .disabled(isDisabled)
            .background(.black)
            .cornerRadius(30, corners: [.topLeft, .bottomLeft])

//            Button(action: pickerAction) {
//                Image(systemName: "chevron.\(expanded ? "up" : "down")")
//                    .renderingMode(.original)
//                    .foregroundColor(.white)
//                    .frame(alignment: .trailing)
//                    .padding(.trailing)
//                    .padding(.vertical, 22)
//            }
//            .disabled(isDisabled)
//            .background(.black)
//            .cornerRadius(20, corners: [.topRight, .bottomRight])
        }
        .overlay(RoundedRectangle(cornerRadius: 30).stroke(.gray, lineWidth: 1))
#if targetEnvironment(macCatalyst)
        .float(above: MenuModal(presented: $expanded, content: content)
            .padding(.bottom))
#else
        .sheet(isPresented: $expanded, content: {
            ScrollView {
                content()
            }
            .padding()
            .presentationDetents([.medium])
        })
#endif
    }
}

extension ActionPicker {
    func disabled(_ disabled: Bool) -> Self {
        self.isDisabled = isDisabled
        return self
    }
}
