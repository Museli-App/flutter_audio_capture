import Foundation

/// Converted PCM shared by the conversion and platform-channel workers.
struct CapturePacket {
    let generation, sequence, firstFrame, captureTimeNs: Int64
    let discontinuity: Bool
    let sampleRate: Double
    let frameCount: Int
    let audioData: Data
}

final class CaptureQueue {
    /// About two seconds of blocks, so a UI-isolate stall does not overflow.
    static func capacity(sampleRate: Double, frames: Int) -> Int {
        max(32, Int((2.0 * sampleRate / Double(frames)).rounded(.up)))
    }

    private let available = NSCondition()
    private let storage: UnsafeMutablePointer<Float>
    private let frames: Int
    private let capacity: Int
    private var positions: [Int64]
    private var times: [Int64]
    private var sequences: [Int64]
    private var gaps: [Bool]
    private var read = 0
    private var count = 0
    private var closed = false
    private var failure: Error?
    // Producer-only state.
    private var sequence: Int64 = 0
    private var gap = false

    init(frames: Int, capacity: Int) {
        self.frames = frames
        self.capacity = capacity
        positions = [Int64](repeating: 0, count: capacity)
        times = [Int64](repeating: 0, count: capacity)
        sequences = [Int64](repeating: 0, count: capacity)
        gaps = [Bool](repeating: false, count: capacity)
        storage = .allocate(capacity: frames * capacity)
        storage.initialize(repeating: 0, count: frames * capacity)
    }
    deinit {
        storage.deinitialize(count: frames * capacity)
        storage.deallocate()
    }

    /// `samples` holds exactly one block of `frames`.
    func offer(_ samples: UnsafePointer<Float>, position: Int64, timeNs: Int64, discontinuity: Bool) {
        let number = sequence
        sequence += 1
        available.lock()
        defer { available.unlock() }
        guard !closed else { return }
        if count == capacity { read = 0; count = 0; gap = true }
        let index = (read + count) % capacity
        storage.advanced(by: index * frames).update(from: samples, count: frames)
        positions[index] = position
        times[index] = timeNs
        sequences[index] = number
        gaps[index] = gap || discontinuity
        gap = false
        count += 1
        available.signal()
    }

    func take(generation: Int64, rate: Double, maximum: Int) throws -> [CapturePacket] {
        available.lock()
        defer { available.unlock() }
        let deadline = Date(timeIntervalSinceNow: 0.25)
        while count == 0 && !closed {
            if !available.wait(until: deadline) { break }
        }
        if let error = failure { throw error }
        var result = [CapturePacket]()
        for _ in 0..<min(count, max(1, min(8, maximum))) {
            let index = read
            let data = Data(bytes: storage.advanced(by: index * frames), count: frames * MemoryLayout<Float>.size)
            result.append(CapturePacket(generation: generation, sequence: sequences[index],
                firstFrame: positions[index], captureTimeNs: times[index],
                discontinuity: gaps[index], sampleRate: rate, frameCount: frames, audioData: data))
            read = (read + 1) % capacity
            count -= 1
        }
        return result
    }

    func close(_ error: Error? = nil) {
        available.lock()
        closed = true
        failure = error
        count = 0
        available.broadcast()
        available.unlock()
    }
}
