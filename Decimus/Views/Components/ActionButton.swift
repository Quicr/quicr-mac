import SwiftUI

struct StyleColours {
    let background: Color
    let foreground: Color
}

struct ActionButtonStyle: ButtonStyle {
    let colours: StyleColours
    let cornerRadius: CGFloat
    let isDisabled: Bool

    func makeBody(configuration: Self.Configuration) -> some View {
        let foregroundColour = colours.foreground.opacity(isDisabled || configuration.isPressed ? 0.3 : 1)
        let backgroundColour = colours.background.opacity(isDisabled || configuration.isPressed ? 0.3 : 1)
        return configuration.label
            .padding()
            .foregroundColor(foregroundColour)
            .background(backgroundColour)
            .cornerRadius(cornerRadius)
            .overlay(
                RoundedRectangle(cornerRadius: cornerRadius)
                    .stroke(.white, lineWidth: colours.background == .black ? 1 : 0)
            )
            .padding([.top, .bottom], 10)
            .font(Font.system(size: 19, weight: .semibold))
    }
}

struct ActionButton<Content>: View where Content: View {
    private let colours: StyleColours

    @ViewBuilder private let title: Content
    private let action: () -> Void
    private let disabled: Bool

    init(disabled: Bool = false,
         colours: StyleColours,
         action: @escaping () -> Void,
         @ViewBuilder title: @escaping () -> Content) {
       self.colours = colours
       self.title = title()
       self.action = action
       self.disabled = disabled
    }

    var body: some View {
        HStack {
            Button(action: self.action) {
                self.title.frame(maxWidth: .infinity)
            }
            .buttonStyle(ActionButtonStyle(
                colours: self.colours,
                cornerRadius: 30,
                isDisabled: disabled))
            .disabled(self.disabled)
        }
    }
}

extension ActionButton where Content == Text {
    init(_ title: String,
         disabled: Bool = false,
         colours: StyleColours,
         action: @escaping () -> Void) {
        self.init(disabled: disabled, colours: colours, action: action) {
            Text(title)
        }
    }
}
