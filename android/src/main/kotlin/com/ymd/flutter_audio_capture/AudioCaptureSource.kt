package com.ymd.flutter_audio_capture

import android.media.MediaRecorder

internal fun selectCaptureSource(requested: Int?, supportsUnprocessed: Boolean): Int =
    requested ?: if (supportsUnprocessed) MediaRecorder.AudioSource.UNPROCESSED
        else MediaRecorder.AudioSource.VOICE_RECOGNITION
