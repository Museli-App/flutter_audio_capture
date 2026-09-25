import Flutter
import UIKit

public class SwiftFlutterAudioCapturePlugin: NSObject, FlutterPlugin {
    private let capture = AudioCaptureEventStreamHandler()

    public static func register(with registrar: FlutterPluginRegistrar) {
        let channel = FlutterMethodChannel(name: "ymd.dev/audio_capture_method_channel",
            binaryMessenger: registrar.messenger(), codec: FlutterStandardMethodCodec.sharedInstance(),
            taskQueue: registrar.messenger().makeBackgroundTaskQueue?())
        registrar.addMethodCallDelegate(SwiftFlutterAudioCapturePlugin(), channel: channel)
    }

    public func handle(_ call: FlutterMethodCall, result: @escaping FlutterResult) {
        let args = call.arguments as? [String: Any] ?? [:]
        do {
            switch call.method {
            case "claim": result(capture.claim())
            case "startCapture": result(try capture.start(args))
            case "readCapture": result(try capture.read(args))
            case "stopCapture":
                capture.stop((args["generation"] as? NSNumber)?.int64Value, clientId: args["clientId"] as? String)
                result(nil)
            case "clock": result(AudioCaptureEventStreamHandler.clock())
            default: result(FlutterMethodNotImplemented)
            }
        } catch is CaptureSuperseded {
            result(FlutterError(code: "CAPTURE_SUPERSEDED", message: "Superseded by a newer capture claim", details: nil))
        } catch {
            result(FlutterError(code: "CAPTURE_FAILED", message: error.localizedDescription, details: nil))
        }
    }

    public func detachFromEngine(for registrar: FlutterPluginRegistrar) { capture.stop(nil) }
}
