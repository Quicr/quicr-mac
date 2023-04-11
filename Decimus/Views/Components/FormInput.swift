import SwiftUI

struct FormInputStyle: TextFieldStyle {
    // swiftlint:disable identifier_name
    func _body(configuration: TextField<Self._Label>) -> some View {
        configuration
            .padding()
            .frame(height: 36)
            .background(.black)
            .foregroundColor(Color(white: 1, opacity: 0.7))
            .cornerRadius(8)
            .overlay {
                RoundedRectangle(cornerRadius: 8)
                    .stroke(Color.white, lineWidth: 1)
                    .opacity(0.5)
            }
            .disableAutocorrection(true)
    }
    // swiftlint:enable identifier_name
}
