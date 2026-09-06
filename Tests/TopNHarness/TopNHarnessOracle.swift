// SPDX-FileCopyrightText: Copyright (c) 2026 Cisco Systems
// SPDX-License-Identifier: BSD-2-Clause

import Foundation
import CoreImage
import CoreMedia
import CoreVideo
import SwiftUI
import UIKit
@testable import QuicR

enum TopNHarnessOracle {
    private struct ObjectLocation: Hashable {
        let connectionGeneration: UInt64
        let handlerGeneration: UInt64?
        let groupId: UInt64
        let subgroupId: UInt64
        let objectId: UInt64
    }

    private struct FrameIdentity: Hashable {
        let connectionGeneration: UInt64
        let generation: UInt64?
        let presentationSeconds: TimeInterval
    }

    private struct SelectedFrame: Hashable {
        let frame: FrameIdentity
        let renderEpoch: UInt64?
    }

    static func lifecycleReactivationFailure(
        in events: [TopNHarnessRecordedEvent],
        subscriber: TopNParticipantID,
        publisher: TopNParticipantID,
        inactiveSinceMilliseconds: Double,
        activeSinceMilliseconds: Double,
        nowMilliseconds: Double,
        maxDisplayGapMilliseconds: Double
    ) -> TopNOracleViolation.Code? {
        let path = events.filter {
            $0.client == subscriber && $0.remoteParticipant == publisher
        }
        guard let created = path.first(where: {
            $0.elapsedMilliseconds >= activeSinceMilliseconds &&
                $0.stage == .handlerCreated &&
                $0.details?.reason == ActivationType.reactivation.rawValue
        }), let activeGeneration = created.handlerGeneration else {
            return .missingReactivation
        }
        guard let stopped = path.last(where: {
            $0.elapsedMilliseconds >= inactiveSinceMilliseconds &&
                $0.elapsedMilliseconds <= created.elapsedMilliseconds &&
                $0.stage == .handlerStopped &&
                $0.details?.reason == VideoHandlerStopReason.inactiveCleanup.rawValue
        }), let stoppedGeneration = stopped.handlerGeneration,
        activeGeneration > stoppedGeneration else {
            return .missingInactiveCleanup
        }
        let fresh = path.filter {
            $0.elapsedMilliseconds >= created.elapsedMilliseconds &&
                $0.handlerGeneration == activeGeneration
        }
        if path.contains(where: {
            $0.elapsedMilliseconds >= created.elapsedMilliseconds &&
                $0.stage == .displayEnqueued &&
                $0.handlerGeneration.map { $0 < activeGeneration } == true
        }) {
            return .staleGenerationDisplay
        }
        if let missing = self.missingRequiredStage(in: fresh, since: created.elapsedMilliseconds) {
            switch missing {
            case .objectReceived: return .missingRequiredTrack
            case .objectUsable: return .noUsableObject
            case .decoderOutput: return .noDecoderOutput
            case .simulreceiveSelected: return .noSelection
            case .displayEnqueued: return .noDisplay
            default: return .noDisplay
            }
        }
        if !fresh.contains(where: { $0.stage == .displayPresented }) { return .noPresentedFrame }
        let displayed = fresh.filter { $0.stage == .displayEnqueued }.map(\.elapsedMilliseconds).sorted()
        guard displayed.count >= 2,
              zip(displayed, displayed.dropFirst()).allSatisfy({ $1 - $0 <= maxDisplayGapMilliseconds }),
              nowMilliseconds - (displayed.last ?? 0) <= maxDisplayGapMilliseconds else {
            return .displayNotSustained
        }
        return nil
    }

