package com.ymd.flutter_audio_capture

import java.util.concurrent.locks.ReentrantLock
import kotlin.concurrent.withLock
import kotlin.math.ceil

/** Fixed storage shared by the AudioRecord worker and bounded channel reads. */
internal class CaptureQueue(private val framesPerBlock: Int, capacity: Int) {
    companion object {
        /** About two seconds of blocks, so a UI-isolate stall does not overflow. */
        fun capacity(sampleRate: Int, framesPerBlock: Int) =
            maxOf(32, ceil(2.0 * sampleRate / framesPerBlock).toInt())
    }

    private val lock = ReentrantLock()
    private val available = lock.newCondition()
    private val samples = Array(capacity) { FloatArray(framesPerBlock) }
    private val positions = LongArray(capacity)
    private val times = LongArray(capacity)
    private val sequences = LongArray(capacity)
    private val gaps = BooleanArray(capacity)
    private var read = 0
    private var size = 0
    private var nextSequence = 0L
    private var gap = false
    private var closed = false
    private var failure: Throwable? = null

    fun offer(source: FloatArray, position: Long, timeNs: Long) {
        val sequence = nextSequence++
        // This is a blocking-read worker, not a real-time audio callback.
        // Contention with a bounded read must not discard valid PCM.
        lock.lock()
        try {
            if (closed) return
            if (size == samples.size) {
                read = 0
                size = 0
                gap = true
            }
            val index = (read + size) % samples.size
            source.copyInto(samples[index], endIndex = framesPerBlock)
            positions[index] = position
            times[index] = timeNs
            sequences[index] = sequence
            gaps[index] = gap
            gap = false
            size++
            available.signal()
        } finally { lock.unlock() }
    }

    fun take(generation: Long, rate: Int, maxBlocks: Int): List<Map<String, Any>> = lock.withLock {
        var remaining = 250_000_000L
        while (size == 0 && !closed && remaining > 0) remaining = available.awaitNanos(remaining)
        failure?.let { throw it }
        val result = ArrayList<Map<String, Any>>()
        repeat(minOf(size, maxBlocks)) {
            val index = read
            result.add(mapOf(
                "generation" to generation, "sequence" to sequences[index],
                "firstFrame" to positions[index], "captureTimeNs" to times[index],
                "discontinuity" to gaps[index],
                "sampleRate" to rate, "frameCount" to framesPerBlock, "audioData" to samples[index].copyOf()
            ))
            read = (read + 1) % samples.size
            size--
        }
        result
    }

    /** Marks the next offered block discontinuous, e.g. after an input route change. */
    fun markGap() = lock.withLock { gap = true }

    fun close(error: Throwable? = null) = lock.withLock {
        closed = true
        failure = error
        size = 0
        available.signalAll()
    }
}
