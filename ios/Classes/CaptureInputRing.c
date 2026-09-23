#include "CaptureInputRing.h"
#include <stdatomic.h>
#include <stdlib.h>
#include <string.h>

struct CaptureInputRing {
    uint32_t capacity, maximumFrames, planes, bytesPerFrame;
    size_t planeBytes, slotBytes;
    unsigned char *samples;
    CaptureInputPacket *packets;
    _Atomic(uint64_t) written, read;
    _Atomic(int) error;
    _Atomic(bool) closed;
    bool gap; // Producer only.
};

CaptureInputRing *CaptureInputRingCreate(uint32_t capacity, uint32_t maximumFrames,
    uint32_t planes, uint32_t bytesPerFrame) {
    if (capacity < 2 || capacity > 64 || maximumFrames == 0 || maximumFrames > 16384 ||
        planes == 0 || planes > 8 || bytesPerFrame == 0 || bytesPerFrame > 32 ||
        bytesPerFrame % sizeof(float) != 0) return NULL;
    CaptureInputRing *ring = calloc(1, sizeof(*ring));
    if (!ring) return NULL;
    ring->capacity = capacity;
    ring->maximumFrames = maximumFrames;
    ring->planes = planes;
    ring->bytesPerFrame = bytesPerFrame;
    ring->planeBytes = (size_t)maximumFrames * bytesPerFrame;
    ring->slotBytes = ring->planeBytes * planes;
    ring->samples = calloc(capacity, ring->slotBytes);
    ring->packets = calloc(capacity, sizeof(*ring->packets));
    if (!ring->samples || !ring->packets) { CaptureInputRingDestroy(ring); return NULL; }
    atomic_init(&ring->written, 0);
    atomic_init(&ring->read, 0);
    atomic_init(&ring->error, CaptureInputErrorNone);
    atomic_init(&ring->closed, false);
    if (!atomic_is_lock_free(&ring->written) || !atomic_is_lock_free(&ring->read) ||
        !atomic_is_lock_free(&ring->closed) || !atomic_is_lock_free(&ring->error)) {
        CaptureInputRingDestroy(ring);
        return NULL;
    }
    return ring;
}

void CaptureInputRingDestroy(CaptureInputRing *ring) {
    if (!ring) return;
    free(ring->samples);
    free(ring->packets);
    free(ring);
}

void CaptureInputRingOffer(CaptureInputRing *ring, const AudioBufferList *input,
    uint32_t frames, int64_t inputFrame, uint64_t hostTicks, bool timestampValid) {
    if (atomic_load_explicit(&ring->closed, memory_order_relaxed) ||
        atomic_load_explicit(&ring->error, memory_order_relaxed) != CaptureInputErrorNone) return;
    if (!timestampValid) {
        atomic_store_explicit(&ring->error, CaptureInputErrorTimestamp, memory_order_release);
        return;
    }
    if (!input || frames == 0 || frames > ring->maximumFrames || input->mNumberBuffers != ring->planes) {
        atomic_store_explicit(&ring->error, CaptureInputErrorFormat, memory_order_release);
        return;
    }
    size_t bytes = (size_t)frames * ring->bytesPerFrame;
    for (uint32_t plane = 0; plane < ring->planes; plane++) {
        if (!input->mBuffers[plane].mData || input->mBuffers[plane].mDataByteSize < bytes ||
            input->mBuffers[plane].mNumberChannels != ring->bytesPerFrame / sizeof(float)) {
            atomic_store_explicit(&ring->error, CaptureInputErrorFormat, memory_order_release);
            return;
        }
    }
    uint64_t written = atomic_load_explicit(&ring->written, memory_order_relaxed);
    uint64_t read = atomic_load_explicit(&ring->read, memory_order_acquire);
    if (written - read == ring->capacity) {
        ring->gap = true;
        return;
    }
    size_t slot = written % ring->capacity;
    for (uint32_t plane = 0; plane < ring->planes; plane++) {
        memcpy(ring->samples + slot * ring->slotBytes + plane * ring->planeBytes,
            input->mBuffers[plane].mData, bytes);
    }
    ring->packets[slot] = (CaptureInputPacket){inputFrame, hostTicks, frames, ring->gap};
    ring->gap = false;
    atomic_store_explicit(&ring->written, written + 1, memory_order_release);
}

bool CaptureInputRingRead(CaptureInputRing *ring, AudioBufferList *output,
    CaptureInputPacket *packet) {
    if (atomic_load_explicit(&ring->closed, memory_order_acquire) ||
        atomic_load_explicit(&ring->error, memory_order_acquire) != CaptureInputErrorNone) return false;
    uint64_t read = atomic_load_explicit(&ring->read, memory_order_relaxed);
    if (read == atomic_load_explicit(&ring->written, memory_order_acquire)) return false;
    size_t slot = read % ring->capacity;
    CaptureInputPacket value = ring->packets[slot];
    size_t bytes = (size_t)value.frameCount * ring->bytesPerFrame;
    if (!output || !packet || output->mNumberBuffers != ring->planes) {
        atomic_store_explicit(&ring->error, CaptureInputErrorFormat, memory_order_release);
        return false;
    }
    for (uint32_t plane = 0; plane < ring->planes; plane++) {
        if (!output->mBuffers[plane].mData || output->mBuffers[plane].mDataByteSize < bytes ||
            output->mBuffers[plane].mNumberChannels != ring->bytesPerFrame / sizeof(float)) {
            atomic_store_explicit(&ring->error, CaptureInputErrorFormat, memory_order_release);
            return false;
        }
    }
    for (uint32_t plane = 0; plane < ring->planes; plane++) {
        memcpy(output->mBuffers[plane].mData,
            ring->samples + slot * ring->slotBytes + plane * ring->planeBytes, bytes);
        output->mBuffers[plane].mDataByteSize = (UInt32)bytes;
    }
    *packet = value;
    atomic_store_explicit(&ring->read, read + 1, memory_order_release);
    return true;
}

void CaptureInputRingClose(CaptureInputRing *ring) {
    atomic_store_explicit(&ring->closed, true, memory_order_release);
}
bool CaptureInputRingIsClosed(const CaptureInputRing *ring) {
    return atomic_load_explicit(&ring->closed, memory_order_acquire);
}
int CaptureInputRingError(const CaptureInputRing *ring) {
    return atomic_load_explicit(&ring->error, memory_order_acquire);
}
