package com.ymd.flutter_audio_capture

import android.content.Context
import android.media.AudioDeviceInfo
import android.media.AudioFormat
import android.media.AudioManager
import android.media.AudioRecord
import android.media.AudioRouting
import android.media.AudioTimestamp
import java.util.concurrent.atomic.AtomicLong

internal class CaptureController(private val context: Context) {
    private val generations = AtomicLong()
    private val claims = CaptureClaims()
    @Volatile private var session: Session? = null

    fun claim(): Long = claims.claim()

    fun start(rate: Int, blockSize: Int, source: Int?, clientId: String?, owner: Long): Map<String, Any> {
        require(rate in 8000..192000 && blockSize in 64..8192)
        // Before any side effect: a superseded start must leave the current session running.
        claims.admit(owner)
        stop(null)
        val minimum = AudioRecord.getMinBufferSize(rate, AudioFormat.CHANNEL_IN_MONO, AudioFormat.ENCODING_PCM_FLOAT)
        check(minimum > 0) { "Unsupported capture format ($minimum)" }
        val manager = context.getSystemService(Context.AUDIO_SERVICE) as AudioManager
        val selectedSource = selectCaptureSource(source,
            manager.getProperty(AudioManager.PROPERTY_SUPPORT_AUDIO_SOURCE_UNPROCESSED) == "true")
        val recorder = AudioRecord.Builder().setAudioSource(selectedSource)
            .setAudioFormat(AudioFormat.Builder().setEncoding(AudioFormat.ENCODING_PCM_FLOAT)
                .setSampleRate(rate).setChannelMask(AudioFormat.CHANNEL_IN_MONO).build())
            .setBufferSizeInBytes(maxOf(minimum, blockSize * 4 * 2)).build()
        try {
            check(recorder.state == AudioRecord.STATE_INITIALIZED) { "AudioRecord initialization failed" }
            val mic = manager.getDevices(AudioManager.GET_DEVICES_INPUTS)
                .firstOrNull { it.type == AudioDeviceInfo.TYPE_BUILTIN_MIC }
            // Best effort, as before timestamped capture: without the built-in mic, record the default route.
            val preferred = if (mic != null && recorder.setPreferredDevice(mic)) mic.id else -1
            recorder.startRecording()
            check(recorder.recordingState == AudioRecord.RECORDSTATE_RECORDING) { "AudioRecord did not start" }
            // A preference is not a route; report the routed input once recording has one.
            val inputId = recorder.routedDevice?.id ?: preferred
            val current = Session(generations.incrementAndGet(), recorder, blockSize, clientId)
            session = current
            current.thread.start()
            return mapOf("generation" to current.generation, "sampleRate" to recorder.sampleRate,
                "inputId" to inputId.toString(), "audioSource" to recorder.audioSource)
        } catch (error: Throwable) {
            recorder.release()
            throw error
        }
    }

    fun read(generation: Long, maxBlocks: Int): List<Map<String, Any>> {
        val current = session ?: error("Capture stopped")
        check(current.generation == generation) { "Stale capture generation" }
        return current.queue.take(generation, current.sampleRate, maxBlocks.coerceIn(1, 8))
    }

    fun stop(generation: Long?, clientId: String? = null) {
        val current = session ?: return
        if (generation != null && generation != current.generation) return
        if (clientId != null && clientId != current.clientId) return
        current.running = false
        current.queue.close()
        // AudioRecord.stop interrupts READ_BLOCKING; joining alone cannot.
        try { current.recorder.stop() } catch (_: IllegalStateException) {}
        current.thread.join(1000)
        check(!current.thread.isAlive) { "Capture worker did not stop" }
        session = null
    }

    private class Session(val generation: Long, val recorder: AudioRecord, val blockSize: Int, val clientId: String?) {
        val sampleRate = recorder.sampleRate
        @Volatile var running = true
        @Volatile private var routeDirty = true // set by the routing listener; the first block seeds the route
        // AudioRouting's type, so registration skips the deprecated AudioRecord overload.
        private val routing = AudioRouting.OnRoutingChangedListener { routeDirty = true }
        val queue = CaptureQueue(blockSize, CaptureQueue.capacity(sampleRate, blockSize))
        val thread = Thread({ record() }, "museli-capture")

        private fun record() {
            val timestamp = AudioTimestamp()
            // Extrapolating the last anchor keeps one timebase when getTimestamp fails mid-stream.
            var anchorFrame = 0L
            var anchorNs = 0L
            var anchored = false
            var routeId: Int? = null
            try {
                android.os.Process.setThreadPriority(android.os.Process.THREAD_PRIORITY_AUDIO)
                recorder.addOnRoutingChangedListener(routing, null) // null: the main looper; this thread has none
                CaptureBlockReader(blockSize).run(
                    read = { buffer, offset, size -> recorder.read(buffer, offset, size, AudioRecord.READ_BLOCKING) },
                    running = { running }
                ) { buffer, position ->
                    // A mic change keeps recording but marks a gap: analysis resets, block timestamps stay fresh.
                    if (routeDirty) {
                        routeDirty = false
                        recorder.routedDevice?.id?.let { id ->
                            if (routeId != null && routeId != id) queue.markGap()
                            routeId = id
                        }
                    }
                    val rate = sampleRate
                    if (recorder.getTimestamp(timestamp, AudioTimestamp.TIMEBASE_MONOTONIC) == AudioRecord.SUCCESS) {
                        anchorFrame = timestamp.framePosition
                        anchorNs = timestamp.nanoTime
                        anchored = true
                    }
                    val timeNs = if (anchored) anchorNs + (position - anchorFrame) * 1_000_000_000L / rate
                        else System.nanoTime() - blockSize * 1_000_000_000L / rate
                    queue.offer(buffer, position, timeNs)
                }
            } catch (error: Throwable) {
                if (running) queue.close(error)
            } finally {
                running = false
                try { recorder.stop() } catch (_: IllegalStateException) {}
                recorder.removeOnRoutingChangedListener(routing)
                recorder.release()
            }
        }
    }
}
