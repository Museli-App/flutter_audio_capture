import AVFoundation

/// The host owns the audio session; the sink only copies hardware PCM.
public class AudioCapture {
    let audioEngine = AVAudioEngine()
    private var sink: AVAudioSinkNode?
    private var pipeline: CapturePipeline?

    func startSession(bufferSize: UInt32, sampleRate: Double, queue: CaptureQueue) throws {
        stopSession()
        let input = audioEngine.inputNode
        let format = input.outputFormat(forBus: 0)
        let pipeline = try CapturePipeline(format: format, frames: Int(bufferSize), rate: sampleRate, queue: queue)
        let sink = AVAudioSinkNode { timestamp, frames, buffers in
            let stamp = timestamp.pointee
            let valid = stamp.mFlags.contains(.hostTimeValid) && stamp.mFlags.contains(.sampleTimeValid)
                && stamp.mSampleTime.isFinite && stamp.mSampleTime >= Double(Int64.min)
                && stamp.mSampleTime < Double(Int64.max)
            CaptureInputRingOffer(pipeline.ring, buffers, frames,
                valid ? Int64(stamp.mSampleTime) : 0, stamp.mHostTime, valid)
            return noErr
        }
        self.pipeline = pipeline
        self.sink = sink
        audioEngine.attach(sink)
        audioEngine.connect(input, to: sink, format: format)
        pipeline.start()
        do {
            audioEngine.prepare()
            try audioEngine.start()
        } catch {
            stopSession()
            throw error
        }
    }

    public func stopSession() {
        audioEngine.stop()
        if let sink = sink {
            audioEngine.disconnectNodeInput(sink)
            audioEngine.detach(sink)
        }
        sink = nil
        pipeline?.stop()
        pipeline = nil
    }

    deinit { stopSession() }
}

final class CapturePipeline {
    let ring: OpaquePointer
    private let input: AVAudioPCMBuffer
    private let converted: AVAudioPCMBuffer
    private let converter: AVAudioConverter?
    private let frames: Int
    private let pending: UnsafeMutablePointer<Float>
    private let queue: CaptureQueue
    private var clock: CaptureSampleClock
    private var filled = 0
    private(set) var emitted: Int64 = 0
    private var nextInputSample: Int64?
    private var gap = false
    private var worker: Thread?
    private let finished = DispatchGroup()

