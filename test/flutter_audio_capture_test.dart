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
  Map<String, Object> block({int generation = 7, int rate = 44100}) => {
        'generation': generation,
        'sampleRate': rate,
        'sequence': 2,
        'firstFrame': 1024,
        'captureTimeNs': 1000000000,
        'discontinuity': true,
        'frameCount': 2,
        'audioData': Float32List.fromList([0.25, -0.25]),
      };
  setUp(() {
    calls = [];
    answer = (call) async {
      switch (call.method) {
        case 'clock':
          return 1000000000;
        case 'startCapture':
          return {'generation': 7, 'sampleRate': 44100, 'inputId': 'builtin'};
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
    expect(session.inputId, 'builtin');
    expect(calls.first.method, 'clock');
    await session.close();
    await session.close();
    expect(calls.where((c) => c.method == 'stopCapture').length, 1);
  });

  test('automatic source selection reports native configuration', () async {
    final original = answer;
    answer = (call) async {
      if (call.method == 'startCapture') {
        expect((call.arguments as Map)['audioSource'], isNull);
        return {
          'generation': 7,
          'sampleRate': 44100,
          'inputId': '2',
          'audioSource': 9
        };
      }
      return original(call);
    };
    final session = await CaptureSession.open();
    expect(session.androidAudioSource, ANDROID_AUDIOSRC_UNPROCESSED);
    await session.close();
  });

  test('explicit Android source is preserved', () async {
    final original = answer;
    answer = (call) async {
      if (call.method != 'startCapture') return original(call);
      final source = (call.arguments as Map)['audioSource'];
      return {
        'generation': 7,
        'sampleRate': 44100,
        'inputId': '2',
        'audioSource': source
      };
    };
    final session = await CaptureSession.open(
      androidAudioSource: ANDROID_AUDIOSRC_VOICERECOGNITION,
    );
    final start = calls.singleWhere((call) => call.method == 'startCapture');
    expect((start.arguments as Map)['audioSource'],
        ANDROID_AUDIOSRC_VOICERECOGNITION);
    expect(session.androidAudioSource, ANDROID_AUDIOSRC_VOICERECOGNITION);
    await session.close();
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

  test('rejects stale native generation and changed sample rate', () async {
    final original = answer;
    for (final bad in [block(generation: 8), block(rate: 48000)]) {
      answer = original;
      final session = await CaptureSession.open();
      answer = (call) async => call.method == 'readCapture' ? [bad] : null;
      await expectLater(session.pump((_) {}), throwsStateError);
    }
    expect(calls.where((c) => c.method == 'stopCapture').length, 2);
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
    answer = (call) =>
        call.method == 'readCapture' ? emptyRead() : original(call);
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

  test('compatibility facade handles a one-argument error callback', () async {
    final failed = Completer<Object>();
    final original = answer;
    var reads = 0;
    answer = (call) async {
      if (call.method == 'readCapture' && ++reads > 1)
        throw PlatformException(code: 'CAPTURE_FAILED');
      if (call.method == 'readCapture')
        return [block()..['discontinuity'] = false];
      return original(call);
    };
    final capture = FlutterAudioCapture();
    await capture.start((_) {}, (Object error) => failed.complete(error));
    expect(await failed.future.timeout(const Duration(seconds: 2)),
        isA<PlatformException>());
    await capture.stop();
  });

  // Serves [batches] in order, then parks reads like an idle native queue.
  void serveReads(List<List<Object>> batches) {
    final original = answer;
    var reads = 0;
    answer = (call) {
      if (call.method != 'readCapture') return original(call);
      final index = reads++;
      return index < batches.length
          ? Future.value(batches[index])
          : Completer<Object?>().future;
    };
  }

  test('facade delivers across a gap', () async {
    final events = <String>[];
    final gapRead = Completer<void>();
    serveReads([
      [block()..['discontinuity'] = false],
      [block()],
    ]);
    final capture = FlutterAudioCapture();
    await capture.start((samples) {
      events.add('samples $samples');
      if (events.length == 2) gapRead.complete();
    }, (Object error) => events.add('error $error'));
    await gapRead.future.timeout(const Duration(seconds: 2));
    expect(events, ['samples [0.25, -0.25]', 'samples [0.25, -0.25]']);
    await capture.stop();
  });

  test('facade defaults to Android DEFAULT source and shares a pending start',
      () async {
    serveReads([
      [block()]
    ]);
    final capture = FlutterAudioCapture();
    final first = capture.start((_) {}, (Object _) {});
    expect(identical(capture.start((_) {}, (Object _) {}), first), isTrue);
    await first;
    final start = calls.singleWhere((call) => call.method == 'startCapture');
    expect((start.arguments as Map)['audioSource'], ANDROID_AUDIOSRC_DEFAULT);
    expect(capture.actualSampleRate, 44100);
    await capture.stop();
    expect(capture.actualSampleRate, isNull);
  });

  test('facade stop during the first-data wait closes the session', () async {
    final original = answer;
    final reading = Completer<void>();
    final release = Completer<Object?>();
    answer = (call) {
      if (call.method != 'readCapture') return original(call);
      reading.complete();
      return release.future;
    };
    final capture = FlutterAudioCapture();
    final pending = capture.start((_) {}, (Object _) {});
    await reading.future;
    final stopped = capture.stop();
    release.complete([block()]);
    await stopped;
    await pending;
    expect(calls.where((c) => c.method == 'stopCapture').length, 1);
    expect(capture.actualSampleRate, isNull);
  });

  test('facade times out when no samples arrive and closes the session',
      () async {
    final original = answer;
    answer = (call) =>
        call.method == 'readCapture' ? emptyRead() : original(call);
    final capture = FlutterAudioCapture();
    await expectLater(
        capture.start((_) {}, (Object _) {},
            firstDataTimeout: const Duration(milliseconds: 20)),
        throwsA(isA<TimeoutException>()));
    expect(calls.where((c) => c.method == 'stopCapture').length, 1);
    await capture.stop();
  });

  test('facade keeps waiting through silence after first data', () async {
    final original = answer;
    var reads = 0;
    answer = (call) {
      if (call.method != 'readCapture') return original(call);
      final index = reads++;
      if (index == 0 || index == 12)
        return Future.value([block()..['discontinuity'] = false]);
      if (index > 12) return Completer<Object?>().future;
      return Future.delayed(const Duration(milliseconds: 5), () => <Object>[]);
    };
    final second = Completer<void>();
    final errors = <Object>[];
    var delivered = 0;
    final capture = FlutterAudioCapture();
    await capture.start((_) {
      if (++delivered == 2) second.complete();
    }, (Object error) => errors.add(error),
        firstDataTimeout: const Duration(milliseconds: 20));
    await second.future.timeout(const Duration(seconds: 2));
    expect(errors, isEmpty);
    await capture.stop();
    expect(calls.where((c) => c.method == 'stopCapture').length, 1);
  });
}
