package com.example.story

import android.content.Context
import android.media.AudioManager
import io.flutter.embedding.android.FlutterActivity
import io.flutter.embedding.engine.FlutterEngine
import io.flutter.plugin.common.MethodChannel

class MainActivity : FlutterActivity() {
    private val channel = "com.example.story/audio_utils"

    override fun configureFlutterEngine(flutterEngine: FlutterEngine) {
        super.configureFlutterEngine(flutterEngine)
        val audioManager = getSystemService(Context.AUDIO_SERVICE) as AudioManager

        MethodChannel(flutterEngine.dartExecutor.binaryMessenger, channel)
            .setMethodCallHandler { call, result ->
                when (call.method) {
                    "muteNotificationStream" -> {
                        audioManager.adjustStreamVolume(
                            AudioManager.STREAM_NOTIFICATION,
                            AudioManager.ADJUST_MUTE,
                            0,
                        )
                        result.success(null)
                    }
                    "unmuteNotificationStream" -> {
                        audioManager.adjustStreamVolume(
                            AudioManager.STREAM_NOTIFICATION,
                            AudioManager.ADJUST_UNMUTE,
                            0,
                        )
                        result.success(null)
                    }
                    else -> result.notImplemented()
                }
            }
    }
}
