import AVFoundation
import Flutter

final class AudioCaptureEventStreamHandler {
    private let audioCapture = AudioCapture()
    private var queue: CaptureQueue?
    private var observers: [NSObjectProtocol] = []
    private var generation: Int64 = 0
    private var clientId: String?
    private var actualSampleRate: Double?

    func start(_ args: [String: Any]) throws -> [String: Any] {
        stop(nil)
        let frames = args["bufferSize"] as? Int ?? 512
        let rate = (args["sampleRate"] as? NSNumber)?.doubleValue ?? 44100
        guard (64...8192).contains(frames), (8000...192000).contains(rate) else {
            throw failure("Invalid capture format")
        }
        // The host prefers the built-in mic; any routed input records, as before timestamps.
        guard let input = AVAudioSession.sharedInstance().currentRoute.inputs.first else { throw failure("No audio input") }
        generation += 1
        clientId = args["clientId"] as? String
        let next = CaptureQueue(frames: frames, capacity: CaptureQueue.capacity(sampleRate: rate, frames: frames))
        queue = next
        observeRoute(next, inputUid: input.uid)
        do {
            try audioCapture.startSession(bufferSize: UInt32(frames), sampleRate: rate, queue: next)
            observeEngine(next)
            actualSampleRate = rate
            return ["generation": generation, "sampleRate": rate, "inputId": input.uid]
        } catch {
            next.close(error)
            queue = nil
            removeObservers()
            throw error
        }
    }

    // Output-only and category changes keep the mic.
    private func observeRoute(_ next: CaptureQueue, inputUid: String) {
        observers = [
            NotificationCenter.default.addObserver(forName: AVAudioSession.routeChangeNotification, object: nil, queue: nil) { _ in
                guard AVAudioSession.sharedInstance().currentRoute.inputs.first?.uid != inputUid else { return }
                next.close(Self.invalidated("Audio input changed; restart capture"))
            },
        ]
    }

    // After start, so the app's pre-start session setup can't close it; a real reconfiguration stops the engine first.
    private func observeEngine(_ next: CaptureQueue) {
        let engine = audioCapture.audioEngine
        observers.append(NotificationCenter.default.addObserver(forName: .AVAudioEngineConfigurationChange,
            object: engine, queue: nil) { _ in
            guard !engine.isRunning else { return }
            next.close(Self.invalidated("Audio engine reconfigured; restart capture"))
        })
    }

    private func removeObservers() {
        for observer in observers { NotificationCenter.default.removeObserver(observer) }
        observers = []
    }

    private static func invalidated(_ message: String) -> NSError {
        NSError(domain: "AudioCapture", code: -2, userInfo: [NSLocalizedDescriptionKey: message])
    }

    func read(_ args: [String: Any]) throws -> [[String: Any]] {
        guard let queue = queue, let rate = actualSampleRate,
              (args["generation"] as? NSNumber)?.int64Value == generation else {
            throw failure("Stale or stopped capture")
        }
        return try queue.take(generation: generation, rate: rate, maximum: args["maxBlocks"] as? Int ?? 8).map { block in
            ["generation": block.generation, "sequence": block.sequence, "firstFrame": block.firstFrame,
             "captureTimeNs": block.captureTimeNs,
             "discontinuity": block.discontinuity, "sampleRate": block.sampleRate, "frameCount": block.frameCount,
             "audioData": FlutterStandardTypedData(float32: block.audioData)]
        }
    }

    func stop(_ token: Int64?, clientId: String? = nil) {
        if let id = clientId, id != self.clientId { return }
        if let token = token, token != generation { return }
        removeObservers()
        guard let old = queue else { return }
        queue = nil
        old.close()
        audioCapture.stopSession()
        actualSampleRate = nil
    }

    static func clock() -> Int64 { CaptureSampleClock.hostNs(mach_absolute_time()) }
    private func failure(_ message: String) -> NSError {
        NSError(domain: "AudioCapture", code: -1, userInfo: [NSLocalizedDescriptionKey: message])
    }
}
