import 'dart:async';
import 'dart:developer';
import 'dart:typed_data';

import 'package:flutter/foundation.dart' show visibleForTesting;
import 'package:flutter/services.dart';

const AUDIO_CAPTURE_METHOD_CHANNEL_NAME =
    'ymd.dev/audio_capture_method_channel';
const ANDROID_AUDIOSRC_DEFAULT = 0;
const ANDROID_AUDIOSRC_MIC = 1;
const ANDROID_AUDIOSRC_CAMCORDER = 5;
const ANDROID_AUDIOSRC_VOICERECOGNITION = 6;
const ANDROID_AUDIOSRC_VOICECOMMUNICATION = 7;
const ANDROID_AUDIOSRC_UNPROCESSED = 9;

/// Native clock ns onto Timeline.now µs: the midpoint of the shortest of
/// [samples] round trips. flutter_pcm_sound keeps the same estimator.
@visibleForTesting
Future<int> timelineOffsetUs(Future<int?> Function() nativeClockNs,
    {int samples = 5}) async {
  int? offsetNs;
  var bestRoundTripUs = 0;
  for (var sample = 0; sample < samples; sample++) {
    final beforeUs = Timeline.now;
    final nativeNs = await nativeClockNs();
    final afterUs = Timeline.now;
    if (nativeNs == null) throw StateError('Native clock unavailable');
    if (offsetNs == null || afterUs - beforeUs < bestRoundTripUs) {
      bestRoundTripUs = afterUs - beforeUs;
      offsetNs = (beforeUs + afterUs) * 500 - nativeNs;
    }
  }
  return offsetNs! ~/ 1000;
}

/// The timestamp names the first sample, in Dart's Timeline.now timebase.
class CaptureBlock {
  const CaptureBlock(
      {required this.samples,
      required this.sequence,
      required this.firstFrame,
      required this.sampleRate,
      required this.captureTimeUs,
      required this.discontinuity});
  final Float32List samples;
  final int sequence, firstFrame, sampleRate;
  final int captureTimeUs;
  final bool discontinuity;
  int get endTimeUs => captureTimeUs + samples.length * 1000000 ~/ sampleRate;
}

/// A single native generation, read only through [pump]. Safe to use from a
/// registered background isolate.
class CaptureSession {
  CaptureSession._(this._generation, this.sampleRate, this._offsetUs);
  static const _channel = MethodChannel(AUDIO_CAPTURE_METHOD_CHANNEL_NAME);
  final int _generation;

  /// The delivery rate, fixed for the session.
  final int sampleRate;
  final int _offsetUs;
  var _closed = false;
  var _pumping = false;
  Future<void>? _closing;

  /// Defaults to supported raw input on Android, or voice recognition.
  /// An explicit source bypasses automatic selection.
  static Future<CaptureSession> open(
      {int sampleRate = 44100,
      int bufferSize = 512,
      int? androidAudioSource,
      String? clientId}) async {
    if (sampleRate < 8000 ||
        sampleRate > 192000 ||
        bufferSize < 64 ||
        bufferSize > 8192) {
      throw ArgumentError('Unsupported capture format');
    }
    // Claim before the clock sync: native refuses this start, with no side
    // effects, once a later open has claimed.
    final owner = await _channel.invokeMethod<int>('claim');
    if (owner == null) throw StateError('Native capture claim unavailable');
    final offsetUs =
        await timelineOffsetUs(() => _channel.invokeMethod<int>('clock'));
    final config =
        await _channel.invokeMapMethod<String, dynamic>('startCapture', {
      'sampleRate': sampleRate,
      'bufferSize': bufferSize,
      'audioSource': androidAudioSource,
      'clientId': clientId,
      'owner': owner,
    });
    if (config == null) throw StateError('Capture did not start');
    return CaptureSession._((config['generation'] as num).toInt(),
        (config['sampleRate'] as num).round(), offsetUs);
  }

  /// Delivers each non-empty read until closed, then closes; the first error
  /// ends it. [stall] fails it after that long without samples; null never does.
  Future<void> pump(void Function(List<CaptureBlock> blocks) onBatch,
      {Duration? stall}) async {
    if (_pumping) throw StateError('Only one capture pump may run');
    _pumping = true;
    var lastDataUs = Timeline.now;
    try {
      while (!_closed) {
        final blocks = await _read();
        if (blocks.isNotEmpty) {
          lastDataUs = Timeline.now;
          onBatch(blocks);
        } else if (stall != null &&
            Timeline.now - lastDataUs > stall.inMicroseconds) {
          throw TimeoutException('No capture samples', stall);
        }
      }
    } finally {
      _pumping = false;
      // The closer, or the error that ended the pump, reports failures.
      await close().catchError((Object _) {});
    }
  }

  // An idle native read returns empty after at most 250 ms. Native refuses a
  // stale generation, so rows carry none.
  Future<List<CaptureBlock>> _read() async {
    if (_closed) return const [];
    final rows = await _channel
        .invokeListMethod<dynamic>('readCapture', {'generation': _generation});
    if (_closed) return const [];
    return [for (final row in rows ?? const <dynamic>[]) _block(row as Map)];
  }

  CaptureBlock _block(Map row) {
    final samples = row['audioData'] as Float32List;
    if (samples.isEmpty) throw StateError('Invalid capture block');
    return CaptureBlock(
        samples: samples,
        sequence: (row['sequence'] as num).toInt(),
        firstFrame: (row['firstFrame'] as num).toInt(),
        sampleRate: sampleRate,
        captureTimeUs:
            (row['captureTimeNs'] as num).toInt() ~/ 1000 + _offsetUs,
        discontinuity: row['discontinuity'] as bool);
  }

  /// Stops only the caller's session, including after its isolate has died.
  static Future<void> closeClient(String clientId) =>
      _channel.invokeMethod<void>('stopCapture', {'clientId': clientId});

  Future<void> close() {
    _closed = true;
    return _closing ??=
        _channel.invokeMethod<void>('stopCapture', {'generation': _generation});
  }
}
