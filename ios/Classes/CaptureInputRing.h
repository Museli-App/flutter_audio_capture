#ifndef MUSELI_CAPTURE_INPUT_RING_H
#define MUSELI_CAPTURE_INPUT_RING_H

#include <AudioToolbox/AudioToolbox.h>
#include <stdbool.h>
#include <stdint.h>

typedef struct CaptureInputRing CaptureInputRing;

typedef struct {
    int64_t inputFrame;
    uint64_t hostTicks;
    uint32_t frameCount;
    bool discontinuity;
} CaptureInputPacket;

enum {
    CaptureInputErrorNone = 0,
    CaptureInputErrorFormat = 1,
    CaptureInputErrorTimestamp = 2
};

CaptureInputRing *CaptureInputRingCreate(uint32_t capacity, uint32_t maximumFrames,
    uint32_t planes, uint32_t bytesPerFrame);
void CaptureInputRingDestroy(CaptureInputRing *ring);
// Single audio-thread producer: no allocation, locks or waiting.
void CaptureInputRingOffer(CaptureInputRing *ring, const AudioBufferList *input,
    uint32_t frames, int64_t inputFrame, uint64_t hostTicks, bool timestampValid);
// Single conversion-thread consumer. Destination storage is owned by the caller.
bool CaptureInputRingRead(CaptureInputRing *ring, AudioBufferList *output,
    CaptureInputPacket *packet);
void CaptureInputRingClose(CaptureInputRing *ring);
bool CaptureInputRingIsClosed(const CaptureInputRing *ring);
int CaptureInputRingError(const CaptureInputRing *ring);

#endif
