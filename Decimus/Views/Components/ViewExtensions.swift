// SPDX-FileCopyrightText: Copyright (c) 2023 Cisco Systems
// SPDX-License-Identifier: BSD-2-Clause

import SwiftUI
#if canImport(UIKit)
import UIKit
#endif

struct Above<AboveContent: View>: ViewModifier {
    let aboveContent: AboveContent

    func body(content: Content) -> some View {
        content.overlay(
            GeometryReader { proxy in
                Rectangle().fill(.clear).overlay(
                    self.aboveContent.offset(x: 0, y: -proxy.size.height),
                    alignment: .bottomTrailing
                )
            }
        )
    }
}

struct CornerRadiusShape: Shape {
    var radius: CGFloat = CGFloat.infinity
    #if canImport(UIKit)
    var corners: UIRectCorner = UIRectCorner.allCorners
    #endif

    func path(in rect: CGRect) -> Path {
        #if canImport(UIKit)
        let path = UIBezierPath(roundedRect: rect,
                                byRoundingCorners: corners,
                                cornerRadii: CGSize(width: radius, height: radius))
        return Path(path.cgPath)
        #else
        return Path(ellipseIn: rect)
        #endif
    }
}

struct CornerRadiusStyle: ViewModifier {
    var radius: CGFloat
    #if canImport(UIKit)
    var corners: UIRectCorner
    #endif

    func body(content: Content) -> some View {
        content
        #if canImport(UIKit)
        .clipShape(CornerRadiusShape(radius: radius, corners: corners))
        #endif
    }
}

extension View {
    func float<Content: View>(above: Content) -> ModifiedContent<Self, Above<Content>> {
        self.modifier(Above(aboveContent: above))
    }

    #if canImport(UIKit)
    func cornerRadius(_ radius: CGFloat, corners: UIRectCorner) -> ModifiedContent<Self, CornerRadiusStyle> {
        self.modifier(CornerRadiusStyle(radius: radius, corners: corners))
    }
    #endif

    @ViewBuilder func conditionalModifier<ModifiedView: View>(_ condition: Bool,
                                                              modifier: (Self) -> ModifiedView) -> some View {
        if condition {
            modifier(self)
        } else {
            self
        }
    }
}
