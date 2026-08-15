import AVFoundation

/// `AudioCapture` taps the audio input node and delivers Float32 mono PCM in
/// fixed `bufferSize`-frame chunks.
///
/// The audio session (category / mode / preferred sample rate) is owned by the
/// host app; this plugin never touches `AVAudioSession`.
///
/// All per-session mutable state (converter, pending samples) is captured by
/// the tap closure and touched only on the tap's render thread, so start/stop
/// on the platform thread never race it. The class itself holds only the
/// engine.
public class AudioCapture {
    /// `audioEngine` is an instance of `AVAudioEngine` used for audio input.
    let audioEngine = AVAudioEngine()

    /// `startSession` starts the audio recording session.
    /// It installs a tap on the input node of the audio engine to capture audio data.
    /// - Parameters:
    ///   - bufferSize: Frames per emitted chunk. iOS clamps `installTap`'s own
    ///     buffer size up to ~100 ms whatever is asked, so the requested
    ///     granularity is honoured by re-chunking here instead.
    ///   - sampleRate: The sample rate to convert the captured audio to.
    ///   - cb: A callback function that is called with the audio data and sample rate.
    /// - Returns: The sample rate the emitted samples are actually at.
    /// - Throws: An error if the audio engine could not be started.
    public func startSession(bufferSize: UInt32, sampleRate: Double, cb: @escaping (FlutterStandardTypedData?, Double, Error?) -> Void) throws -> Double {
        let inputNode = audioEngine.inputNode
        let inputFormat = inputNode.inputFormat(forBus: 0)

        guard inputFormat.sampleRate > 0, inputFormat.channelCount > 0 else {
            throw AudioCapture.failure("Invalid input format")
        }
        guard let outputFormat = AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: sampleRate, channels: 1, interleaved: false) else {
            throw AudioCapture.failure("Invalid output format")
        }

        // When the hardware already delivers what was asked for, ship the tap
        // buffer untouched — no resampler is the best resampler, and it is the
        // path the app takes when it requests the session's own rate.
        let needsConversion = inputFormat.sampleRate != outputFormat.sampleRate
            || inputFormat.channelCount != outputFormat.channelCount
            || inputFormat.commonFormat != outputFormat.commonFormat

        // ONE converter for the session: a resampler carries polyphase filter
        // state across buffers; rebuilding it per callback zeroes that state and
        // splices a priming transient into every chunk boundary.
        let converter: AVAudioConverter?
        if needsConversion {
            guard let c = AVAudioConverter(from: inputFormat, to: outputFormat) else {
                throw AudioCapture.failure("AVAudioConverter initialization failed")
            }
            c.sampleRateConverterQuality = AVAudioQuality.high.rawValue
            converter = c
        } else {
            converter = nil
        }

        // Emissions are always at the requested rate: either the converter
        // produces it, or the input is already at it.
        let reportedRate = outputFormat.sampleRate
        let emitFrames = bufferSize > 0 ? Int(bufferSize) : 512

        // Converted samples not yet emitted. Captured by the tap closure and
        // touched only on its thread; any sub-chunk tail dies with the closure
        // on stop.
        var pending = [Float]()
        pending.reserveCapacity(emitFrames * 16)

        inputNode.installTap(onBus: 0, bufferSize: bufferSize, format: inputFormat) { (buffer, _) in
            do {
                pending.append(contentsOf: try AudioCapture.samples(from: buffer, converter: converter, outputFormat: outputFormat))
            } catch {
                cb(nil, reportedRate, error)
                return
            }
            // Emit whole chunks via a cursor, then compact ONCE — not one O(n)
            // removeFirst per chunk on the render thread.
            var start = 0
            while pending.count - start >= emitFrames {
                let data = pending[start..<start + emitFrames].withUnsafeBufferPointer { Data(buffer: $0) }
                cb(FlutterStandardTypedData(float32: data), reportedRate, nil)
                start += emitFrames
            }
            if start > 0 { pending.removeFirst(start) }
        }

        do {
            try audioEngine.start()
        } catch {
            // Leave no tap behind: a second installTap on a tapped bus is an
            // uncatchable ObjC exception.
            inputNode.removeTap(onBus: 0)
            throw error
        }
        return reportedRate
    }

    /// `stopSession` stops the audio recording session.
    /// It removes the tap on the input node of the audio engine and stops the audio engine.
    public func stopSession() {
        audioEngine.inputNode.removeTap(onBus: 0)
        audioEngine.stop()
    }

    /// The tap buffer's Float32 mono samples, converted only if it has to be.
    private static func samples(from buffer: AVAudioPCMBuffer, converter: AVAudioConverter?, outputFormat: AVAudioFormat) throws -> [Float] {
        guard let converter = converter else {
            return try floats(of: buffer)
        }

        // Room for this buffer's worth of output (+1 rounding slack); the
        // converter retains anything that doesn't fit and emits it next call.
        let ratio = outputFormat.sampleRate / buffer.format.sampleRate
        let capacity = AVAudioFrameCount((Double(buffer.frameLength) * ratio).rounded(.up)) + 1
        guard let out = AVAudioPCMBuffer(pcmFormat: outputFormat, frameCapacity: capacity) else {
            throw failure("Could not allocate the converted buffer")
        }

        // One-shot input: this buffer is offered exactly once. The resulting
        // `.inputRanDry` is success — it means the converter drained everything
        // it was given rather than looping back over it.
        var supplied = false
        var error: NSError?
        let status = converter.convert(to: out, error: &error) { _, outStatus in
            if supplied {
                outStatus.pointee = .noDataNow
                return nil
            }
            supplied = true
            outStatus.pointee = .haveData
            return buffer
        }

        if let error = error { throw error }
        if status == .error { throw failure("Audio conversion failed") }
        return try floats(of: out)
    }

    private static func floats(of buffer: AVAudioPCMBuffer) throws -> [Float] {
        guard let channel = buffer.floatChannelData else {
            throw failure("Expected float32 samples")
        }
        return Array(UnsafeBufferPointer(start: channel[0], count: Int(buffer.frameLength)))
    }

    private static func failure(_ message: String) -> NSError {
        return NSError(domain: "AudioCapture", code: -1, userInfo: [NSLocalizedDescriptionKey: message])
    }
}
