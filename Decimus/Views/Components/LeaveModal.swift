import SwiftUI

struct LeaveModal: View {
    private let leaveAction: () async -> Void
    private let cancelAction: () -> Void
    @State private var leaving = false

    init(leaveAction: @escaping () async -> Void, cancelAction: @autoclosure @escaping () -> Void) {
        self.leaveAction = leaveAction
        self.cancelAction = cancelAction
    }

    var body: some View {
        VStack(alignment: .leading) {
            HStack {
                Text("Leave Meeting")
                    .foregroundColor(.white)
                    .font(.title)
                    .padding(.bottom)
                Spacer()
                if self.leaving {
                    ProgressView()
                }
            }
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
                ActionButton(self.leaving ? "Leaving..." : "Leave Meeting",
                             styleConfig: .init(
                                background: .white,
                                foreground: .black),
                             action: {
                    Task {
                        self.leaving = true
                        await self.leaveAction()
                        self.leaving = false
                    }
                })
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
