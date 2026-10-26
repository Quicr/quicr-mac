// SPDX-FileCopyrightText: Copyright (c) 2023 Cisco Systems
// SPDX-License-Identifier: BSD-2-Clause

import AVFAudio
import Synchronization

/// Registration of audio playout sources, as required by playing subscriptions.
protocol AudioPlayout: AnyObject {
    func addPlayer(identifier: SourceIDType, node: AVAudioSourceNode) throws
    func removePlayer(identifier: SourceIDType) throws
}

/// Wrapper for app specific `AVAudioEngine` functionality.
final class DecimusAudioEngine: AudioPlayout, @unchecked Sendable {
    /// The audio format the application should use.
    static let format: AVAudioFormat = .init(commonFormat: .pcmFormatFloat32,
                                             sampleRate: .opus48khz,
                                             channels: 1,
                                             interleaved: false)!

    private let logger: DecimusLogger = .init(DecimusAudioEngine.self)

    /// Microphone data is enqueued into this buffer. Only the engine writes to it.
    let microphoneBuffer: CircularBuffer.Reader?
    private let microphoneWriter: CircularBuffer.Writer?

    // The AVAudioEngine instance this AudioEngine wraps.
    private var engine: AVAudioEngine?
    private let sessionTransition: (@Sendable (Bool) async throws -> Void)?
    private let notifications: NotificationCenter
    private var notificationObservers: [NSObjectProtocol] = []
    private var sink: AVAudioSinkNode?
    private let control: DispatchQueue
    private var shouldRun = false
    private var interrupted = false
    private var generation = UUID()
    private var lifecycleTask: Task<Void, Never>?
    private var elements: [SourceIDType: AVAudioSourceNode] = [:]
    private let inputNodePresent: Bool
    private let outputNodePresent: Bool
    private let captureAudio = Atomic(false)
    private let inputMuted = Atomic(false)

    private lazy var reconfigure: @Sendable (Notification) -> Void = { [weak self] _ in
        self?.control.async { [weak self] in
            self?.requestRestart()
        }
    }

    #if !os(macOS)
    private lazy var interupt: @Sendable (Notification) -> Void = { [weak self] notification in
        guard let typeValue = notification.userInfo?[AVAudioSessionInterruptionTypeKey] as? UInt,
              let type = AVAudioSession.InterruptionType(rawValue: typeValue) else { return }
        let optionsValue = notification.userInfo?[AVAudioSessionInterruptionOptionKey] as? UInt ?? 0
        let resume = AVAudioSession.InterruptionOptions(rawValue: optionsValue).contains(.shouldResume)
        self?.control.async { [weak self] in
            guard let self else { return }
            switch type {
            case .began:
                self.interrupted = true
                self.generation = UUID()
                self.engine?.stop()
            case .ended:
                guard resume else { return }
                self.interrupted = false
                self.requestRestart()
            @unknown default:
                break
            }
        }
    }

    private lazy var reset: @Sendable (Notification) -> Void = { [weak self] _ in
        self?.logger.warning("Media services reset. Please report this.", alert: true)
    }

    private lazy var routeChange: @Sendable (Notification) -> Void = { [weak self] notification in
        guard let reasonValue = notification.userInfo?[AVAudioSessionRouteChangeReasonKey] as? UInt,
              AVAudioSession.RouteChangeReason(rawValue: reasonValue) == .routeConfigurationChange else { return }
        self?.control.async { [weak self] in
            self?.requestRestart()
        }
    }
    #endif

