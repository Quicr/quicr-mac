import AVFoundation
import CoreAudio
import CTPCircularBuffer

/// Plays audio samples out.
class FasterAVEngineAudioPlayer: AudioPlayer {
    private var engine: AVAudioEngine = .init()
    private var mixer: AVAudioMixerNode = .init()
    private let errorWriter: ErrorWriter
    private var elements: [UInt32: Element] = [:]
    private var elementsLock: atomic_flag = .init()
    private var readContentions: Int32 = 0
    private var writeContentions: Int32 = 0

    /// Represents an individual input source for mixed output.
    private struct Element {
        var player: AVAudioSourceNode
        var buffer: TPCircularBuffer
        var metrics: BufferMetrics
    }

    /// Metrics.
    private struct BufferMetrics {
        var copyFails = 0
        var incompleteFrames = 0
        var reads = 0
        var copyAttempts = 0
    }

    /// Create a new `AudioPlayer`
    init(errorWriter: ErrorWriter) {
        self.errorWriter = errorWriter

        engine.attach(mixer)
        engine.connect(mixer, to: engine.outputNode, format: nil)
        engine.prepare()
    }

    deinit {
        while Self.getLock(atomic: &elementsLock) == false {
            // Spin.
        }
        defer { Self.unlock(atomic: &elementsLock)}

        engine.stop()

        for identifier in elements.keys {
            removeElement(identifier: identifier, lock: false)
        }
        elements.removeAll()

        engine.disconnectNodeInput(mixer)
        engine.detach(mixer)
    }

    @inline(__always)
    private static func getLock(atomic: inout atomic_flag) -> Bool {
        atomic_flag_test_and_set_explicit(&atomic, memory_order_acquire) == false
    }

    @inline(__always)
    private static func unlock(atomic: inout atomic_flag) {
        atomic_flag_clear_explicit(&atomic, memory_order_release)
    }

    func write(identifier: UInt32, buffer: AVAudioPCMBuffer) {
        // Get the buffer for this stream and ensure it's valid.
        var list = buffer.mutableAudioBufferList.pointee
        guard list.mNumberBuffers == 1 else {
            fatalError()
        }
        guard list.mBuffers.mDataByteSize > 0 else {
            fatalError()
        }

        // Spin until we get access.
        var contention = false
        while Self.getLock(atomic: &elementsLock) == false {
            if !contention {
                OSAtomicIncrement32(&self.writeContentions)
                contention = true
            }
        }
        defer { Self.unlock(atomic: &elementsLock) }

        // We got the lock, get data objects.
        var intermediateElement: Element? = self.elements[identifier]
        if intermediateElement == nil {
            do {
                intermediateElement = try createElement(identifier: identifier, inputFormat: buffer.format)
            } catch {
                errorWriter.writeError(message: error.localizedDescription)
                return
            }
        }
        var element = intermediateElement!

        defer {
            elements[identifier] = element
        }

        let copied = TPCircularBufferCopyAudioBufferList(&element.buffer,
                                                         &list,
                                                         nil,
                                                         kTPCircularBufferCopyAll,
                                                         nil)
        element.metrics.copyAttempts += 1
        guard copied else {
            element.metrics.copyFails += 1
            return
        }
    }

    private func createElement(identifier: UInt32, inputFormat: AVAudioFormat) throws -> Element {
        guard elements[identifier] == nil else { fatalError() }
        print("AudioPlayer => [\(identifier)] New player: \(inputFormat)")
        if !engine.isRunning {
            try engine.start()
        }

        // Create the circular buffer.
        var buffer: TPCircularBuffer = .init()
        let created = _TPCircularBufferInit(&buffer,
                                            1,
                                            MemoryLayout<TPCircularBuffer>.size)
        guard created else {
            fatalError()
        }

        let absd = inputFormat.streamDescription.pointee
        let node: AVAudioSourceNode = .init(format: inputFormat) { silence, timestamp, numFrames, data in
            self.renderFunction(silence: silence,
                                timestamp: timestamp,
                                numFrames: numFrames,
                                data: data,
                                absd: absd,
                                identifier: identifier)
        }
        engine.attach(node)
        engine.connect(node, to: mixer, format: nil)
        return .init(player: node, buffer: buffer, metrics: .init())
    }

