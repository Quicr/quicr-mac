import SwiftUI
import UIKit

struct Above<AboveContent: View>: ViewModifier {
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

struct CornerRadiusShape: Shape {
    var radius: CGFloat = CGFloat.infinity
    var corners: UIRectCorner = UIRectCorner.allCorners

    func path(in rect: CGRect) -> Path {
        let path = UIBezierPath(roundedRect: rect,
                                byRoundingCorners: corners,
                                cornerRadii: CGSize(width: radius, height: radius))
        return Path(path.cgPath)
    }
}

struct CornerRadiusStyle: ViewModifier {
    var radius: CGFloat
    var corners: UIRectCorner

    func body(content: Content) -> some View {
        content
            .clipShape(CornerRadiusShape(radius: radius, corners: corners))
    }
}

extension View {
    func float<Content: View>(above: Content) -> ModifiedContent<Self, Above<Content>> {
        self.modifier(Above(aboveContent: above))
    }

    func cornerRadius(_ radius: CGFloat, corners: UIRectCorner) -> some View {
        ModifiedContent(content: self, modifier: CornerRadiusStyle(radius: radius, corners: corners))
    }
}
