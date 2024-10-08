// SPDX-FileCopyrightText: Copyright (c) 2023 Cisco Systems
// SPDX-License-Identifier: BSD-2-Clause

import Foundation
import SwiftUI

/// A view that allows textual entry of a typed integer with UI errors
/// on overflow / invalid characters, updating a provided Binding
/// if valid.
struct NumberView<T: FixedWidthInteger>: View {
    @Binding var value: T
    let formatStyle: IntegerFormatStyle<T>
    let name: String
    @State private var text: String = ""
    @State private var errorText: String?

    var body: some View {
        VStack {
            TextField(self.name, text: self.$text)
                #if canImport(UIKit)
                .keyboardType(.numberPad)
                #endif
                .labelsHidden()
                .onChange(of: self.text) {
                    do {
                        switch try validate(self.text) {
                        case .empty:
                            self.errorText = nil
                        case .nan:
                            self.errorText = "\(self.name) must be a number"
                        case .tooLarge:
                            self.errorText = "\(self.name) is too large"
                        case .valid(let parsed):
                            self.value = parsed
                            self.errorText = nil
                        }
                    } catch {
                        self.errorText = error.localizedDescription
                    }
                }
            if let error = self.errorText {
                HStack {
                    Text(error)
                        .foregroundStyle(.red)
                        .font(.footnote)
                    Spacer()
                }
            }
        }
        .onAppear {
            self.text = self.value.formatted(self.formatStyle)
        }
        .onChange(of: self.value) {
            self.text = self.value.formatted(self.formatStyle)
        }
    }

    enum ValidationResult: Equatable {
        case empty
        case nan
        case tooLarge
        case valid(T)
    }

    func validate(_ value: String) throws -> ValidationResult {
        // Need something.
        guard !value.isEmpty else {
            return .empty
        }
        // Should be all numbers.
        guard value.allSatisfy({ $0.isNumber }) else {
            return .nan
        }

        // Should be <= UInt16 max value.
        let max = String(T.max)
        guard value.count <= max.count else {
            return .tooLarge
        }

        // Equals needs digit by digit comparison.
        if value.count == max.count {
            let digitPairs = zip(value, max)
            for (valueDigit, maxDigit) in digitPairs {
                guard valueDigit <= maxDigit else {
                    return .tooLarge
                }
                guard valueDigit == maxDigit else {
                    break
                }
            }
        }

        // Valid!
        let parsed = try T(value, format: self.formatStyle)
        return .valid(parsed)
    }
}

#Preview {
    NumberView<UInt8>(value: .constant(1),
                      formatStyle: .number,
                      name: "Test")
}