    init(format: AVAudioFormat, frames: Int, rate: Double, queue: CaptureQueue) throws {
        let maximumFrames: AVAudioFrameCount = 16384
        guard format.sampleRate > 0, format.channelCount > 0, format.channelCount <= 8,
              format.commonFormat == .pcmFormatFloat32, frames > 0, rate > 0,
              let output = AVAudioFormat(commonFormat: .pcmFormatFloat32,
                sampleRate: rate, channels: 1, interleaved: false),
              let input = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: maximumFrames),
              let converted = AVAudioPCMBuffer(pcmFormat: output,
                frameCapacity: AVAudioFrameCount(ceil(Double(maximumFrames) * rate / format.sampleRate)) + 4096)
        else { throw Self.failure("Invalid capture format or buffer allocation") }
        let conversionNeeded = format.sampleRate != rate || format.channelCount != 1 || format.isInterleaved
        let converter = conversionNeeded ? AVAudioConverter(from: format, to: output) : nil
        guard !conversionNeeded || converter != nil else { throw Self.failure("Cannot create converter") }
        converter?.sampleRateConverterQuality = AVAudioQuality.high.rawValue
        let planes = format.isInterleaved ? 1 : format.channelCount
        guard let ring = CaptureInputRingCreate(32, maximumFrames, planes,
            format.streamDescription.pointee.mBytesPerFrame) else {
            throw Self.failure("Cannot allocate lock-free capture storage")
        }
        self.ring = ring
        self.input = input
        self.converted = converted
        self.converter = converter
        self.frames = frames
        self.queue = queue
        clock = CaptureSampleClock(inputRate: format.sampleRate, outputRate: rate)
        pending = .allocate(capacity: frames)
        pending.initialize(repeating: 0, count: frames)
    }

    func start() {
        finished.enter()
        let thread = Thread { [self] in
            defer { finished.leave() }
            run()
        }
        thread.name = "museli.capture.convert"
        thread.qualityOfService = .userInitiated
        worker = thread
        thread.start()
    }

    func stop() {
        CaptureInputRingClose(ring)
        if worker != nil { finished.wait(); worker = nil }
    }

    private func run() {
        do {
            while !CaptureInputRingIsClosed(ring) {
                if try !drainOnce() { Thread.sleep(forTimeInterval: 0.002) }
            }
        } catch { queue.close(error) }
    }

    /// Converts one ring packet into the queue; false when none is ready.
    func drainOnce() throws -> Bool {
        var packet = CaptureInputPacket()
        input.frameLength = input.frameCapacity
        guard CaptureInputRingRead(ring, input.mutableAudioBufferList, &packet) else {
            let error = CaptureInputRingError(ring)
            if error != 0 { throw Self.failure("Input callback failed (\(error))") }
            return false
        }
        input.frameLength = packet.frameCount
        try process(packet)
        return true
    }

    private func process(_ packet: CaptureInputPacket) throws {
        let captureNs = CaptureSampleClock.hostNs(packet.hostTicks)
        let inputGap = packet.discontinuity || (nextInputSample.map { $0 != packet.inputFrame } ?? false)
        if clock.observe(inputFrame: packet.inputFrame, hostNs: captureNs,
            outputFrame: emitted, discontinuity: inputGap) {
            filled = 0
            converter?.reset()
            gap = true
        }
        nextInputSample = packet.inputFrame + Int64(packet.frameCount)
        let pcm: AVAudioPCMBuffer
        if let converter = converter {
            var supplied = false
            var error: NSError?
            converted.frameLength = 0
            let status = converter.convert(to: converted, error: &error) { [input] _, status in
                if supplied { status.pointee = .noDataNow; return nil }
                supplied = true
                status.pointee = .haveData
                return input
            }
            if let error = error { throw error }
            guard status != .error else { throw Self.failure("Audio conversion failed") }
            pcm = converted
        } else { pcm = input }
        guard let samples = pcm.floatChannelData?[0] else { throw Self.failure("Expected Float32 input") }
        var cursor = 0
        while cursor < Int(pcm.frameLength) {
            let count = min(frames - filled, Int(pcm.frameLength) - cursor)
            pending.advanced(by: filled).update(from: samples.advanced(by: cursor), count: count)
            filled += count
            cursor += count
            if filled < frames { continue }
            queue.offer(pending, position: emitted, timeNs: clock.time(outputFrame: emitted), discontinuity: gap)
            emitted += Int64(frames)
            filled = 0
            gap = false
        }
    }

    private static func failure(_ message: String) -> NSError {
        NSError(domain: "AudioCapture", code: -1, userInfo: [NSLocalizedDescriptionKey: message])
    }

    deinit {
        pending.deinitialize(count: frames)
        pending.deallocate()
        CaptureInputRingDestroy(ring)
    }
}

/// Retains converter phase while following the hardware clock on every tap.
struct CaptureSampleClock {
    let inputRate: Double
    let outputRate: Double
    private var firstInputFrame: Int64?
    private var firstOutputFrame: Int64 = 0
    private var originNs: Int64 = 0

    init(inputRate: Double, outputRate: Double) {
        self.inputRate = inputRate
        self.outputRate = outputRate
    }

    /// The one host-tick conversion; capture stamps and the Dart clock exchange must agree.
    static func hostNs(_ ticks: UInt64) -> Int64 {
        Int64(AVAudioTime.seconds(forHostTime: ticks) * 1_000_000_000)
    }

    mutating func observe(inputFrame: Int64, hostNs: Int64, outputFrame: Int64,
        discontinuity: Bool = false) -> Bool {
        var gap = discontinuity
        if let first = firstInputFrame, !gap {
            let projected = hostNs - Int64(Double(inputFrame - first) * 1_000_000_000 / inputRate)
            gap = abs(projected - originNs) > 5_000_000
            if !gap { originNs = projected; return false }
        }
        firstInputFrame = inputFrame
        firstOutputFrame = outputFrame
        originNs = hostNs
        return gap
    }

    func time(outputFrame: Int64) -> Int64 {
        originNs + Int64(Double(outputFrame - firstOutputFrame) * 1_000_000_000 / outputRate)
    }
}