    /// Create a new app audio engine, configuring the session, formats, I/O devices, and processing.
    /// - Throws: Any of the many possible errors during setup.
    init(engine: AVAudioEngine = AVAudioEngine(), // swiftlint:disable:this function_body_length
         notifications: NotificationCenter = .default,
         sessionTransition: (@Sendable (Bool) async throws -> Void)? = nil) async throws {
        let control = DispatchQueue(label: "DecimusAudioEngine.control")
        self.control = control
        self.notifications = notifications
        self.sessionTransition = sessionTransition
        #if !os(macOS)
        let session = AVAudioSession.sharedInstance()
        try session.setSupportsMultichannelContent(false)
        let options: AVAudioSession.CategoryOptions
        #if os(tvOS)
        options = []
        #else
        options = [.defaultToSpeaker, .allowBluetoothHFP, .mixWithOthers]
        #endif
        try session.setCategory(.playAndRecord,
                                mode: .videoChat,
                                options: options)

        // Check for the presence of an input node without querying it.
        try await Self.setSessionActive(true, on: control)
        if let availableInputs = session.availableInputs,
           availableInputs.count > 0 {
            // Should be safe to query input node now.
            let inputFormat = engine.inputNode.inputFormat(forBus: 0)
            let valid = inputFormat.sampleRate > 0 && inputFormat.channelCount > 0
            guard valid else {
                throw "Input exists w/ bad format. Aggregate device broken. Report this."
            }
            self.inputNodePresent = true
        } else {
            self.inputNodePresent = false
        }
        #else
        self.inputNodePresent = true
        #endif

        if !self.inputNodePresent {
            self.logger.warning("Couldn't find a microphone to use", alert: true)
        }
        let outputFormat = engine.outputNode.outputFormat(forBus: 0)
        self.outputNodePresent = outputFormat.sampleRate > 0 && outputFormat.channelCount > 0
        if !self.outputNodePresent {
            self.logger.warning("Couldn't find a speaker to use", alert: true)
        }

        // Enable voice processing.
        if self.outputNodePresent && self.inputNodePresent {
            if !engine.outputNode.isVoiceProcessingEnabled {
                do {
                    try SwiftInterop.catchException { [logger] in
                        do {
                            try engine.outputNode.setVoiceProcessingEnabled(true)
                        } catch {
                            logger.warning("Failed to enable voice processing: \(error.localizedDescription)")
                        }
                    }
                } catch {
                    self.logger.warning("Failed to enable voice processing: \(error.localizedDescription)")
                }
            }
        }
        self.engine = engine

        // Ducking.
        if self.inputNodePresent {
            #if !os(tvOS)
            if #available(iOS 17.0, macOS 14.0, macCatalyst 17.0, visionOS 1.0, *) {
                let ducking: AVAudioVoiceProcessingOtherAudioDuckingConfiguration = .init(enableAdvancedDucking: false,
                                                                                          duckingLevel: .min)
                engine.inputNode.voiceProcessingOtherAudioDuckingConfiguration = ducking
            }
            #endif

            // Capture microphone audio.
            let inputFormat = Self.format.streamDescription.pointee

            let microphone = try CircularBuffer.makeSPSC(length: 1, format: inputFormat)
            self.microphoneBuffer = microphone.reader
            self.microphoneWriter = microphone.writer
            let sink = AVAudioSinkNode { [weak self] timestamp, frames, data in
                guard let self = self,
                      let microphoneWriter = self.microphoneWriter,
                      self.captureAudio.load(ordering: .acquiring) else { return 1 }
                let example = UnsafeMutablePointer(mutating: data)
                let timestamp = UnsafeMutablePointer(mutating: timestamp)
                do {
                    try microphoneWriter.enqueue(buffer: &example.pointee,
                                                 timestamp: &timestamp.pointee,
                                                 frames: frames)
                    return .zero
                } catch CircularBufferError.clearPending {
                    // Stale capture is being discarded, this audio predates the unmute.
                    return .zero
                } catch {
                    self.logger.warning("Couldn't enqueue microphone data: \(error.localizedDescription)")
                    return 1
                }
            }
            engine.attach(sink)
            self.sink = sink
        } else {
            self.sink = nil
            self.microphoneBuffer = nil
            self.microphoneWriter = nil
        }

        // Reconfigure first time.
        try localReconfigure()

