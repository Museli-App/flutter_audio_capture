import 'dart:async';
import 'dart:developer';
import 'dart:typed_data';

import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:flutter_audio_capture/flutter_audio_capture.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  const channel = MethodChannel(AUDIO_CAPTURE_METHOD_CHANNEL_NAME);
  final messenger =
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;
  late List<MethodCall> calls;
  late Future<Object?> Function(MethodCall) answer;
  Map<String, Object> block() => {
        'sequence': 2,
        'firstFrame': 1024,
        'captureTimeNs': 1000000000,
        'discontinuity': true,
        'audioData': Float32List.fromList([0.25, -0.25]),
      };
  setUp(() {
    calls = [];
    answer = (call) async {
      switch (call.method) {
        case 'claim':
          return 41;
        case 'clock':
          return 1000000000;
        case 'startCapture':
          return {'generation': 7, 'sampleRate': 44100};
        case 'readCapture':
          return [block()];
        case 'stopCapture':
          return null;
        default:
          throw StateError(call.method);
      }
    };
    messenger.setMockMethodCallHandler(channel, (call) {
      calls.add(call);
      return answer(call);
    });
  });
  tearDown(() => messenger.setMockMethodCallHandler(channel, null));

  // Pumps [session] until its first batch, then closes it.
  Future<List<CaptureBlock>> firstBatch(CaptureSession session) async {
    List<CaptureBlock>? first;
    await session.pump((blocks) {
      first ??= blocks;
      unawaited(session.close());
    });
    return first!;
  }

  // Models the native idle read, which returns empty after a bounded wait.
  Future<Object?> emptyRead() =>
      Future.delayed(const Duration(milliseconds: 1), () => <Object>[]);

  test('pull blocks retain sample position, discontinuity, and format',
      () async {
    final session = await CaptureSession.open(clientId: 'matcher');
    final blocks = await firstBatch(session);
    expect(blocks.single.samples, [0.25, -0.25]);
    expect(blocks.single.firstFrame, 1024);
    expect(blocks.single.sequence, 2);
    expect(blocks.single.discontinuity, isTrue);
    expect(blocks.single.sampleRate, 44100);
    final read = calls.firstWhere((c) => c.method == 'readCapture');
    expect(read.arguments, {'generation': 7});
    await session.close();
    await session.close();
    expect(calls.where((c) => c.method == 'stopCapture').length, 1);
  });

  test('open claims before the clock sync and starts as that owner', () async {
    final session = await CaptureSession.open();
    expect(calls.take(2).map((c) => c.method), ['claim', 'clock']);
    final start = calls.singleWhere((c) => c.method == 'startCapture');
    expect((start.arguments as Map)['owner'], 41);
    await session.close();
  });

  test('a missing claim reply never starts capture', () async {
    final original = answer;
    answer = (call) async => call.method == 'claim' ? null : original(call);
    await expectLater(CaptureSession.open(), throwsStateError);
    expect(calls.map((c) => c.method), ['claim']);
  });

  test('automatic source selection is left to native', () async {
    final session = await CaptureSession.open();
    final start = calls.singleWhere((call) => call.method == 'startCapture');
    expect((start.arguments as Map)['audioSource'], isNull);
    await session.close();
  });

  test('explicit Android source is sent', () async {
    final session = await CaptureSession.open(
      androidAudioSource: ANDROID_AUDIOSRC_VOICERECOGNITION,
    );
    final start = calls.singleWhere((call) => call.method == 'startCapture');
    expect((start.arguments as Map)['audioSource'],
        ANDROID_AUDIOSRC_VOICERECOGNITION);
    await session.close();
  });

  test('the clock offset keeps the shortest round trip', () async {
    // flutter_pcm_sound pins its estimator on the same samples.
    var exchanges = 0;
    final offsetUs = await timelineOffsetUs(() async {
      // The slow first exchange reads 5 s off; a fast one must win.
      if (exchanges++ == 0) {
        await Future<void>.delayed(const Duration(milliseconds: 30));
        return Timeline.now * 1000 + 14000000000;
      }
      return Timeline.now * 1000 + 9000000000;
    });
    expect(exchanges, 5);
    expect(offsetUs, closeTo(-9000000, 2000));
    await expectLater(timelineOffsetUs(() async => null), throwsStateError);
  });

  test('capture time maps the native clock into Timeline.now', () async {
    const nativeAheadNs = 7000000000000;
    final original = answer;
    late int dartUs;
    answer = (call) async {
      switch (call.method) {
        case 'clock':
          return Timeline.now * 1000 + nativeAheadNs;
        case 'readCapture':
          dartUs = Timeline.now;
          return [block()..['captureTimeNs'] = dartUs * 1000 + nativeAheadNs];
      }
      return original(call);
    };
    final session = await CaptureSession.open();
    final captured = (await firstBatch(session)).single;
    expect((captured.captureTimeUs - dartUs).abs(), lessThanOrEqualTo(20000));
    expect(captured.endTimeUs - captured.captureTimeUs, 2 * 1000000 ~/ 44100);
    await session.close();
  });

  test('an empty block fails the pump and closes', () async {
    final session = await CaptureSession.open();
    answer = (call) async => call.method == 'readCapture'
        ? [block()..['audioData'] = Float32List(0)]
        : null;
    await expectLater(session.pump((_) {}), throwsStateError);
    expect(calls.where((c) => c.method == 'stopCapture').length, 1);
  });

  test('one pump at a time; close discards the late batch', () async {
    final session = await CaptureSession.open();
    final data = Completer<Object?>();
    answer = (call) async => call.method == 'readCapture' ? data.future : null;
    var batches = 0;
    final pumping = session.pump((_) => batches++);
    await expectLater(session.pump((_) {}), throwsStateError);
    await session.close();
    data.complete([block()]);
    await pumping;
    expect(batches, 0);
    expect(calls.where((c) => c.method == 'stopCapture').length, 1);
  });

  test('pump fails after the stall without samples and closes', () async {
    final original = answer;
    answer =
        (call) => call.method == 'readCapture' ? emptyRead() : original(call);
    final session = await CaptureSession.open();
    await expectLater(
        session
            .pump((_) {}, stall: const Duration(milliseconds: 20))
            .timeout(const Duration(seconds: 2)),
        throwsA(isA<TimeoutException>()
            .having((e) => e.message, 'message', 'No capture samples')));
    expect(calls.where((c) => c.method == 'stopCapture').length, 1);
  });

  test('close is awaited by every caller and uses the original generation',
      () async {
    final session = await CaptureSession.open();
    final stopped = Completer<Object?>();
    answer = (_) => stopped.future;
    var completed = 0;
    final first = session.close().then((_) => completed++);
    final second = session.close().then((_) => completed++);
    await Future<void>.delayed(Duration.zero);
    expect(completed, 0);
    expect((calls.last.arguments as Map)['generation'], 7);
    stopped.complete(null);
    await Future.wait([first, second]);
    expect(completed, 2);
  });

  test('closeClient stops by client id, not generation', () async {
    await CaptureSession.closeClient('previous-owner');
    expect(calls.single.method, 'stopCapture');
    expect(calls.single.arguments, {'clientId': 'previous-owner'});
  });

  test('invalid format never starts capture', () async {
    await expectLater(
        CaptureSession.open(sampleRate: 192001), throwsArgumentError);
    expect(calls, isEmpty);
  });

  test('a superseded start creates no session and stops no one', () async {
    final original = answer;
    answer = (call) async => call.method == 'startCapture'
        ? throw PlatformException(code: 'CAPTURE_SUPERSEDED')
        : original(call);
    await expectLater(
        CaptureSession.open(),
        throwsA(isA<PlatformException>()
            .having((e) => e.code, 'code', 'CAPTURE_SUPERSEDED')));
    expect(
        calls.map((c) => c.method).toSet(), {'claim', 'clock', 'startCapture'});
    // Nothing is held, so the next open starts afresh.
    answer = original;
    final session = await CaptureSession.open();
    expect(calls.where((c) => c.method == 'startCapture').length, 2);
    await session.close();
  });
}
