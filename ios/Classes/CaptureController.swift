import AVFoundation
import Flutter

final class CaptureController {
    // Recursive, as start stops first. Channel calls arrive on one task queue; detach and rebuilds do not.
    private let lock = NSRecursiveLock()
    private let rebuilds = DispatchQueue(label: "museli.capture.rebuild")
    private let audioCapture = AudioCapture()
    private var queue: CaptureQueue?
    private var observers: [NSObjectProtocol] = []
    private var generation: Int64 = 0
    private var claims = CaptureClaims()
    private var clientId: String?
    private var inputUid: String?

    private func locked<T>(_ body: () throws -> T) rethrows -> T {
        lock.lock()
        defer { lock.unlock() }
        return try body()
    }

    func claim() -> Int64 { locked { claims.claim() } }

    func start(_ args: [String: Any]) throws -> [String: Any] {
        try locked {
            // Before any side effect: a superseded start must leave the current session running.
            guard let owner = (args["owner"] as? NSNumber)?.int64Value else {
                throw captureError("Missing capture owner")
            }
            try claims.admit(owner)
            stop(nil)
            let frames = args["bufferSize"] as? Int ?? 512
            let rate = (args["sampleRate"] as? NSNumber)?.doubleValue ?? 44100
            guard (64...8192).contains(frames), (8000...192000).contains(rate) else {
                throw captureError("Invalid capture format")
            }
            // The host prefers the built-in mic; any routed input records, as before timestamps.
            guard let input = AVAudioSession.sharedInstance().currentRoute.inputs.first else {
                throw captureError("No audio input")
            }
            generation += 1
            clientId = args["clientId"] as? String
            inputUid = input.uid
            let next = CaptureQueue(frames: frames, capacity: CaptureQueue.capacity(sampleRate: rate, frames: frames))
            queue = next
            observeRoute(generation)
            let token = generation
            audioCapture.onReconfigure = { [weak self] in self?.scheduleRebuild(token) }
            do {
                try audioCapture.startSession(bufferSize: UInt32(frames), sampleRate: rate, queue: next)
                return ["generation": generation, "sampleRate": rate]
            } catch {
                next.close(error)
                queue = nil
                removeObservers()
                throw error
            }
        }
    }

    // Output-only and category changes keep the mic; an input change rebuilds. A media reset kills the
    // engine whatever it reports, so it always rebuilds.
    private func observeRoute(_ token: Int64) {
        let center = NotificationCenter.default
        observers = [
            center.addObserver(forName: AVAudioSession.routeChangeNotification, object: nil,
                queue: nil) { [weak self] _ in self?.scheduleRebuild(token) },
            center.addObserver(forName: AVAudioSession.mediaServicesWereResetNotification, object: nil,
                queue: nil) { [weak self] _ in self?.scheduleRebuild(token, force: true) },
        ]
    }

    // Off the notifying thread, so the engine never restarts inside its own notification.
    private func scheduleRebuild(_ token: Int64, force: Bool = false) {
        rebuilds.async { [weak self] in self?.rebuild(token, force: force) }
    }

    /// Keeps capturing through an input change, engine reconfiguration or media reset, as Android does, and marks
    /// the next block discontinuous. One change fires both notifications, so the second finds nothing.
    private func rebuild(_ token: Int64, force: Bool) {
        locked {
            guard token == generation, let current = queue else { return }
            let uid = AVAudioSession.sharedInstance().currentRoute.inputs.first?.uid
            guard force || uid != inputUid || !audioCapture.isRunning else { return }
            do {
                guard let uid = uid else { throw captureError("No audio input") }
                try audioCapture.restart(queue: current)
                inputUid = uid
            } catch {
                // Only a failed rebuild ends capture; the next read reports it.
                current.close(error)
                audioCapture.stopSession()
                removeObservers()
            }
        }
    }

    private func removeObservers() {
        for observer in observers { NotificationCenter.default.removeObserver(observer) }
        observers = []
    }

    func read(_ args: [String: Any]) throws -> [[String: Any]] {
        let current: CaptureQueue = try locked {
            guard let queue = queue, (args["generation"] as? NSNumber)?.int64Value == generation else {
                throw captureError("Stale or stopped capture")
            }
            return queue
        }
        // Waits unlocked, so a detach or rebuild never queues behind an idle read.
        return try current.take().map { block in
            ["sequence": block.sequence, "firstFrame": block.firstFrame, "captureTimeNs": block.captureTimeNs,
             "discontinuity": block.discontinuity, "audioData": FlutterStandardTypedData(float32: block.audioData)]
        }
    }

    func stop(_ token: Int64?, clientId: String? = nil) {
        locked {
            if let id = clientId, id != self.clientId { return }
            if let token = token, token != generation { return }
            removeObservers()
            guard let old = queue else { return }
            queue = nil
            old.close()
            audioCapture.stopSession()
        }
    }

    static func clock() -> Int64 { CaptureSampleClock.hostNs(mach_absolute_time()) }
}
