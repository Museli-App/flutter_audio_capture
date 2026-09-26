import 'dart:async';
import 'dart:developer';
import 'dart:typed_data';

import 'package:flutter/services.dart';

const AUDIO_CAPTURE_METHOD_CHANNEL_NAME =
    'ymd.dev/audio_capture_method_channel';
const ANDROID_AUDIOSRC_DEFAULT = 0;
const ANDROID_AUDIOSRC_MIC = 1;
const ANDROID_AUDIOSRC_CAMCORDER = 5;
const ANDROID_AUDIOSRC_VOICERECOGNITION = 6;
const ANDROID_AUDIOSRC_VOICECOMMUNICATION = 7;
const ANDROID_AUDIOSRC_UNPROCESSED = 9;

/// The timestamp names the first sample, in Dart's Timeline.now timebase.
class CaptureBlock {
  const CaptureBlock(
      {required this.samples,
      required this.generation,
      required this.sequence,
      required this.firstFrame,
      required this.sampleRate,
      required this.captureTimeUs,
      required this.discontinuity});
  final Float32List samples;
  final int generation, sequence, firstFrame, sampleRate;
  final int captureTimeUs;
  final bool discontinuity;
  int get endTimeUs => captureTimeUs + samples.length * 1000000 ~/ sampleRate;
}

/// A single native generation, read only through [pump]. Safe to use from a
/// registered background isolate.
class CaptureSession {
  CaptureSession._(this.generation, this.sampleRate, this.inputId,
      this.androidAudioSource, this._offsetUs);
  static const _channel = MethodChannel(AUDIO_CAPTURE_METHOD_CHANNEL_NAME);
  final int generation, sampleRate;
  final String inputId;

  /// The selected Android source; null on other platforms.
  final int? androidAudioSource;
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
    // The lowest round trip gives the tightest offset.
    var bestRoundTrip = 1 << 62;
    var offset = 0;
    for (var i = 0; i < 5; i++) {
      final before = Timeline.now;
      final nativeNs = await _channel.invokeMethod<int>('clock');
      final after = Timeline.now;
      if (nativeNs == null)
        throw StateError('Native capture clock unavailable');
      if (after - before < bestRoundTrip) {
        bestRoundTrip = after - before;
        offset = (before + after) ~/ 2 - nativeNs ~/ 1000;
      }
    }
    final config =
        await _channel.invokeMapMethod<String, dynamic>('startCapture', {
      'sampleRate': sampleRate,
      'bufferSize': bufferSize,
      'audioSource': androidAudioSource,
      'clientId': clientId,
      'owner': owner,
    });
    if (config == null) throw StateError('Capture did not start');
    return CaptureSession._(
        (config['generation'] as num).toInt(),
        (config['sampleRate'] as num).round(),
        config['inputId'] as String,
        (config['audioSource'] as num?)?.toInt(),
        offset);
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

  // An idle native read returns empty after at most 250 ms.
  Future<List<CaptureBlock>> _read() async {
    if (_closed) return const [];
    final rows = await _channel.invokeListMethod<dynamic>(
        'readCapture', {'generation': generation, 'maxBlocks': 8});
    if (_closed) return const [];
    return [for (final row in rows ?? const <dynamic>[]) _block(row as Map)];
  }

  CaptureBlock _block(Map row) {
    final rate = (row['sampleRate'] as num).round();
    final token = (row['generation'] as num).toInt();
    final samples = row['audioData'] as Float32List;
    if (token != generation ||
        rate != sampleRate ||
        samples.isEmpty ||
        (row['frameCount'] as num).toInt() != samples.length) {
      throw StateError('Invalid capture block');
    }
    return CaptureBlock(
        samples: samples,
        generation: token,
        sequence: (row['sequence'] as num).toInt(),
        firstFrame: (row['firstFrame'] as num).toInt(),
        sampleRate: rate,
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
        _channel.invokeMethod<void>('stopCapture', {'generation': generation});
  }
}

/// Compatibility facade over [CaptureSession] for tuner capture: Android DEFAULT
/// source, no stall after first data. Matching should pump [CaptureSession].
class FlutterAudioCapture {
  CaptureSession? _session;
  Future<void>? _starting;
  var _revision = 0;

  /// Blocks after a gap are still delivered, so the listener splices across it.
  Future<void> start(
    void Function(Float32List) listener,
    Function onError, {
    int sampleRate = 44100,
    int bufferSize = 512,
    int androidAudioSource = ANDROID_AUDIOSRC_DEFAULT,
    Duration firstDataTimeout = const Duration(seconds: 2),
  }) {
    if (_starting != null) return _starting!;
    if (_session != null) return Future.value();
    final revision = ++_revision;
    void deliver(CaptureBlock block) {
      if (revision != _revision) return;
      listener(block.samples);
    }

    final pending = _start(revision, deliver, onError, sampleRate, bufferSize,
        androidAudioSource, firstDataTimeout);
    _starting = pending;
    // Observe errors without creating an unhandled error on a cleanup future.
    unawaited(pending.then((_) {
      if (revision == _revision) _starting = null;
    }, onError: (Object _, StackTrace __) {
      if (revision == _revision) _starting = null;
    }));
    return pending;
  }

  Future<void> _start(
      int revision,
      void Function(CaptureBlock) deliver,
      Function onError,
      int rate,
      int size,
      int source,
      Duration timeout) async {
    final session = await CaptureSession.open(
        sampleRate: rate, bufferSize: size, androidAudioSource: source);
    if (revision != _revision) {
      await session.close();
      return;
    }
    _session = session;
    // No stall: after first data it waits through silence, as before.
    final first = Completer<void>();
    unawaited(session.pump((blocks) {
      if (!first.isCompleted) first.complete();
      blocks.forEach(deliver);
    }).then((_) {
      if (!first.isCompleted) first.complete();
    }, onError: (Object error, StackTrace stack) {
      if (!first.isCompleted) {
        first.completeError(error, stack);
      } else if (revision == _revision) {
        _report(onError, error, stack);
      }
    }).whenComplete(() {
      if (identical(_session, session)) _session = null;
    }));
    try {
      await first.future.timeout(timeout,
          onTimeout: () =>
              throw TimeoutException('No microphone samples', timeout));
    } catch (_) {
      if (identical(_session, session)) _session = null;
      await session.close();
      rethrow;
    }
  }

  static void _report(Function callback, Object error, StackTrace stack) {
    if (callback is void Function(Object, StackTrace)) {
      callback(error, stack);
    } else {
      Function.apply(callback, [error]);
    }
  }

  Future<void> stop() async {
    ++_revision;
    final pending = _starting;
    _starting = null;
    final session = _session;
    _session = null;
    await session?.close();
    if (pending != null) {
      try {
        await pending;
      } catch (_) {}
    }
  }
}
