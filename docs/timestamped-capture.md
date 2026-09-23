# Timestamped capture contract

Android and iOS expose request/response capture through `CaptureSession`. Matching can open and pump the session from a registered Flutter background isolate. The native method handler uses a background task queue; there is no unsolicited background-isolate event channel.

Each block owns its Float32 samples and carries native generation, sequence, first frame, frame count, actual delivery sample rate, first-sample monotonic timestamp and discontinuity. `CaptureSession` maps the native clock into `Timeline.now` using the lowest-round-trip clock exchange. Neither platform reports a timing error bound, so blocks carry none; physical alignment comes only from loopback measurement.

The converted queue holds about two seconds of complete blocks (at least 32); the iOS hardware ring holds 32 packets. iOS uses a separate preallocated SPSC input ring: its audio callback only copies PCM and publishes lock-free atomic counters. Conversion and channel delivery run on a dedicated worker, which may wait for a consumer without blocking audio I/O. A full hardware ring drops incoming audio without overwriting unread slots, then marks the next accepted block discontinuous. A full converted queue discards its pending history and marks the replacement block discontinuous. Analysis must reset its windows in either case. The compatibility `FlutterAudioCapture` facade, the production path while matching runs flag-off, keeps delivering after a gap and reports it through the optional `onDiscontinuity` callback first.

Android requires API 24. `CaptureSession.open()` defaults to `UNPROCESSED` when `PROPERTY_SUPPORT_AUDIO_SOURCE_UNPROCESSED` is true, otherwise `VOICE_RECOGNITION`; an explicit source is preserved. The compatibility facade keeps Android's `DEFAULT` source. `CaptureSession.androidAudioSource` reports the selected source (null outside Android). This follows [Android's recording guidance](https://developer.android.com/media/platform/mediarecorder), without enabling speech AGC/noise suppression. Android checks short/error reads, retains blocks during bounded queue-read contention, prefers the built-in microphone (best effort; `inputId` is the routed input, else the preferred one, else -1), keeps recording through an input route change but marks the next block discontinuous (checked only after AudioRecord's routing listener fires), and calls `AudioRecord.stop()` before joining its capture thread. iOS receives input with AVAudioSinkNode, preserves its converter between blocks, uses preallocated sample/conversion storage, follows each hardware timestamp without discarding converter phase, records whichever input is routed (the host app prefers the built-in mic), and invalidates capture when the routed input changes or the capture engine is reconfigured; output-only route changes keep capture running. Sample-position gaps or host-clock jumps reset conversion and mark the next block discontinuous. The host app still owns AVAudioSession configuration.

The app listener and compatibility facade report readiness only after actual PCM arrives; `CaptureSession.open()` itself returns the native session before its first read. Close uses the native generation. A caller may additionally assign a unique `clientId` and call `CaptureSession.closeClient(id)` after worker death; that cannot close a newer client's capture. Stop waits for capture shutdown. Legacy error callbacks with one or two arguments are supported.

`CaptureSession.pump` is the only reader. It hands each batch over as soon as native holds one (an idle native read returns empty after at most 250 ms), closes the session when it ends, and fails for lack of samples only after a caller-supplied `stall`. The pitch worker and loopback probe pass 2 s; the facade passes none, so after its first-data timeout it waits through silence. A stall never delays delivery: it is checked only after an empty read.

## Verification

Run `flutter pub get` and `flutter test` for the Dart protocol tests.

Pure native checks (temporary output; no phone required):

```sh
kotlinc -classpath "$ANDROID_SDK_ROOT/platforms/android-36/android.jar" android/src/main/kotlin/com/ymd/flutter_audio_capture/AudioCaptureSource.kt android/src/main/kotlin/com/ymd/flutter_audio_capture/CaptureQueue.kt android/src/main/kotlin/com/ymd/flutter_audio_capture/CaptureBlockReader.kt test/native/CaptureTest.kt -include-runtime -d /tmp/capture-tests.jar
java -jar /tmp/capture-tests.jar
clang -std=c11 -Wall -Wextra -Werror -Iios/Classes -fsanitize=address,undefined ios/Classes/CaptureInputRing.c test/native/capture_input_ring_test.c -o /tmp/capture-ring-tests
/tmp/capture-ring-tests
clang -std=c11 -c ios/Classes/CaptureInputRing.c -o /tmp/capture-input-ring.o
swiftc -import-objc-header ios/Classes/CaptureInputRing.h ios/Classes/CaptureQueue.swift ios/Classes/AudioCapture.swift test/native/main.swift /tmp/capture-input-ring.o -o /tmp/capture-tests
/tmp/capture-tests
```

These cover source selection, queue capacity, copied buffer ownership, route-change gap marking, pipeline positions and gap flags across sample and host-clock gaps, lossless concurrent read/offer without overflow, overflow, partial/error reads, waiting-reader wakeup, shutdown, and simulated 30-minute capture clock drift. They do not validate AudioRecord/AVAudioEngine behavior on a physical device, converter delay, hardware timestamp accuracy, interruptions or battery/CPU cost. The previous iOS tap measured 155 ms p95 capture age on an iPhone13,2 before detector work. The sink path measured 14.819 ms p95 and 15.494 ms p99 capture age in an eight-chirp repeat with 100/250/500 ms UI stalls and zero underruns. This does not prove end-to-end matching latency. See Apple's [AVAudioSinkNode real-time guidance](https://developer.apple.com/videos/play/wwdc2019/510/).