    static func missingRequiredStage(
        in events: [TopNHarnessRecordedEvent],
        since stageWindowStartMilliseconds: Double
    ) -> TopNHarnessStage? {
        let recent = events.filter { $0.elapsedMilliseconds >= stageWindowStartMilliseconds }
            .sorted { $0.ordinal < $1.ordinal }
        var received: [ObjectLocation: UInt64] = [:]
        for event in recent where event.stage == .objectReceived {
            guard let groupId = event.groupId,
                  let subgroupId = event.subgroupId,
                  let objectId = event.objectId else { continue }
            let location = ObjectLocation(connectionGeneration: event.connectionGeneration,
                                          handlerGeneration: event.handlerGeneration,
                                          groupId: groupId, subgroupId: subgroupId, objectId: objectId)
            received[location] = min(received[location] ?? event.ordinal, event.ordinal)
        }
        guard !received.isEmpty else { return .objectReceived }

        let usable = recent.compactMap { event -> (FrameIdentity, UInt64)? in
            guard event.stage == .objectUsable,
                  let groupId = event.groupId,
                  let subgroupId = event.subgroupId,
                  let objectId = event.objectId,
                  let presentation = event.details?.presentationSeconds else { return nil }
            let location = ObjectLocation(connectionGeneration: event.connectionGeneration,
                                          handlerGeneration: event.handlerGeneration,
                                          groupId: groupId, subgroupId: subgroupId, objectId: objectId)
            guard let receivedOrdinal = received[location], receivedOrdinal < event.ordinal else { return nil }
            return (.init(connectionGeneration: event.connectionGeneration,
                          generation: event.handlerGeneration,
                          presentationSeconds: presentation), event.ordinal)
        }
        guard !usable.isEmpty else { return .objectUsable }

        let decoded = recent.compactMap { event -> (FrameIdentity, UInt64)? in
            guard event.stage == .decoderOutput,
                  let presentation = event.details?.presentationSeconds else { return nil }
            let frame = FrameIdentity(connectionGeneration: event.connectionGeneration,
                                      generation: event.handlerGeneration,
                                      presentationSeconds: presentation)
            guard usable.contains(where: { $0.0 == frame && $0.1 < event.ordinal }) else { return nil }
            return (frame, event.ordinal)
        }
        guard !decoded.isEmpty else { return .decoderOutput }

        let selected = recent.compactMap { event -> (SelectedFrame, UInt64)? in
            guard event.stage == .simulreceiveSelected,
                  event.details?.displayed == true,
                  let presentation = event.details?.presentationSeconds else { return nil }
            let frame = FrameIdentity(connectionGeneration: event.connectionGeneration,
                                      generation: event.handlerGeneration,
                                      presentationSeconds: presentation)
            guard decoded.contains(where: { $0.0 == frame && $0.1 < event.ordinal }) else { return nil }
            return (.init(frame: frame, renderEpoch: event.renderEpoch), event.ordinal)
        }
        guard !selected.isEmpty else { return .simulreceiveSelected }

        let displayed = recent.contains { event in
            guard event.stage == .displayEnqueued,
                  let presentation = event.details?.presentationSeconds else { return false }
            let selectedFrame = SelectedFrame(
                frame: .init(connectionGeneration: event.connectionGeneration,
                             generation: event.handlerGeneration,
                             presentationSeconds: presentation),
                renderEpoch: event.renderEpoch)
            return selected.contains { $0.0 == selectedFrame && $0.1 < event.ordinal }
        }
        return displayed ? nil : .displayEnqueued
    }

    static func deliveryViolations(subscriber: TopNParticipantID,
                                   view: TopNExpectedView,
                                   online: Set<TopNParticipantID>,
                                   delivered: Set<TopNParticipantID>) -> [TopNOracleViolation] {
        var violations: [TopNOracleViolation] = []
        func add(_ code: TopNOracleViolation.Code, _ publisher: TopNParticipantID? = nil) {
            violations.append(.init(code: code, subscriber: subscriber, publisher: publisher))
        }
        if delivered.contains(subscriber) { add(.selfDelivery, subscriber) }
        for publisher in delivered where publisher != subscriber {
            if !online.contains(publisher) {
                add(.offlineDelivery, publisher)
            } else if !view.allowed.contains(publisher) {
                add(.outsideAllowedSet, publisher)
            }
        }
        let eligibleDelivered = delivered.filter { $0 != subscriber && online.contains($0) }
        if eligibleDelivered.count < view.expectedCount { add(.tooFewDelivered) }
        if eligibleDelivered.count > view.expectedCount { add(.tooManyDelivered) }
        for publisher in view.required where online.contains(publisher) && !delivered.contains(publisher) {
            add(.missingRequiredTrack, publisher)
        }
        return violations
    }