    // swiftlint:disable function_parameter_count
    @inline(__always)
    private func renderFunction(silence: UnsafeMutablePointer<ObjCBool>,
                                timestamp: UnsafePointer<AudioTimeStamp>,
                                numFrames: AVAudioFrameCount,
                                data: UnsafeMutablePointer<AudioBufferList>,
                                absd: AudioStreamBasicDescription,
                                identifier: UInt32) -> OSStatus {
        // Ensure we can access the resources.
        guard Self.getLock(atomic: &self.elementsLock) == true else {
            // We didn't get the lock. We'll have to drop this audio.
            OSAtomicIncrement32(&self.readContentions)
            Self.fillSilence(data: data,
                             numFrames: numFrames,
                             absd: absd,
                             copiedFrames: 0,
                             silence: silence)
            return .zero
        }

        defer { Self.unlock(atomic: &self.elementsLock) }

        guard var element = elements[identifier] else {
            fatalError()
        }

        defer {
            self.elements[identifier] = element
        }

        // Fill the buffers as best we can.
        var copiedFrames: UInt32 = numFrames
        var absd = absd
        TPCircularBufferDequeueBufferListFrames(&element.buffer,
                                                &copiedFrames,
                                                data,
                                                .init(mutating: timestamp),
                                                &absd)
        element.metrics.reads += 1
        guard copiedFrames == numFrames else {
            // Ensure any incomplete data is pure silence.
            Self.fillSilence(data: data,
                             numFrames: numFrames,
                             absd: absd,
                             copiedFrames: copiedFrames,
                             silence: silence)
            element.metrics.incompleteFrames += 1
            return .zero
        }
        return .zero
    }
    // swiftlint:enable function_parameter_count

    @inline(__always)
    private static func fillSilence(data: UnsafeMutablePointer<AudioBufferList>,
                                    numFrames: AVAudioFrameCount,
                                    absd: AudioStreamBasicDescription,
                                    copiedFrames: UInt32,
                                    silence: UnsafeMutablePointer<ObjCBool>) {
        let buffers: UnsafeMutableAudioBufferListPointer = .init(data)
        for buffer in buffers {
            guard let dataPointer = buffer.mData else {
                break
            }
            let discontinuityStartOffset = Int(copiedFrames * absd.mBytesPerFrame)
            let numberOfSilenceBytes = Int((numFrames - copiedFrames) * absd.mBytesPerFrame)
            guard discontinuityStartOffset + numberOfSilenceBytes == buffer.mDataByteSize else {
                print("[FasterAVEngineAudioPlayer] Invalid buffers when calculating silence")
                break
            }
            memset(dataPointer + discontinuityStartOffset, 0, Int(numberOfSilenceBytes))
            let thisBufferSilence = numberOfSilenceBytes == buffer.mDataByteSize
            let silenceSoFar = silence.pointee.boolValue
            silence.pointee = .init(thisBufferSilence && silenceSoFar)
        }
    }

    func removePlayer(identifier: UInt32) {
        removeElement(identifier: identifier, lock: true)
    }

    private func removeElement(identifier: UInt32, lock: Bool) {
        if lock {
            // Spin until we can remove.
            var contention = false
            while Self.getLock(atomic: &elementsLock) != true {
                if !contention {
                    OSAtomicIncrement32(&self.writeContentions)
                    contention = true
                }
            }
        }

        defer {
            if lock {
                Self.unlock(atomic: &elementsLock)
            }
        }

        guard var element = elements.removeValue(forKey: identifier) else { return }
        print("[FasterAVAudioEngine] Removing \(identifier)")

        // Dispose of the element's resources.
        engine.disconnectNodeInput(element.player)
        engine.detach(element.player)
        element.player.reset()
        TPCircularBufferCleanup(&element.buffer)

        // Report metrics on leave.
        print("They had \(element.metrics.copyFails)/\(element.metrics.copyAttempts) copy fails")
        print("They had \(element.metrics.incompleteFrames)/\(element.metrics.reads) incomplete reads")
        print("They had \(readContentions)/\(element.metrics.copyAttempts) contentions")
        print("They had \(writeContentions) write contentions")
    }
}
