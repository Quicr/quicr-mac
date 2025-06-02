// SPDX-FileCopyrightText: Copyright (c) 2025 Cisco Systems
// SPDX-License-Identifier: BSD-2-Clause

#if canImport(ScreenCaptureKit)
import SwiftUI
import ScreenCaptureKit

private struct Display: Identifiable, CustomStringConvertible, Hashable {
    let description: String
    let id: CGDirectDisplayID

    init(display: SCDisplay) {
        self.id = display.displayID
        self.description = "Display - \(display.width)x\(display.height)"
    }

    init() {
        self.description = "None"
        self.id = 0
    }
}

struct DisplayPicker: View {
    static let displayRecordKey = "displayRecordKey"
    @AppStorage(Self.displayRecordKey)
    private var displayRecord: Int = 0

    private static let noDisplay = Display()
    @State private var selectedDisplay = Self.noDisplay
    @State private var displays: [Display] = []
    @State private var error: Error?

    var body: some View {
        VStack {
            if let error {
                Text(error.localizedDescription)
                    .foregroundStyle(.red)
                    .font(.footnote)
            } else {
                LabeledContent("Display") {
                    Picker("Display", selection: self.$selectedDisplay) {
                        ForEach(self.displays) { display in
                            Text("\(display)").tag(display)
                        }
                    }
                    .pickerStyle(.segmented)
                    .labelsHidden()
                }
            }
        }
        .task {
            await self.loadDisplays()
        }
        .onChange(of: self.selectedDisplay) {
            self.displayRecord = Int(self.selectedDisplay.id)
        }
    }

    private func loadDisplays() async {
        do {
            let content = try await SCShareableContent.excludingDesktopWindows(false,
                                                                               onScreenWindowsOnly: false)
            self.displays = content.displays.map { Display(display: $0) }
            if self.selectedDisplay == Self.noDisplay,
               let first = self.displays.first {
                self.selectedDisplay = first
            }
            self.error = nil
        } catch {
            self.error = error
        }
    }
}
#endif