    static func resolve(subscriber: TopNParticipantID,
                        activity: [TopNParticipantID: TopNActivity],
                        online: Set<TopNParticipantID>,
                        topN: Int) -> TopNExpectedView {
        let ranked = online
            .filter { $0 != subscriber }
            .compactMap { participant -> (TopNParticipantID, UInt8)? in
                guard let value = activity[participant] else { return nil }
                return (participant, value.rawValue)
            }
            .sorted { lhs, rhs in
                if lhs.1 != rhs.1 { return lhs.1 > rhs.1 }
                return lhs.0.rawValue < rhs.0.rawValue
            }
        guard !ranked.isEmpty else {
            return .init(required: [], allowed: [], expectedCount: 0)
        }
        let count = min(topN, ranked.count)
        let cutoff = ranked[count - 1].1
        let cutoffParticipants = ranked.filter { $0.1 == cutoff }
        let allowed = Set(ranked.filter { $0.1 >= cutoff }.map(\.0))
        let required: Set<TopNParticipantID>
        if cutoffParticipants.count == 1 {
            required = Set(cutoffParticipants.map(\.0))
        } else {
            required = Set(ranked.filter { $0.1 > cutoff }.map(\.0))
        }
        return .init(required: required, allowed: allowed, expectedCount: count)
    }

    static func evaluate(subscriber: TopNParticipantID,
                         view: TopNExpectedView,
                         online: Set<TopNParticipantID>,
                         connectionHealthy: Bool,
                         delivered: Set<TopNParticipantID>,
                         progress: [TopNParticipantID: TopNStageProgress],
                         stageWindowStart: Ticks,
                         livenessWindowStart: Ticks,
                         now: Ticks,
                         maxDisplayGapSeconds: TimeInterval) -> [TopNOracleViolation] {
        var violations: [TopNOracleViolation] = []
        func add(_ code: TopNOracleViolation.Code, _ publisher: TopNParticipantID? = nil) {
            violations.append(.init(code: code, subscriber: subscriber, publisher: publisher))
        }

        guard connectionHealthy else { add(.unhealthyConnection); return violations }
        violations += self.deliveryViolations(subscriber: subscriber, view: view,
                                              online: online, delivered: delivered)

        let expectedPipeline = view.required.isEmpty ? delivered.intersection(view.allowed) : view.required
        for publisher in expectedPipeline where online.contains(publisher) {
            let values = progress[publisher] ?? .init()
            let usable = values.usable.filter { $0 >= stageWindowStart }
            let decoded = values.decoded.filter { $0 >= stageWindowStart }
            let selected = values.selected.filter { $0 >= stageWindowStart }
            let displayed = values.displayed.filter { $0 >= stageWindowStart }
            if usable.isEmpty { add(.noUsableObject, publisher) }
            if decoded.isEmpty { add(.noDecoderOutput, publisher) }
            if selected.isEmpty { add(.noSelection, publisher) }
            if displayed.isEmpty { add(.noDisplay, publisher) }

            let sustained = values.displayed.filter { $0 >= livenessWindowStart }.sorted()
            let hasGaps = sustained.count >= 2 && zip(sustained, sustained.dropFirst()).allSatisfy {
                $1.timeIntervalSince($0) <= maxDisplayGapSeconds
            }
            let currentGap = sustained.last.map { now.timeIntervalSince($0) <= maxDisplayGapSeconds } ?? false
            if !hasGaps || !currentGap { add(.displayNotSustained, publisher) }
        }
        return violations
    }
}

enum TopNHarnessPresentation {
    static func isVisiblyNonBlack(luma: [UInt8]) -> Bool {
        guard !luma.isEmpty else { return false }
        let total = luma.reduce(UInt64(0)) { $0 + UInt64($1) }
        return total / UInt64(luma.count) > 24
    }

    static func lumaSamples(from pixelBuffer: CVPixelBuffer) -> [UInt8] {
        self.lumaSamples(from: CIImage(cvPixelBuffer: pixelBuffer))
    }

    static func lumaSamples(from image: CGImage) -> [UInt8] {
        self.lumaSamples(from: CIImage(cgImage: image))
    }

