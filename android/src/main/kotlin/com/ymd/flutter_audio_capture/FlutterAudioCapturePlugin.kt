package com.ymd.flutter_audio_capture

import io.flutter.embedding.engine.plugins.FlutterPlugin
import io.flutter.plugin.common.MethodCall
import io.flutter.plugin.common.MethodChannel
import io.flutter.plugin.common.StandardMethodCodec

class FlutterAudioCapturePlugin: FlutterPlugin, MethodChannel.MethodCallHandler {
    private lateinit var capture: AudioCaptureStreamHandler
    private var channel: MethodChannel? = null

    override fun onAttachedToEngine(binding: FlutterPlugin.FlutterPluginBinding) {
        capture = AudioCaptureStreamHandler(binding.applicationContext)
        channel = MethodChannel(binding.binaryMessenger, "ymd.dev/audio_capture_method_channel",
            StandardMethodCodec.INSTANCE, binding.binaryMessenger.makeBackgroundTaskQueue())
        channel!!.setMethodCallHandler(this)
    }

    override fun onMethodCall(call: MethodCall, result: MethodChannel.Result) {
        try {
            when (call.method) {
                "startCapture" -> result.success(capture.start(call.argument<Int>("sampleRate") ?: 44100,
                    call.argument<Int>("bufferSize") ?: 512, call.argument<Int>("audioSource"), call.argument<String>("clientId")))
                "readCapture" -> result.success(capture.read(call.argument<Number>("generation")!!.toLong(), call.argument<Int>("maxBlocks") ?: 8))
                "stopCapture" -> { capture.stop(call.argument<Number>("generation")?.toLong(), call.argument<String>("clientId")); result.success(null) }
                "clock" -> result.success(System.nanoTime())
                else -> result.notImplemented()
            }
        } catch (error: Exception) {
            result.error("CAPTURE_FAILED", error.message, null)
        }
    }

    override fun onDetachedFromEngine(binding: FlutterPlugin.FlutterPluginBinding) {
        channel?.setMethodCallHandler(null)
        capture.stop(null)
        channel = null
    }
}
