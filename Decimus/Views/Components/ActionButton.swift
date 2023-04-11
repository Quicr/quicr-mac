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
    private let styleConfig: ActionButtonStyleConfig
    private let cornerRadius: CGFloat
    private let isDisabled: Bool

    @State private var borderColour: Color
    @State private var borderSize: CGFloat

    init(styleConfig: ActionButtonStyleConfig, cornerRadius: CGFloat, isDisabled: Bool) {
        self.styleConfig = styleConfig
        self.cornerRadius = cornerRadius
        self.isDisabled = isDisabled

        borderColour = styleConfig.borderColour ?? .clear
        borderSize = styleConfig.borderColour != nil || styleConfig.hoverColour != nil ? 1 : 0
    }

    func makeBody(configuration: Self.Configuration) -> some View {
        let foregroundColour = (styleConfig.foreground ?? Color.white).opacity(
            isDisabled || configuration.isPressed ? 0.3 : 1)
        let backgroundColour = (styleConfig.background ?? Color.black).opacity(
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
                borderColour = (hovered ? styleConfig.hoverColour : styleConfig.borderColour) ??
                                                                    styleConfig.borderColour ?? .clear
            }
    }
}

struct ActionButton<Content>: View where Content: View {
    private let styleConfig: ActionButtonStyleConfig

    @ViewBuilder private let title: Content
    private let action: () -> Void
    private let disabled: Bool
    private let cornerRadius: CGFloat

    init(disabled: Bool = false,
         cornerRadius: CGFloat = 30,
         styleConfig: ActionButtonStyleConfig,
         action: @escaping () -> Void,
         @ViewBuilder title: @escaping () -> Content) {
        self.styleConfig = styleConfig
        self.title = title()
        self.action = action
        self.disabled = disabled
        self.cornerRadius = cornerRadius
    }

    init(disabled: Bool = false,
         cornerRadius: CGFloat = 30,
         styleConfig: ActionButtonStyleConfig,
         action: @escaping () async -> Void,
         @ViewBuilder title: @escaping () -> Content) {
        self.init(disabled: disabled,
                  cornerRadius: cornerRadius,
                  styleConfig: styleConfig,
                  action: { Task { await action() }},
                  title: title)
    }

    var body: some View {
        HStack {
            Button(action: self.action) {
                self.title.frame(maxWidth: .infinity)
            }
            .buttonStyle(ActionButtonStyle(
                styleConfig: self.styleConfig,
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
         styleConfig: ActionButtonStyleConfig,
         action: @escaping () -> Void) {
        self.init(disabled: disabled, cornerRadius: cornerRadius, styleConfig: styleConfig, action: action) {
            Text(verbatim: title).font(font)
        }
    }

    init(_ title: String,
         disabled: Bool = false,
         cornerRadius: CGFloat = 30,
         styleConfig: ActionButtonStyleConfig,
         action: @escaping () -> Void) {
        self.init(title,
                  font: nil,
                  disabled: disabled,
                  cornerRadius: cornerRadius,
                  styleConfig: styleConfig,
                  action: action)
    }
}
