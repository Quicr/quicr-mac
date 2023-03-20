import SwiftUI

struct ActionButtonStyleConfig {
    let background: Color?
    let foreground: Color?
    let borderColour: Color?
    let hoverColour: Color?

    init(background: Color? = nil, foreground: Color? = nil, borderColour: Color? = nil, hoverColour: Color? = nil) {
        self.background = background
        self.foreground = foreground
        self.borderColour = borderColour
        self.hoverColour = hoverColour
    }
}

struct ActionButtonStyle: ButtonStyle {
    private let colours: ActionButtonStyleConfig
    private let cornerRadius: CGFloat
    private let isDisabled: Bool

    @State private var borderColour: Color
    @State private var borderSize: CGFloat

    init(colours: ActionButtonStyleConfig, cornerRadius: CGFloat, isDisabled: Bool) {
        self.colours = colours
        self.cornerRadius = cornerRadius
        self.isDisabled = isDisabled

        borderColour = colours.borderColour ?? .clear
        borderSize = colours.borderColour != nil || colours.hoverColour != nil ? 1 : 0
    }

    func makeBody(configuration: Self.Configuration) -> some View {
        let foregroundColour = (colours.foreground ?? Color.white).opacity(
            isDisabled || configuration.isPressed ? 0.3 : 1)
        let backgroundColour = (colours.background ?? Color.black).opacity(
            isDisabled || configuration.isPressed ? 0.3 : 1)

        return configuration.label
            .padding()
            .foregroundColor(foregroundColour)
            .background(backgroundColour)
            .cornerRadius(cornerRadius)
            .overlay(
                RoundedRectangle(cornerRadius: cornerRadius)
                    .stroke(borderColour, lineWidth: borderSize)
                    .hoverEffect(.highlight)
            )
            .onHover { hovered in
                borderColour = (hovered ? colours.hoverColour : colours.borderColour) ?? colours.borderColour ?? .clear
            }
    }
}

struct ActionButton<Content>: View where Content: View {
    private let colours: ActionButtonStyleConfig

    @ViewBuilder private let title: Content
    private let action: () -> Void
    private let disabled: Bool
    private let cornerRadius: CGFloat

    init(disabled: Bool = false,
         cornerRadius: CGFloat = 30,
         colours: ActionButtonStyleConfig,
         action: @escaping () -> Void,
         @ViewBuilder title: @escaping () -> Content) {
        self.colours = colours
        self.title = title()
        self.action = action
        self.disabled = disabled
        self.cornerRadius = cornerRadius
    }

    init(disabled: Bool = false,
         cornerRadius: CGFloat = 30,
         colours: ActionButtonStyleConfig,
         action: @escaping () async -> Void,
         @ViewBuilder title: @escaping () -> Content) {
        self.init(disabled: disabled,
                  cornerRadius: cornerRadius,
                  colours: colours,
                  action: { Task { await action() }},
                  title: title)
    }

    var body: some View {
        HStack {
            Button(action: self.action) {
                self.title.frame(maxWidth: .infinity)
            }
            .buttonStyle(ActionButtonStyle(
                colours: self.colours,
                cornerRadius: self.cornerRadius,
                isDisabled: disabled))
            .disabled(self.disabled)
        }
    }
}

extension ActionButton where Content == Text {
    init(_ title: String,
         font: Font?,
         disabled: Bool = false,
         cornerRadius: CGFloat = 30,
         colours: ActionButtonStyleConfig,
         action: @escaping () -> Void) {
        self.init(disabled: disabled, cornerRadius: cornerRadius, colours: colours, action: action) {
            Text(verbatim: title).font(font)
        }
    }

    init(_ title: String,
         disabled: Bool = false,
         cornerRadius: CGFloat = 30,
         colours: ActionButtonStyleConfig,
         action: @escaping () -> Void) {
        self.init(title, font: nil, disabled: disabled, cornerRadius: cornerRadius, colours: colours, action: action)
    }
}
