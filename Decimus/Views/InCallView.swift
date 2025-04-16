// SPDX-FileCopyrightText: Copyright (c) 2023 Cisco Systems
// SPDX-License-Identifier: BSD-2-Clause

import SwiftUI
import Network
#if canImport(UIKit)
import UIKit
#endif

/// View to show when in a call.
/// Shows remote video, local self view and controls.
struct InCallView: View {
    /// Supported supported video layouts.
    enum VideoLayout: CaseIterable, CustomStringConvertible {
        /// A 1x1 grid (of the active speaker, if known).
        case oneByOne
        /// A 2x2 grid (ranked by speaker, if known).
        case twoByTwo
        /// A unlimited grid (ranked by speaker, if known).
        case nByN
        /// A film strip of large active speaker and small others at top.
        case filmStrip

        var description: String {
            switch self {
            case .oneByOne:
                "1x1"
            case .twoByTwo:
                "2x2"
            case .nByN:
                "Grid"
            case .filmStrip:
                "Film Strip"
            }
        }

        /// The number of participants to show in this layout.
        var count: Int? {
            switch self {
            case .oneByOne:
                1
            case .twoByTwo:
                4
            default:
                nil
            }
        }
    }

    private let viewModel: CallState
    @State private var leaving: Bool = false
    @State private var noParticipantsDetected = false
    @State private var showPreview = true
    @State private var lastTap: Date = .now
    @State private var debugDetail = false
    @State private var layout = VideoLayout.nByN
    @State private var activeSpeakers: String = ""
    var noParticipants: Bool {
        self.viewModel.videoParticipants.participants.isEmpty
    }
    @State private var showControls = false

    /// Callback when call is left.
    #if !os(tvOS) && !os(macOS)
    private let orientationChanged = NotificationCenter
        .default
        .publisher(for: UIDevice.orientationDidChangeNotification)
        .makeConnectable()
        .autoconnect()
    #endif

    init(callState: CallState) {
        #if canImport(UIKit)
        UIApplication.shared.isIdleTimerDisabled = true
        #endif
        self.viewModel = callState
    }

