package com.ymd.flutter_audio_capture

import java.util.concurrent.CountDownLatch
import java.util.concurrent.TimeUnit
import java.util.concurrent.atomic.AtomicBoolean

fun main() {
    check(selectCaptureSource(null, true) == 9)
    check(selectCaptureSource(null, false) == 6)
    check(CaptureQueue.capacity(44100, 512) == 173)
    check(CaptureQueue.capacity(8000, 8192) == 32)
    for (supported in listOf(true, false)) {
        for (explicit in listOf(0, 1, 5, 6, 7, 9)) {
            check(selectCaptureSource(explicit, supported) == explicit)
        }
    }
    // The open that claimed last wins; an unowned start claims afresh, so it fences the owner before it.
    val claims = CaptureClaims()
    val older = claims.claim()
    val newer = claims.claim()
    fun refused(owner: Long?) = try { claims.admit(owner); false } catch (_: CaptureSupersededException) { true }
    check(refused(older) && !refused(newer) && !refused(newer))
    check(!refused(null) && refused(newer))
    check(!refused(claims.claim()))
    val queue = CaptureQueue(4, 2)
    val source = floatArrayOf(1f, 2f, 3f, 4f)
    queue.offer(source, 0, 10)
    source.fill(99f)
    val first = queue.take(1, 44100, 8).single()
    check((first["audioData"] as FloatArray).contentEquals(floatArrayOf(1f, 2f, 3f, 4f)))
    queue.offer(source, 4, 20)
    queue.offer(source, 8, 30)
    queue.offer(source, 12, 40)
    val overflow = queue.take(1, 44100, 8).single()
    check(overflow["discontinuity"] == true && overflow["firstFrame"] == 12L)
    check((first["audioData"] as FloatArray)[0] == 1f)
    // A marked gap (input route change) reaches exactly the next offered block.
    val routed = CaptureQueue(4, 8)
    routed.offer(source, 0, 10)
    routed.markGap()
    check(routed.take(1, 44100, 8).single()["discontinuity"] == false)
    routed.offer(source, 4, 20)
    routed.offer(source, 8, 30)
    check(routed.take(1, 44100, 8).map { it["discontinuity"] } == listOf(true, false))

    val outputs = mutableListOf<FloatArray>()
    var next = 0
    var active = true
    CaptureBlockReader(4).run(
        read = { target, offset, count ->
            val read = minOf(count, 2)
            repeat(read) { target[offset + it] = (next++).toFloat() }
            read
        }, running = { active }
    ) { buffer, position ->
        check(position == outputs.size * 4L)
        outputs.add(buffer.copyOf())
        if (outputs.size == 2) active = false
    }
    check(outputs[0].contentEquals(floatArrayOf(0f, 1f, 2f, 3f)))
    check(outputs[1].contentEquals(floatArrayOf(4f, 5f, 6f, 7f)))
    for (error in listOf(0, -1, -2, -3, -6, 5)) {
        var emitted = false
        try {
            CaptureBlockReader(4).run({ _, _, _ -> error }, { true }) { _, _ -> emitted = true }
            error("Expected read failure")
        } catch (_: IllegalStateException) { check(!emitted) }
    }
    val running = AtomicBoolean(true)
    val entered = CountDownLatch(1)
    val unblock = CountDownLatch(1)
    val worker = Thread {
        CaptureBlockReader(4).run({ _, _, _ -> entered.countDown(); unblock.await(); -3 }, running::get) { _, _ -> error("Stopped block escaped") }
    }
    worker.start()
    check(entered.await(1, TimeUnit.SECONDS))
    running.set(false)
    unblock.countDown()
    worker.join(1000)
    check(!worker.isAlive)
    val waitingQueue = CaptureQueue(4, 32)
    val stopped = CountDownLatch(1)
    val consumer = Thread { check(waitingQueue.take(1, 44100, 8).isEmpty()); stopped.countDown() }
    consumer.start()
    waitingQueue.close()
    check(stopped.await(1, TimeUnit.SECONDS))
    val failureQueue = CaptureQueue(4, 32)
    failureQueue.close(IllegalStateException("native failure"))
    try { failureQueue.take(1, 44100, 8); error("Expected queue failure") }
    catch (failure: IllegalStateException) { check(failure.message == "native failure") }
    // Capacity exceeds the entire run, so lock contention must never drop PCM.
    val totalBlocks = 10000
    val concurrent = CaptureQueue(4, totalBlocks)
    val start = CountDownLatch(1)
    val producer = Thread {
        val buffer = FloatArray(4)
        start.await()
        repeat(totalBlocks) { index ->
            buffer.fill(index.toFloat())
            concurrent.offer(buffer, index * 4L, index.toLong())
            Thread.yield()
        }
    }
    producer.start()
    start.countDown()
    var received = 0
    val deadline = System.nanoTime() + TimeUnit.SECONDS.toNanos(5)
    while (received < totalBlocks && System.nanoTime() < deadline) {
        for (packet in concurrent.take(1, 44100, 8)) {
            check(packet["sequence"] == received.toLong()) { "Capture dropped a block during read contention" }
            check(packet["firstFrame"] == received * 4L)
            check(packet["discontinuity"] == false)
            check((packet["audioData"] as FloatArray).all { it == received.toFloat() })
            received++
        }
    }
    producer.join(1000)
    check(!producer.isAlive && received == totalBlocks)
    concurrent.close()
    println("Capture source selection, claims, ownership, overflow, short/error reads and shutdown checks passed")
}
