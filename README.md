# flutter_audio_capture

Capture the audio stream buffer through microphone for iOS/Android.
Required OS version is iOS 13+ or Android 24+

## Getting Started

Add this line to your pubspec.yaml file:

```
dependencies:
  flutter_audio_capture: ^1.1.12
```

and execute

```
$ flutter pub get
```

### Android

If you want to use this package on Android OS, you need to set `RECORD_AUDIO` permission to `AndroidManifest.xml` like below.

```
<manifest xmlns:android="http://schemas.android.com/apk/res/android"
  package="com.ymd.flutter_audio_capture">
  ...
  // Add this line
  <uses-permission android:name="android.permission.RECORD_AUDIO"/>
</manifest>
```

### iOS

If you want to use this package on iOS, you need to set `NSMicrophoneUsageDescription` to `Info.plist` like below.

```
<dict>
    <key>NSMicrophoneUsageDescription</key>
    <string>Need microphone access to capture audio</string>
...
```

The plugin does not configure the audio session itself, so your app must
activate a record-capable `AVAudioSession` before calling `CaptureSession.open()`. The
easiest way from Dart is the
[`audio_session`](https://pub.dev/packages/audio_session) package:

```dart
import 'package:audio_session/audio_session.dart';

final session = await AudioSession.instance;
await session.configure(AudioSessionConfiguration(
  avAudioSessionCategory: AVAudioSessionCategory.playAndRecord,
  avAudioSessionCategoryOptions: AVAudioSessionCategoryOptions.mixWithOthers,
  avAudioSessionMode: AVAudioSessionMode.measurement,
));
await session.setActive(true);
```

Any equivalent native configuration (e.g. in your `AppDelegate`) works too.
Without it the session stays in the default `.soloAmbient` category, which
does not permit recording, and `open()` will report an error.

## Example

You can see full example in `example/lib/main.dart`

```dart
import 'package:flutter_audio_capture/flutter_audio_capture.dart';
...

// Start capturing; bufferSize is the frames per delivered block.
final session = await CaptureSession.open(sampleRate: 16000, bufferSize: 3000);

// Deliver each batch of timestamped blocks until closed. A gap still
// delivers, with `discontinuity` set; the first error ends the pump.
session.pump((blocks) {
  for (final block in blocks) print(block.samples);
}).catchError((Object e) => print(e));

// Stop capturing
await session.close();
```