    private static func lumaSamples(from image: CIImage) -> [UInt8] {
        let sampleWidth = 32
        let sampleHeight = 32
        guard !image.extent.isEmpty else { return [] }
        let normalised = image.transformed(by: CGAffineTransform(translationX: -image.extent.minX,
                                                                 y: -image.extent.minY))
        let scaled = normalised.transformed(by: CGAffineTransform(scaleX: CGFloat(sampleWidth) / image.extent.width,
                                                                  y: CGFloat(sampleHeight) / image.extent.height))
        var pixels = [UInt8](repeating: 0, count: sampleWidth * sampleHeight * 4)
        pixels.withUnsafeMutableBytes { bytes in
            guard let base = bytes.baseAddress else { return }
            CIContext(options: [.cacheIntermediates: false]).render(
                scaled,
                toBitmap: base,
                rowBytes: sampleWidth * 4,
                bounds: CGRect(x: 0, y: 0, width: sampleWidth, height: sampleHeight),
                format: .RGBA8,
                colorSpace: CGColorSpaceCreateDeviceRGB())
        }
        return stride(from: 0, to: pixels.count, by: 4).map { offset in
            let red = UInt16(pixels[offset])
            let green = UInt16(pixels[offset + 1])
            let blue = UInt16(pixels[offset + 2])
            return UInt8((29 * blue + 150 * green + 77 * red) >> 8)
        }
    }

}

struct TopNHarnessPresentationSample {
    let meanLuma: Double
    let source: String
    let motionObserved: Bool
}

private enum TopNHarnessCaptureSource: String {
    case renderer
    case hostedView
}

private struct TopNHarnessCapturedFrame {
    let sample: TopNHarnessPresentationSample
    let luma: [UInt8]
    let source: TopNHarnessCaptureSource
}

enum TopNHarnessPresentationError: Error, Equatable {
    case noWindowScene, invalidLayer, layerFailed, noDisplayedPixelBuffer, blackFrame
    case timebase(String)
}

@MainActor
final class TopNHarnessPresentationHost {
    private let window: UIWindow
    private let rootViewController: UIViewController
    private let container: UIView
    private var controllersBySlot: [String: UIViewController] = [:]

    init() throws {
        guard let scene = UIApplication.shared.connectedScenes.compactMap({ $0 as? UIWindowScene }).first else {
            throw TopNHarnessPresentationError.noWindowScene
        }
        let controller = UIViewController()
        self.rootViewController = controller
        self.container = controller.view
        self.window = UIWindow(windowScene: scene)
        self.window.frame = scene.screen.bounds
        self.window.rootViewController = controller
        self.window.windowLevel = .normal + 1
        self.window.makeKeyAndVisible()
    }

    func attach(_ videoView: VideoView, slot: String? = nil) {
        let controller = UIHostingController(rootView: videoView)
        self.attach(controller, slot: slot ?? String(describing: ObjectIdentifier(videoView.view)))
    }

    func attachGrid(_ participants: VideoParticipants, topN: Int, slot: String) {
        let grid = VideoGrid(showLabels: false,
                             blur: .constant(false),
                             restrictedCount: topN,
                             videoParticipants: participants)
        self.attach(UIHostingController(rootView: grid), slot: slot)
    }

    private func attach(_ controller: UIViewController, slot: String) {
        if let existing = self.controllersBySlot.removeValue(forKey: slot) {
            existing.willMove(toParent: nil)
            existing.view.removeFromSuperview()
            existing.removeFromParent()
        }
        self.rootViewController.addChild(controller)
        self.container.addSubview(controller.view)
        controller.didMove(toParent: self.rootViewController)
        self.controllersBySlot[slot] = controller
        self.layoutViews()
    }

    func detach(slot: String) {
        guard let existing = self.controllersBySlot.removeValue(forKey: slot) else { return }
        existing.willMove(toParent: nil)
        existing.view.removeFromSuperview()
        existing.removeFromParent()
        self.layoutViews()
    }

    func diagnostics(_ videoView: VideoView) -> String {
        let view = videoView.view
        guard let layer = videoView.layer else {
            return "layer=nil viewWindow=\(view.window != nil) viewBounds=\(view.bounds)"
        }
        let renderer = layer.sampleBufferRenderer
        let rendererError = renderer.error?.localizedDescription ?? "nil"
        let timebaseRate = layer.controlTimebase.map(CMTimebaseGetRate)
        let timebaseTime = layer.controlTimebase.map { CMTimebaseGetTime($0).seconds }
        return "rendererStatus=\(renderer.status.rawValue) rendererError=\(rendererError) " +
            "ready=\(renderer.isReadyForMoreMediaData) requiresFlush=\(renderer.requiresFlushToResumeDecoding) " +
            "timebaseRate=\(String(describing: timebaseRate)) " +
            "timebaseTime=\(String(describing: timebaseTime)) viewWindow=\(view.window != nil) " +
            "viewHidden=\(view.isHidden) viewAlpha=\(view.alpha) viewBounds=\(view.bounds) layerBounds=\(layer.bounds)"
    }

