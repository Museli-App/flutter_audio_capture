import 'package:flutter/material.dart';
import 'dart:async';
import 'dart:typed_data';

import 'package:audio_session/audio_session.dart';
import 'package:flutter_audio_capture/flutter_audio_capture.dart';

void main() => runApp(MyApp());

class MyApp extends StatefulWidget {
  @override
  _MyAppState createState() => _MyAppState();
}

class _MyAppState extends State<MyApp> {
  CaptureSession? _session;

  Future<void> _startCapture() async {
    if (_session != null) return;
    // The plugin does not configure the audio session; the app must activate a
    // record-capable one before open().
    final session = await AudioSession.instance;
    await session.configure(AudioSessionConfiguration(
      avAudioSessionCategory: AVAudioSessionCategory.playAndRecord,
      avAudioSessionCategoryOptions: AVAudioSessionCategoryOptions.mixWithOthers,
      avAudioSessionMode: AVAudioSessionMode.measurement,
    ));
    await session.setActive(true);
    final capture = _session =
        await CaptureSession.open(sampleRate: 16000, bufferSize: 3000);
    // Pumps until closed; a gap still delivers, flagged discontinuous.
    capture
        .pump((blocks) => blocks.forEach((block) => listener(block.samples)))
        .catchError(onError);
  }

  Future<void> _stopCapture() async {
    final capture = _session;
    _session = null;
    await capture?.close();
  }

  void listener(Float32List buffer) {
    print(buffer);
  }

  void onError(Object e) {
    print(e);
  }

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      home: Scaffold(
        appBar: AppBar(
          title: const Text('Flutter Audio Capture Plugin'),
        ),
        body: Column(children: [
          Expanded(
              child: Row(
            children: [
              Expanded(
                  child: Center(
                      child: FloatingActionButton(
                          onPressed: _startCapture, child: Text("Start")))),
              Expanded(
                  child: Center(
                      child: FloatingActionButton(
                          onPressed: _stopCapture, child: Text("Stop")))),
            ],
          ))
        ]),
      ),
    );
  }
}
