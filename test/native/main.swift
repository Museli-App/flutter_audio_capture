import AVFoundation

precondition(CaptureQueue.capacity(sampleRate: 44100, frames: 512) == 173)
precondition(CaptureQueue.capacity(sampleRate: 8000, frames: 8192) == 32)
let queue = CaptureQueue(frames: 4, capacity: 32)
let source = UnsafeMutablePointer<Float>.allocate(capacity: 4)
source.initialize(repeating: 1, count: 4)
defer { source.deinitialize(count: 4); source.deallocate() }
func offer(_ q: CaptureQueue, _ position: Int64) {
    q.offer(UnsafePointer(source), position: position, timeNs: position * 1000, discontinuity: false)
}
offer(queue, 0)
source.update(repeating: 99, count: 4)
let first = try queue.take(generation: 7, rate: 44100, maximum: 8).first!
precondition(first.audioData.withUnsafeBytes { $0.load(as: Float.self) } == 1)
for i in 1...33 { offer(queue, Int64(i * 4)) }
let overflow = try queue.take(generation: 7, rate: 44100, maximum: 8)
precondition(overflow.count == 1)
precondition(overflow[0].discontinuity && overflow[0].firstFrame == 132)
precondition(first.audioData.withUnsafeBytes { $0.load(as: Float.self) } == 1)
let closed = CaptureQueue(frames: 4, capacity: 32)
let finished = DispatchSemaphore(value: 0)
Thread.detachNewThread {
    let result = try! closed.take(generation: 8, rate: 44100, maximum: 8)
    precondition(result.isEmpty)
    finished.signal()
}
closed.close()
precondition(finished.wait(timeout: .now() + 1) == .success)
let failed = CaptureQueue(frames: 4, capacity: 32)
failed.close(NSError(domain: "test", code: 42))
do { _ = try failed.take(generation: 9, rate: 44100, maximum: 8); fatalError("Expected failure") }
catch { precondition((error as NSError).code == 42) }
print("Swift capture ownership, overflow, failure and shutdown checks passed")

// The open that claimed last wins: only the newest claim's start is admitted.
var claims = CaptureClaims()
let older = claims.claim()
let newer = claims.claim()
func refused(_ owner: Int64) -> Bool {
    do { try claims.admit(owner); return false } catch { precondition(error is CaptureSuperseded); return true }
}
precondition(refused(older) && !refused(newer) && !refused(newer))
precondition(!refused(claims.claim()) && refused(newer))
print("Swift capture claim checks passed")

var clock = CaptureSampleClock(inputRate: 48000, outputRate: 44100)
precondition(!clock.observe(inputFrame: 4800, hostNs: 1_000_000_000, outputFrame: 0))
precondition(clock.time(outputFrame: 441) == 1_010_000_000)
precondition(!clock.observe(inputFrame: 5280, hostNs: 1_010_003_000, outputFrame: 441))
precondition(clock.time(outputFrame: 441) == 1_010_003_000)
// Thirty minutes at 50 ppm drift; no converter reset or stale initial anchor.
for tap in 1...18000 {
    let hardwareNs = 1_000_000_000 + Int64(tap) * 100_005_000
    precondition(!clock.observe(inputFrame: 4800 + Int64(tap) * 4800,
        hostNs: hardwareNs, outputFrame: Int64(tap) * 4410))
    precondition(clock.time(outputFrame: Int64(tap) * 4410) == hardwareNs)
}
precondition(clock.observe(inputFrame: 91_000_000, hostNs: 2_000_000_000_000,
    outputFrame: 80_000_000, discontinuity: true))
precondition(clock.time(outputFrame: 80_000_000) == 2_000_000_000_000)
precondition(clock.observe(inputFrame: 91_004_800, hostNs: 2_000_110_000_000,
    outputFrame: 80_004_410))
precondition(clock.time(outputFrame: 80_004_410) == 2_000_110_000_000)
print("Swift capture timestamp drift, discontinuity and clock-jump checks passed")

// Pipeline glue drained synchronously: 48 kHz hardware packets into 44.1 kHz blocks.
let hardware = AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: 48000, channels: 1, interleaved: false)!
let converted = CaptureQueue(frames: 441, capacity: 64)
let pipeline = try CapturePipeline(format: hardware, frames: 441, rate: 44100, queue: converted)
let tap = UnsafeMutablePointer<Float>.allocate(capacity: 480)
tap.initialize(repeating: 0.1, count: 480)
defer { tap.deinitialize(count: 480); tap.deallocate() }
var tapList = AudioBufferList(mNumberBuffers: 1,
    mBuffers: AudioBuffer(mNumberChannels: 1, mDataByteSize: 480 * 4, mData: tap))
var blocks = [CapturePacket]()
func feed(_ inputFrame: Int64, _ hostNs: Int64) throws {
    CaptureInputRingOffer(pipeline.ring, &tapList, 480, inputFrame,
        AVAudioTime.hostTime(forSeconds: Double(hostNs) / 1e9), true)
    let drained = try pipeline.drainOnce()
    precondition(drained)
    while blocks.count < Int(pipeline.emitted / 441) {
        blocks += try converted.take(generation: 1, rate: 44100, maximum: Int(pipeline.emitted / 441) - blocks.count)
    }
}
func near(_ a: Int64, _ b: Int64) -> Bool { abs(a - b) < 100_000 }
let drainedEmpty = try pipeline.drainOnce()
precondition(!drainedEmpty)
for i in 0..<20 { try feed(Int64(i) * 480, 1_000_000_000 + Int64(i) * 10_000_000) }
precondition(blocks.count >= 15 && blocks.allSatisfy { !$0.discontinuity })
for (k, block) in blocks.enumerated() {
    precondition(block.firstFrame == Int64(k) * 441)
    precondition(near(block.captureTimeNs, 1_000_000_000 + Int64(k) * 10_000_000))
}
// A sample-position gap on a consistent host clock, then a host-clock jump on contiguous samples.
for (inputStart, hostStart) in [(Int64(14_400), Int64(1_300_000_000)), (Int64(19_200), Int64(1_450_000_000))] {
    let before = blocks.count
    let emittedBefore = pipeline.emitted
    for i in 0..<10 { try feed(inputStart + Int64(i) * 480, hostStart + Int64(i) * 10_000_000) }
    precondition(blocks.count > before + 5)
    precondition(blocks[before].discontinuity && blocks[before].firstFrame == emittedBefore)
    precondition(near(blocks[before].captureTimeNs, hostStart))
    precondition(blocks[(before + 1)...].allSatisfy { !$0.discontinuity })
}
precondition(blocks.enumerated().allSatisfy { $0.element.firstFrame == Int64($0.offset) * 441 })
print("Swift capture pipeline positions, gap flags and clock continuity checks passed")