    func capture(_ videoView: VideoView,
                 timeout: Duration = .milliseconds(750)) async throws -> TopNHarnessPresentationSample {
        let clock = ContinuousClock()
        let deadline = clock.now + timeout
        var motionDeadline: ContinuousClock.Instant?
        var visibleFramesBySource: [TopNHarnessCaptureSource: TopNHarnessCapturedFrame] = [:]
        while true {
            do {
                let captured = try await self.captureOnce(videoView)
                if let baseline = visibleFramesBySource[captured.source], baseline.luma != captured.luma {
                    return .init(meanLuma: captured.sample.meanLuma,
                                 source: captured.sample.source,
                                 motionObserved: true)
                }
                visibleFramesBySource[captured.source] = captured
                motionDeadline = motionDeadline ?? min(deadline, clock.now + .milliseconds(750))
                if let motionDeadline, clock.now >= motionDeadline {
                    return captured.sample
                }
                try await Task.sleep(for: .milliseconds(50))
            } catch let error as TopNHarnessPresentationError {
                guard clock.now < deadline,
                      error == .noDisplayedPixelBuffer || error == .blackFrame else { throw error }
                try await Task.sleep(for: .milliseconds(50))
            }
        }
    }

    private func captureOnce(_ videoView: VideoView) async throws -> TopNHarnessCapturedFrame {
        guard let layer = videoView.layer else { throw TopNHarnessPresentationError.invalidLayer }
        guard layer.sampleBufferRenderer.status != .failed else { throw TopNHarnessPresentationError.layerFailed }
        guard layer.controlTimebase != nil else { throw TopNHarnessPresentationError.timebase("missing") }
        let luma: [UInt8]
        let source: TopNHarnessCaptureSource
        if let pixelBuffer = layer.sampleBufferRenderer.displayedPixelBuffer() {
            luma = TopNHarnessPresentation.lumaSamples(from: pixelBuffer)
            source = .renderer
        } else {
            luma = self.renderedLuma(videoView.view)
            source = .hostedView
            guard TopNHarnessPresentation.isVisiblyNonBlack(luma: luma) else {
                throw TopNHarnessPresentationError.noDisplayedPixelBuffer
            }
        }
        guard TopNHarnessPresentation.isVisiblyNonBlack(luma: luma) else {
            throw TopNHarnessPresentationError.blackFrame
        }
        let total = luma.reduce(UInt64(0)) { $0 + UInt64($1) }
        return .init(sample: .init(meanLuma: Double(total) / Double(luma.count),
                                   source: source.rawValue,
                                   motionObserved: false),
                     luma: luma, source: source)
    }

    private func renderedLuma(_ view: UIView) -> [UInt8] {
        guard view.window != nil, view.bounds.width > 0, view.bounds.height > 0 else { return [] }
        let format = UIGraphicsImageRendererFormat()
        format.scale = min(1, 64 / max(view.bounds.width, view.bounds.height))
        format.opaque = true
        var drewHierarchy = false
        let image = UIGraphicsImageRenderer(bounds: view.bounds, format: format).image { _ in
            drewHierarchy = view.drawHierarchy(in: view.bounds, afterScreenUpdates: true)
        }
        guard drewHierarchy, let image = image.cgImage else { return [] }
        return TopNHarnessPresentation.lumaSamples(from: image)
    }

    private func layoutViews() {
        let views = self.container.subviews
        guard !views.isEmpty else { return }
        let columns = views.count > 1 ? 2 : 1
        let rows = Int(ceil(Double(views.count) / Double(columns)))
        let width = self.container.bounds.width / CGFloat(columns)
        let height = self.container.bounds.height / CGFloat(rows)
        for (index, view) in views.enumerated() {
            view.frame = .init(x: CGFloat(index % columns) * width,
                               y: CGFloat(index / columns) * height,
                               width: width, height: height)
            view.autoresizingMask = []
        }
        self.container.layoutIfNeeded()
    }
}