        // Register interest in reconfigure events.
        notificationObservers.append(notifications.addObserver(forName: .AVAudioEngineConfigurationChange,
                                                               object: engine,
                                                               queue: nil,
                                                               using: reconfigure))
        #if !os(macOS)
        notificationObservers.append(notifications.addObserver(forName: AVAudioSession.interruptionNotification,
                                                               object: AVAudioSession.sharedInstance(),
                                                               queue: nil,
                                                               using: interupt))
        let resetName = AVAudioSession.mediaServicesWereResetNotification
        notificationObservers.append(notifications.addObserver(forName: resetName,
                                                               object: AVAudioSession.sharedInstance(),
                                                               queue: nil,
                                                               using: reset))
        notificationObservers.append(notifications.addObserver(forName: AVAudioSession.routeChangeNotification,
                                                               object: AVAudioSession.sharedInstance(),
                                                               queue: nil,
                                                               using: routeChange))
        #endif
    }

    deinit {
        for observer in notificationObservers {
            self.notifications.removeObserver(observer)
        }

        // Drop instance reference first as DSP teardown can block.
        let retiredEngine = Mutex(self.engine)
        self.engine = nil
        self.control.async(qos: .default, flags: .enforceQoS) {
            retiredEngine.withLock { $0 = nil }
        }
    }

    func setMicrophoneCapture(_ enabled: Bool) {
        if enabled, let microphoneWriter = self.microphoneWriter {
            // Discard whatever was captured before this unmute. The encoder performs the clear.
            _ = microphoneWriter.requestClear()
        }
        self.captureAudio.store(enabled, ordering: .releasing)
    }

    private final class StartRequest: Sendable {
        let generation = UUID()
        let cancelled = Atomic(false)
    }

    /// Run the audio engine, awaiting session activation before starting I/O.
    func start() async throws {
        let request = StartRequest()
        try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, any Error>) in
                control.async {
                    guard !request.cancelled.load(ordering: .acquiring) else {
                        continuation.resume(throwing: CancellationError())
                        return
                    }
                    self.shouldRun = true
                    self.interrupted = false
                    self.generation = request.generation
                    self.schedule(continuation: continuation) {
                        do {
                            try await self.startEngine(generation: request.generation)
                        } catch {
                            let current = try await self.onControl {
                                guard self.generation == request.generation else { return false }
                                self.shouldRun = false
                                return true
                            }
                            if current { try? await self.setSessionActive(false) }
                            throw error
                        }
                    }
                }
            }
        } onCancel: {
            request.cancelled.store(true, ordering: .releasing)
            self.control.async {
                guard self.generation == request.generation else { return }
                self.requestStop()
            }
        }
    }

    /// Stop I/O even if Apple has already stopped the engine during a route change.
    func stop() async throws {
        try await withCheckedThrowingContinuation { continuation in
            self.control.async {
                self.requestStop(continuation: continuation)
            }
        }
    }

    private func requestStop(continuation: CheckedContinuation<Void, any Error>? = nil) {
        self.shouldRun = false
        self.generation = UUID()
        let generation = self.generation
        self.engine?.stop()
        self.schedule(continuation: continuation) {
            let current = try await self.onControl { self.generation == generation }
            guard current else { return }
            try await self.setSessionActive(false)
        }
    }

    /// Add a source node to this engine, to be mixed with any others.
    /// - Parameter identifier: Identifier for this source.
    /// - Parameter node: The source node supplying audio.
    /// - Throws: Error if the target node has already been added.
    func addPlayer(identifier: SourceIDType, node: AVAudioSourceNode) throws {
        try self.control.sync {
            guard let engine = self.engine else { throw "Audio engine unavailable" }
            guard elements[identifier] == nil else { throw "Add called for existing entry" }
            engine.attach(node)
            do {
                try self.connect(node, to: engine.mainMixerNode)
            } catch {
                engine.detach(node)
                throw error
            }
            self.elements[identifier] = node
        }
        self.logger.info("(\(identifier)) Attached node")
    }

    /// Remove a previously added source node.
    /// - Parameter identifier: Identifier of the source node to remove.
    /// - Throws: Error if the source node has not beed added,
    func removePlayer(identifier: SourceIDType) throws {
        try self.control.sync {
            guard let element = elements.removeValue(forKey: identifier) else {
                throw "Remove called for non existent entry"
            }
            self.engine?.detach(element)
        }
        self.logger.info("(\(identifier)) Removed player node")
    }

    /// Is the microphone / input device currently muted?
    /// - Returns: True if muted, or if no input device available.
    func isInputMuted() -> Bool {
        self.inputNodePresent ? self.inputMuted.load(ordering: .acquiring) : true
    }

    /// Toggle mute status.
    /// - Returns: The new mute state.
    @discardableResult
    func toggleMute() -> Bool {
        guard self.inputNodePresent else { return true }
        return self.control.sync {
            let muted = !self.inputMuted.load(ordering: .acquiring)
            self.inputMuted.store(muted, ordering: .releasing)
            self.applyInputMuteState()
            return muted
        }
    }

    /// Register a callback for notifications of speech detection while mutex.
    /// - Parameter block: The callback to receive the muted speech event.
    @available(iOS 17.0, macOS 14.0, macCatalyst 17.0, tvOS 17.0, visionOS 1.0, *)
    func setMutedSpeechActivityEventListener(_ block: ((AVAudioVoiceProcessingSpeechActivityEvent) -> Void)?) throws {
        guard self.inputNodePresent else { return }
        try self.control.sync {
            guard let engine = self.engine else { return }
            guard engine.inputNode.setMutedSpeechActivityEventListener(block) else {
                throw "Couldn't set muted speech listener"
            }
        }
    }

    private func localReconfigure() throws {
        guard let engine = self.engine else { throw "Audio engine unavailable" }
        #if !os(macOS)
        // Reconfigure the audio session.
        let session: AVAudioSession = .sharedInstance()
        try session.setPreferredSampleRate(Self.format.sampleRate)

        // Inputs
        if self.inputNodePresent,
           Self.format.channelCount <= session.maximumInputNumberOfChannels {
            try session.setPreferredInputNumberOfChannels(Int(Self.format.channelCount))
        }

        // Outputs
        if self.outputNodePresent,
           Self.format.channelCount <= session.maximumOutputNumberOfChannels {
            try session.setPreferredOutputNumberOfChannels(Int(Self.format.channelCount))
        }
        #endif

        guard !engine.isRunning else { throw "Cannot reconfigure a running audio engine" }

        // Sink for microphone output.
        if self.inputNodePresent {
            guard let sink = self.sink else {
                throw "Sink should be present when input node present"
            }
            try self.connect(engine.inputNode, to: sink)
            assert(engine.inputNode.numberOfOutputs == 1)
            let inputOutputFormat = engine.inputNode.outputFormat(forBus: 0)
            self.logger.info("Connected microphone: \(inputOutputFormat)")
            assert(inputOutputFormat == Self.format)
            assert(sink.numberOfInputs == 1)
            assert(sink.inputFormat(forBus: 0) == Self.format)
        }

        // Mixer for player nodes.
        if self.outputNodePresent {
            try self.connect(engine.mainMixerNode, to: engine.outputNode)
            assert(engine.mainMixerNode.numberOfOutputs == 1)
            let mixerOutputFormat = engine.mainMixerNode.outputFormat(forBus: 0)
            self.logger.info("Connected mixer: \(mixerOutputFormat)")
            assert(mixerOutputFormat == Self.format)

            // Sanity check the output format.
            assert(engine.outputNode.numberOfInputs == 1)
            if self.inputNodePresent && self.outputNodePresent {
                assert(engine.outputNode.isVoiceProcessingEnabled)
            }
            assert(engine.outputNode.inputFormat(forBus: 0) == Self.format)
        }

        // We shouldn't need to reconnect source nodes to the mixer,
        // as the format should not have changed.
        for element in self.elements.values {
            assert(element.numberOfOutputs == 1)
            assert(element.outputFormat(forBus: 0) == Self.format)
        }
    }

    private func applyInputMuteState() {
        guard self.inputNodePresent else { return }
        self.engine?.inputNode.isVoiceProcessingInputMuted = self.inputMuted.load(ordering: .acquiring)
    }

    private func connect(_ source: AVAudioNode, to destination: AVAudioNode) throws {
        guard let engine = self.engine else { throw "Audio engine unavailable" }
        if #available(iOS 27.0, macOS 27.0, macCatalyst 27.0, tvOS 27.0, visionOS 27.0, *) {
            try engine.connectNode(source, to: destination, format: Self.format)
        } else {
            try SwiftInterop.catchException {
                engine.connect(source, to: destination, format: Self.format)
            }
        }
    }

    // Called on control; notification callbacks never synchronously enter the engine.
    private func requestRestart() {
        guard self.shouldRun,
              !self.interrupted else { return }
        let generation = self.generation
        self.schedule {
            let needed = try await self.onControl {
                self.shouldRun && !self.interrupted && self.generation == generation && self.engine?.isRunning == false
            }
            guard needed else { return }
            try await self.startEngine(generation: generation)
        }
    }

    private func startEngine(generation: UUID) async throws {
        try await self.onControl { try self.checkStart(generation: generation) }
        try await self.setSessionActive(true)
        try await self.onControl {
            try self.checkStart(generation: generation)
            guard let engine = self.engine else { throw "Audio engine unavailable" }
            guard !engine.isRunning else { return }
            try self.localReconfigure()
            try engine.start()
            self.applyInputMuteState()
        }
    }

    private func checkStart(generation: UUID) throws {
        guard self.shouldRun,
              !self.interrupted,
              self.generation == generation else {
            throw CancellationError()
        }
    }

    private func setSessionActive(_ active: Bool) async throws {
        if let sessionTransition {
            try await sessionTransition(active)
            return
        }
        try await Self.setSessionActive(active, on: control)
    }

    private static func setSessionActive(_ active: Bool, on control: DispatchQueue) async throws {
        #if !os(macOS)
        let session = AVAudioSession.sharedInstance()
        if #available(iOS 27.0, macCatalyst 27.0, tvOS 27.0, visionOS 27.0, *) {
            do {
                let succeeded: Bool
                if active {
                    succeeded = try await session.activate(options: [])
                } else {
                    succeeded = try await session.deactivate(options: .notifyOthersOnDeactivation)
                }
                guard succeeded else { throw "Audio session activation/deactivation failed" }
                return
            } catch {
                #if targetEnvironment(macCatalyst)
                // Catalyst 27.0.1 exposes these APIs but returns unimpErr for both.
                let sessionError = error as NSError
                guard sessionError.domain == NSOSStatusErrorDomain,
                      sessionError.code == Int(unimpErr) else { throw error }
                #else
                throw error
                #endif
            }
        }
        try await onQueue(control) {
            try session.setActive(active, options: active ? [] : .notifyOthersOnDeactivation)
        }
        #endif
    }

    private func schedule(continuation: CheckedContinuation<Void, any Error>? = nil,
                          operation: @escaping @Sendable () async throws -> Void) {
        let previous = self.lifecycleTask
        self.lifecycleTask = Task {
            await previous?.value
            do {
                try await operation()
                continuation?.resume()
            } catch {
                if let continuation {
                    continuation.resume(throwing: error)
                } else if !(error is CancellationError) {
                    self.logger.error("Failed to restart audio: \(error.localizedDescription)")
                }
            }
        }
    }

    private func onControl<T: Sendable>(_ operation: @escaping @Sendable () throws -> T) async throws -> T {
        try await Self.onQueue(control, operation: operation)
    }

    private static func onQueue<T: Sendable>(_ queue: DispatchQueue,
                                             operation: @escaping @Sendable () throws -> T) async throws -> T {
        try await withCheckedThrowingContinuation { continuation in
            queue.async {
                continuation.resume(with: Result { try operation() })
            }
        }
    }
}
