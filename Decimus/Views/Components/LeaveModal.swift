import SwiftUI

struct LeaveModal: View {
    private let leaveAction: () -> Void
    private let cancelAction: () -> Void

    init(leaveAction: @escaping () -> Void, cancelAction: @escaping () -> Void) {
        self.leaveAction = leaveAction
        self.cancelAction = cancelAction
    }

    init(leaveAction: @escaping () async -> Void, cancelAction: @escaping () async -> Void) {
        self.leaveAction = { Task { await leaveAction() }}
        self.cancelAction = { Task { await cancelAction() }}
    }

    var body: some View {
        VStack(alignment: .leading) {
            Text("Leave Meeting")
                .foregroundColor(.white)
                .font(.title)
                .padding(.bottom)
            Text("Do you want to leave this meeting?")
                .foregroundColor(.gray)
                .font(.body)
                .padding(.bottom)
            HStack {
                Spacer().frame(maxWidth: .infinity)
                ActionButton("Cancel",
                             styleConfig: .init(
                                background: .black,
                                foreground: .white,
                                borderColour: .gray),
                             action: cancelAction)
                .fixedSize()
                ActionButton("Leave Meeting",
                             styleConfig: .init(
                                background: .white,
                                foreground: .black),
                             action: leaveAction)
                .fixedSize()
            }
        }
        .padding()
        .overlay(
            RoundedRectangle(cornerRadius: 12)
                .stroke(.gray, lineWidth: 1)
        )
        .background(.black)
        .cornerRadius(12)
    }
}
