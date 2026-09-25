# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## Project Overview

flutter_audio_capture is a Flutter plugin that captures audio stream buffer from the microphone. It supports iOS 13+ and Android 24+.

## Build and Development Commands

```bash
# Get dependencies
flutter pub get

# Run tests
flutter test

# Analyze code
flutter analyze

# Generate documentation
flutter pub global run dartdoc

# Run the example app (from example/ directory)
cd example && flutter run
```

## Architecture

This is a Flutter federated plugin with platform-specific implementations communicating via Flutter platform channels:

- **Dart API** (`lib/flutter_audio_capture.dart`): `CaptureSession` request/response reads over a `MethodChannel` (the host app's matching path, pumped in its pitch worker), plus the `FlutterAudioCapture` compatibility facade (its tuner path)
- **Android** (`android/src/main/kotlin/`): Kotlin implementation using `AudioRecord` API with a background thread for capturing. `AudioCaptureStreamHandler` handles the actual recording loop
- **iOS** (`ios/Classes/`): Swift implementation using `AVAudioEngine` with an `AVAudioSinkNode` for buffer capture. `AudioCapture` manages only the engine — the host app owns the `AVAudioSession` (category, mode, activation) and must configure a record-capable one before `start()`

### Channel Names
- Method channel: `ymd.dev/audio_capture_method_channel` (no event channel)

### Usage Pattern
```dart
FlutterAudioCapture plugin = FlutterAudioCapture();
await plugin.start(listener, onError, sampleRate: 16000, bufferSize: 3000);
await plugin.stop();
```

**Note**: Android audio source can be configured via `androidAudioSource` parameter using constants like `ANDROID_AUDIOSRC_MIC`, `ANDROID_AUDIOSRC_VOICERECOGNITION`, etc.

### Platform Permissions Required
- **Android**: `RECORD_AUDIO` permission in AndroidManifest.xml
- **iOS**: `NSMicrophoneUsageDescription` in Info.plist
