// SPDX-FileCopyrightText: Copyright (c) 2023 Cisco Systems
// SPDX-License-Identifier: BSD-2-Clause

import SwiftUI
import AVFoundation

#if os(macOS)
class VideoUIView: NSView {
    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        self.layer = AVSampleBufferDisplayLayer()
        self.wantsLayer = true
    }

    required init?(coder: NSCoder) {
        super.init(coder: coder)
    }
}
#else
class VideoUIView: UIView {
    override public class var layerClass: AnyClass {
        return AVSampleBufferDisplayLayer.self
    }
}
#endif

enum VideoError: Error {
    case invalidLayer
    case layerFailed
    case layerTimebaseFailed(Error)
}

#if os(macOS)
struct VideoView: NSViewRepresentable {
    let view: VideoUIView = .init()
    var layer: AVSampleBufferDisplayLayer? { return view.layer as? AVSampleBufferDisplayLayer }

    // UI based measurements.
    private(set) var joinToFirstFrame: TimeInterval?
    private(set) var subscribeToFirstFrame: TimeInterval?
    private let startDate: Date
    private let subscribeDate: Date

    init(startDate: Date, subscribeDate: Date) {
        self.startDate = startDate
        self.subscribeDate = subscribeDate
    }

    func makeNSView(context: Context) -> VideoUIView {
        do {
            try layer!.controlTimebase = .init(sourceClock: .hostTimeClock)
            try layer!.controlTimebase?.setTime(.zero)
            try layer!.controlTimebase?.setRate(1.0)
        } catch {
            fatalError("Failed to setup layer: \(error)")
        }
        return view
    }

    func flush() throws {
        guard let layer = layer else {
            throw VideoError.invalidLayer
        }

        layer.flush()

        do {
            try layer.controlTimebase?.setTime(.zero)
            try layer.controlTimebase?.setRate(1.0)
        } catch {
            throw VideoError.layerTimebaseFailed(error)
        }
    }

    mutating func enqueue(_ sampleBuffer: CMSampleBuffer, transform: CATransform3D?) throws {
        guard let layer = layer else {
            throw VideoError.invalidLayer
        }

        guard layer.status != .failed else {
            layer.flush()
            throw VideoError.layerFailed
        }

        layer.transform = transform ?? CATransform3DIdentity
        layer.enqueue(sampleBuffer)

        if self.joinToFirstFrame == nil {
            let now = Date.now
            self.joinToFirstFrame = now.timeIntervalSince(self.startDate)
            self.subscribeToFirstFrame = now.timeIntervalSince(self.subscribeDate)
        }
    }

    func updateNSView(_ nsView: VideoUIView, context: Context) {}
}
#else
struct VideoView: UIViewRepresentable {
    let view: VideoUIView = .init()
    var layer: AVSampleBufferDisplayLayer? { return view.layer as? AVSampleBufferDisplayLayer }

    // UI based measurements.
    private(set) var joinToFirstFrame: TimeInterval?
    private(set) var subscribeToFirstFrame: TimeInterval?
    private let startDate: Date
    private let subscribeDate: Date

    init(startDate: Date, subscribeDate: Date) {
        self.startDate = startDate
        self.subscribeDate = subscribeDate
    }

    func flush() throws {
        guard let layer = layer else {
            throw VideoError.invalidLayer
        }

        layer.flush()

        do {
            try layer.controlTimebase?.setTime(.zero)
            try layer.controlTimebase?.setRate(1.0)
        } catch {
            throw VideoError.layerTimebaseFailed(error)
        }
    }

    mutating func enqueue(_ sampleBuffer: CMSampleBuffer, transform: CATransform3D?) throws {
        guard let layer = layer else {
            throw VideoError.invalidLayer
        }

        guard layer.status != .failed else {
            layer.flush()
            throw VideoError.layerFailed
        }

        layer.transform = transform ?? CATransform3DIdentity
        layer.enqueue(sampleBuffer)
        if self.joinToFirstFrame == nil {
            let now = Date.now
            self.joinToFirstFrame = now.timeIntervalSince(self.startDate)
            self.subscribeToFirstFrame = now.timeIntervalSince(self.subscribeDate)
        }
    }

    func makeUIView(context: Context) -> VideoUIView {
        do {
            try layer?.controlTimebase = .init(sourceClock: .hostTimeClock)
            try layer?.controlTimebase?.setTime(.zero)
            try layer?.controlTimebase?.setRate(1.0)
        } catch {
            fatalError("Failed to setup layer: \(error)")
        }

        view.contentMode = .scaleAspectFit
        return view
    }

    func updateUIView(_ uiView: VideoUIView, context: Context) {}
}
#endif

struct VideoView_Previews: PreviewProvider {
    static var previews: some View {
        VideoView(startDate: .now, subscribeDate: .now)
    }
}
