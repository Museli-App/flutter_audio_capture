enum AudioCaptureEventStreamHandlerErrorCode {
    static let onListenFailed = "ON_LISTEN_FAILED"
    static let whileListeningFailed = "WHILE_LISTENING_FAILED"
}

class AudioCaptureEventStreamHandler: NSObject, FlutterStreamHandler {
    let eventChannelName = "ymd.dev/audio_capture_event_channel"
    let audioCapture = AudioCapture()
    var eventSink: FlutterEventSink?
    var actualSampleRate: Float64?
    /// Generation counter, main-thread only. A tap callback still in flight
    /// across a back-to-back cancel→listen carries the old session's token, so
    /// `send` drops it instead of emitting into the new session's sink.
    private var session = 0

    func onListen(withArguments arguments: Any?, eventSink events: @escaping FlutterEventSink) -> FlutterError? {
        session += 1
        let token = session
        eventSink = events
        let args = arguments as? Dictionary<String, Any> ?? [:]
        let bufferSize: UInt32 = args["bufferSize"] as? UInt32 ?? 4000
        let sampleRate: Double = args["sampleRate"] as? Double ?? 16000.0
        do {
            actualSampleRate = try audioCapture.startSession(bufferSize: bufferSize, sampleRate: sampleRate) { [weak self] buffer, sampleRate, err in
                if let e = err {
                    self?.send(FlutterError(code: AudioCaptureEventStreamHandlerErrorCode.whileListeningFailed,
                                            message: "Error occurred while capturing audio",
                                            details: e.localizedDescription), for: token)
                } else if let audioData = buffer {
                    self?.send([
                        "actualSampleRate": sampleRate,
                        "audioData": audioData
                    ], for: token)
                }
            }
        } catch let error {
            actualSampleRate = nil
            send(FlutterError(code: AudioCaptureEventStreamHandlerErrorCode.onListenFailed,
                              message: "Error occurred while starting audio capture",
                              details: error.localizedDescription), for: token)
        }
        return nil
    }

    func onCancel(withArguments arguments: Any?) -> FlutterError? {
        session += 1
        actualSampleRate = nil
        eventSink = nil
        audioCapture.stopSession()
        return nil
    }

    private func send(_ event: Any, for token: Int) {
        DispatchQueue.main.async {
            guard token == self.session, let sink = self.eventSink else { return }
            sink(event)
        }
    }
}