    var body: some View {
        ZStack {
            GeometryReader { geometry in
                Group {
                    let gridCount: Int? = switch self.layout {
                    case .oneByOne:
                        1
                    case .twoByTwo:
                        4
                    default:
                        nil
                    }
                    #if os(tvOS)
                    ZStack {
                        // Incoming videos.
                        VideoGrid(showLabels: self.viewModel.showLabels,
                                  blur: self.$showControls,
                                  restrictedCount: gridCount,
                                  videoParticipants: self.viewModel.videoParticipants)
                            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .bottom)
                        HStack {
                            if self.showControls {
                                Group {
                                    Button("Hide Controls") {
                                        self.showControls = false
                                    }
                                    Button("Toggle Debug Details") {
                                        self.debugDetail = true
                                    }
                                    // Call controls panel.
                                    CallControls(captureManager: self.viewModel.captureManager,
                                                 engine: self.viewModel.engine,
                                                 leaving: self.$leaving)
                                }
                            } else {
                                Spacer()
                                VStack {
                                    Button("Show Controls") {
                                        self.showControls = true
                                    }
                                    Spacer()
                                }
                            }
                        }
                        .disabled(self.leaving)
                    }
                    #else
                    VStack {
                        VideoGrid(showLabels: self.viewModel.showLabels,
                                  blur: .constant(false),
                                  restrictedCount: gridCount,
                                  videoParticipants: self.viewModel.videoParticipants)
                            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .bottom)
                        Button("Toggle Debug Details") {
                            self.debugDetail = true
                        }

                        // Call controls panel.
                        CallControls(captureManager: viewModel.captureManager,
                                     engine: viewModel.engine,
                                     leaving: $leaving)
                            .disabled(leaving)
                            .padding(.bottom)
                            .frame(alignment: .top)
                    }
                    #endif
                }
                .sheet(isPresented: self.$debugDetail) {
                    VStack {
                        if let controller = self.viewModel.controller,
                           let manifest = self.viewModel.currentManifest {
                            Text("Debug Details").font(.title)
                            Form {
                                HStack {
                                    Text("Relay")
                                    Text(controller.serverId ?? "Unknown").monospaced()
                                }
                                LabeledContent("Layout") {
                                    Picker("Layout", selection: self.$layout) {
                                        ForEach(VideoLayout.allCases, id: \.self) { layout in
                                            Text("\(layout)")
                                        }
                                    }
                                    .labelsHidden()
                                    .pickerStyle(.segmented)
                                }
                                if let speakers = self.viewModel.activeSpeaker {
                                    let ids = speakers.lastRenderedSpeakers.map { $0.participantId }
                                    if let json = try? JSONEncoder().encode(ids) {
                                        LabeledContent("Currently Active Speakers") {
                                            Text(String(data: json, encoding: .utf8) ?? "Unknown")
                                        }
                                    } else {
                                        Text("Failed to parse list")
                                            .foregroundStyle(.red)
                                    }
                                    let received = speakers.lastReceived.map { $0.participantId }
                                    if let json = try? JSONEncoder().encode(received) {
                                        LabeledContent("Last Received Speakers") {
                                            Text(String(data: json, encoding: .utf8) ?? "Unknown")
                                        }
                                    } else {
                                        Text("Failed to parse list")
                                            .foregroundStyle(.red)
                                    }
                                }
                                let playtime = self.viewModel.playtimeConfig.value
                                if playtime.playtime && playtime.manualActiveSpeaker {
                                    LabeledContent("Active Speakers") {
                                        HStack {
                                            TextField("Active Speakers",
                                                      text: self.$activeSpeakers)
                                            #if !os(macOS)
                                            .keyboardType(.asciiCapable)
                                            #endif
                                            Button("Set") { self.viewModel.setManualActiveSpeaker(self.activeSpeakers)
                                            }
                                        }
                                    }
                                }
                            }
                            ScrollView {
                                SubscriptionPopover(controller,
                                                    manifest: manifest,
                                                    factory: self.viewModel.subscriptionFactory!)
                                PublicationPopover(controller)
                            }
                        }
                    }.padding()
                    Spacer()
                    Button("Done") {
                        self.debugDetail = false
                    }.padding()
                }

                // Preview / self-view.
                // swiftlint:disable force_try
                if let capture = viewModel.captureManager,
                   let camera = try! capture.activeDevices().first,
                   showPreview {
                    let gWidth = geometry.size.width
                    let gHeight = geometry.size.height
                    let cWidth = gWidth / 7
                    let cHeight = gHeight / 7
                    let pWidth = cWidth / 10
                    let pHeight = cHeight / 10
                    try! PreviewView(captureManager: capture, device: camera)
                        .frame(maxWidth: cWidth)
                        .offset(CGSize(width: gWidth - cWidth - pWidth,
                                       height: gHeight / 2 - (cHeight * 0.75) - pHeight))
                }
                // swiftlint:enable force_try
            }

            if leaving {
                LeaveModal(leaveAction: {
                    await viewModel.leave()
                    self.viewModel.onLeave()
                }, cancelAction: leaving = false)
                .frame(maxWidth: 400, alignment: .center)
            }
        }
        .background(.black)
        .onChange(of: noParticipants) { _, newValue in
            noParticipantsDetected = newValue
        }
        .onChange(of: self.layout) {
            if let activeSpeaker = self.viewModel.activeSpeaker {
                activeSpeaker.setClampCount(self.layout.count)
            }
        }
        .onTapGesture {
            // Show the preview when we tap.
            self.lastTap = .now
            withAnimation {
                self.showPreview.toggle()
            }
        }
        .task {
            // Hide the preview if we didn't tap for a while.
            while !Task.isCancelled {
                do {
                    try await Task.sleep(for: .seconds(5))
                } catch {
                    return
                }

                if self.lastTap.timeIntervalSince(.now) < -5 {
                    withAnimation {
                        if self.showPreview {
                            self.showPreview = false
                        }
                    }
                }
            }
        }
    }
}
