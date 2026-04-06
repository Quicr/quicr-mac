// SPDX-FileCopyrightText: Copyright (c) 2026 Cisco Systems
// SPDX-License-Identifier: BSD-2-Clause

import AVFAudio
import Accelerate

/// Voice activity detector wrapping libfvad.
class FVADDetector {
    private let inst: OpaquePointer
    private var int16Buffer: [Int16]
    private var scaledBuffer: [Float]

    /// Create a voice activity detector.
    /// - Parameters:
    ///   - sampleRate: Input sample rate. Must be 8000, 16000, 32000, or 48000.
    ///   - mode: Aggressiveness mode 0-3. Higher is more restrictive.
    init(sampleRate: Int, mode: Int) {
        guard let inst = fvad_new() else {
            fatalError("fvad_new() failed")
        }
        self.inst = inst
        guard fvad_set_sample_rate(inst, Int32(sampleRate)) == 0 else {
            fatalError("Invalid sample rate: \(sampleRate)")
        }
        guard fvad_set_mode(inst, Int32(mode)) == 0 else {
            fatalError("Invalid VAD mode: \(mode)")
        }
        self.int16Buffer = []
        self.scaledBuffer = []
    }

    deinit {
        fvad_free(self.inst)
    }

    /// Process a buffer of audio and return whether voice is active.
    /// - Parameter buffer: Mono float32 PCM audio. Frame length must be 10, 20, or 30ms.
    /// - Returns: `true` if voice activity detected.
    func process(_ buffer: AVAudioPCMBuffer) -> Bool {
        guard let floatData = buffer.floatChannelData?[0] else {
            return false
        }
        let count = Int(buffer.frameLength)

        // Resize conversion buffers if needed.
        if self.int16Buffer.count != count {
            self.int16Buffer = [Int16](repeating: 0, count: count)
            self.scaledBuffer = [Float](repeating: 0, count: count)
        }

        // Convert float32 [-1.0, 1.0] to int16 [-32768, 32767].
        var scale: Float = 32767.0
        vDSP_vsmul(floatData, 1, &scale, &self.scaledBuffer, 1, vDSP_Length(count))
        self.int16Buffer.withUnsafeMutableBufferPointer { dst in
            vDSP_vfix16(&self.scaledBuffer, 1, dst.baseAddress!, 1, vDSP_Length(count))
        }

        let result = self.int16Buffer.withUnsafeBufferPointer { src in
            fvad_process(self.inst, src.baseAddress!, count)
        }
        return result == 1
    }
}
