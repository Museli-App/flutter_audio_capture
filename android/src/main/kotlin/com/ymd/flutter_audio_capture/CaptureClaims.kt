package com.ymd.flutter_audio_capture

import java.util.concurrent.atomic.AtomicLong

/** A later claim replaced this start's; nothing current was touched. */
internal class CaptureSupersededException : Exception("Superseded by a newer capture claim")

/** One counter, which is the newest claim; calls arrive on one serial queue, so claims keep the order opens began. */
internal class CaptureClaims {
    private val latest = AtomicLong()

    fun claim(): Long = latest.incrementAndGet()

    /** Refuses a stale owner; an unowned (legacy) start claims afresh, so it still fences older owned starts. */
    fun admit(owner: Long?) {
        if (owner == null) latest.incrementAndGet() else if (owner != latest.get()) throw CaptureSupersededException()
    }
}
