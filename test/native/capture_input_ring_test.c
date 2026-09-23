#include "CaptureInputRing.h"
#include <assert.h>
#include <pthread.h>
#include <sched.h>
#include <stdatomic.h>
#include <stdio.h>
#include <stdlib.h>

static AudioBufferList buffer(float *samples, uint32_t frames) {
    return (AudioBufferList){1, {{1, frames * sizeof(float), samples}}};
}

static void boundaries(void) {
    CaptureInputRing *ring = CaptureInputRingCreate(2, 4, 1, sizeof(float));
    assert(ring);
    float input[] = {1, 2, 3, 4}, output[4];
    AudioBufferList source = buffer(input, 4), destination = buffer(output, 4);
    CaptureInputPacket packet;
    CaptureInputRingOffer(ring, &source, 4, 0, 100, true);
    input[0] = 9;
    assert(CaptureInputRingRead(ring, &destination, &packet));
    assert(output[0] == 1 && packet.inputFrame == 0 && packet.hostTicks == 100);
    CaptureInputRingOffer(ring, &source, 4, 4, 200, true);
    CaptureInputRingOffer(ring, &source, 4, 8, 300, true);
    CaptureInputRingOffer(ring, &source, 4, 12, 400, true);
    assert(CaptureInputRingRead(ring, &destination, &packet));
    assert(CaptureInputRingRead(ring, &destination, &packet));
    CaptureInputRingOffer(ring, &source, 4, 16, 500, true);
    assert(CaptureInputRingRead(ring, &destination, &packet));
    assert(packet.discontinuity && packet.inputFrame == 16);
    CaptureInputRingClose(ring);
    assert(CaptureInputRingIsClosed(ring));
    CaptureInputRingOffer(ring, &source, 4, 20, 600, true);
    assert(!CaptureInputRingRead(ring, &destination, &packet));
    CaptureInputRingDestroy(ring);

    ring = CaptureInputRingCreate(2, 4, 1, sizeof(float));
    CaptureInputRingOffer(ring, &source, 5, 0, 100, true);
    assert(CaptureInputRingError(ring) == CaptureInputErrorFormat);
    CaptureInputRingDestroy(ring);
    ring = CaptureInputRingCreate(2, 4, 1, sizeof(float));
    CaptureInputRingOffer(ring, &source, 4, 0, 100, false);
    assert(CaptureInputRingError(ring) == CaptureInputErrorTimestamp);
    CaptureInputRingDestroy(ring);
}

static void planar_and_short_buffers(void) {
    CaptureInputRing *ring = CaptureInputRingCreate(2, 4, 2, sizeof(float));
    AudioBufferList *source = calloc(1, sizeof(AudioBufferList) + sizeof(AudioBuffer));
    AudioBufferList *destination = calloc(1, sizeof(AudioBufferList) + sizeof(AudioBuffer));
    float left[] = {1, 2, 3, 4}, right[] = {5, 6, 7, 8}, outLeft[4], outRight[4];
    source->mNumberBuffers = destination->mNumberBuffers = 2;
    source->mBuffers[0] = (AudioBuffer){1, sizeof(left), left};
    source->mBuffers[1] = (AudioBuffer){1, sizeof(right), right};
    destination->mBuffers[0] = (AudioBuffer){1, sizeof(outLeft), outLeft};
    destination->mBuffers[1] = (AudioBuffer){1, sizeof(outRight), outRight};
    CaptureInputPacket packet;
    CaptureInputRingOffer(ring, source, 2, 42, 101, true);
    left[0] = right[0] = 99;
    assert(CaptureInputRingRead(ring, destination, &packet));
    assert(packet.frameCount == 2 && packet.inputFrame == 42);
    assert(outLeft[0] == 1 && outLeft[1] == 2 && outRight[0] == 5 && outRight[1] == 6);
    assert(destination->mBuffers[0].mDataByteSize == 2 * sizeof(float));
    CaptureInputRingOffer(ring, source, 4, 44, 102, true);
    assert(!CaptureInputRingRead(ring, destination, &packet));
    assert(CaptureInputRingError(ring) == CaptureInputErrorFormat);
    CaptureInputRingDestroy(ring);
    free(source);
    free(destination);
}

static CaptureInputRing *concurrent;
static _Atomic(bool) finished;
static void *produce(void *unused) {
    (void)unused;
    float input[4];
    AudioBufferList source = buffer(input, 4);
    for (int64_t frame = 0; frame < 1000000; frame++) {
        for (int i = 0; i < 4; i++) input[i] = (float)frame;
        CaptureInputRingOffer(concurrent, &source, 4, frame, (uint64_t)frame + 7, true);
        if (frame % 16 == 0) sched_yield();
    }
    atomic_store_explicit(&finished, true, memory_order_release);
    return NULL;
}

int main(void) {
    boundaries();
    planar_and_short_buffers();
    concurrent = CaptureInputRingCreate(32, 4, 1, sizeof(float));
    assert(concurrent);
    pthread_t thread;
    assert(pthread_create(&thread, NULL, produce, NULL) == 0);
    int64_t previous = -1;
    unsigned read = 0;
    float output[4];
    AudioBufferList destination = buffer(output, 4);
    CaptureInputPacket packet;
    for (;;) {
        if (CaptureInputRingRead(concurrent, &destination, &packet)) {
            assert(packet.inputFrame > previous);
            assert(packet.hostTicks == (uint64_t)packet.inputFrame + 7);
            assert(packet.frameCount == 4);
            if (packet.inputFrame != previous + 1) assert(packet.discontinuity);
            for (int i = 0; i < 4; i++) assert(output[i] == (float)packet.inputFrame);
            previous = packet.inputFrame;
            read++;
        } else if (atomic_load_explicit(&finished, memory_order_acquire)) break;
        else sched_yield();
    }
    assert(pthread_join(thread, NULL) == 0);
    assert(read > 0);
    CaptureInputRingDestroy(concurrent);
    puts("Capture input ring: ownership, overflow, failure, close and one-million-frame concurrency passed");
}
