package com.ymd.flutter_audio_capture

/** Only complete blocks cross into the queue; errors never become PCM. */
internal class CaptureBlockReader(private val blockSize: Int) {
    fun run(read: (FloatArray, Int, Int) -> Int, running: () -> Boolean, block: (FloatArray, Long) -> Unit) {
        val buffer = FloatArray(blockSize)
        var filled = 0
        var position = 0L
        while (running()) {
            val requested = blockSize - filled
            val count = read(buffer, filled, requested)
            if (!running()) return
            check(count in 1..requested) { "AudioRecord.read failed ($count of $requested)" }
            filled += count
            if (filled != blockSize) continue
            block(buffer, position)
            position += blockSize
            filled = 0
        }
    }
}
