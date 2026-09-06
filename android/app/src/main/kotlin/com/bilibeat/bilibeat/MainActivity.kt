package com.bilibeat.bilibeat

import android.Manifest
import android.content.pm.PackageManager
import android.os.Build
import androidx.core.app.ActivityCompat
import com.ryanheise.audioservice.AudioServiceActivity
import io.flutter.embedding.engine.FlutterEngine
import io.flutter.plugin.common.MethodChannel

class MainActivity : AudioServiceActivity() {
    override fun configureFlutterEngine(flutterEngine: FlutterEngine) {
        super.configureFlutterEngine(flutterEngine)
        MethodChannel(
            flutterEngine.dartExecutor.binaryMessenger,
            "bilibeat/permissions",
        ).setMethodCallHandler { call, result ->
            when (call.method) {
                "requestNotifications" -> {
                    requestNotificationPermission()
                    result.success(null)
                }
                else -> result.notImplemented()
            }
        }
    }

    /// Android 13+ gates notifications behind a runtime grant. Stock Android
    /// exempts media-session notifications, but stricter OEM builds do not, so
    /// ask up front instead of discovering the missing permission on release.
    private fun requestNotificationPermission() {
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.TIRAMISU &&
            checkSelfPermission(Manifest.permission.POST_NOTIFICATIONS) !=
            PackageManager.PERMISSION_GRANTED
        ) {
            ActivityCompat.requestPermissions(
                this,
                arrayOf(Manifest.permission.POST_NOTIFICATIONS),
                1001,
            )
        }
    }
}