package dev.hnudash.hnu_dash_mobile

import android.os.SystemClock
import android.provider.Settings
import io.flutter.embedding.android.FlutterActivity
import io.flutter.embedding.engine.FlutterEngine
import io.flutter.plugin.common.MethodChannel

class MainActivity : FlutterActivity() {
    override fun configureFlutterEngine(flutterEngine: FlutterEngine) {
        super.configureFlutterEngine(flutterEngine)
        MethodChannel(
            flutterEngine.dartExecutor.binaryMessenger,
            "dev.hnudash.mobile/clock_evidence"
        ).setMethodCallHandler { call, result ->
            if (call.method != "observe") {
                result.notImplemented()
                return@setMethodCallHandler
            }
            val elapsed = SystemClock.elapsedRealtime()
            val wall = System.currentTimeMillis()
            val boot = try {
                Settings.Global.getInt(contentResolver, Settings.Global.BOOT_COUNT, -1)
                    .takeIf { it >= 0 }?.let { "boot_$it" }
            } catch (_: Exception) {
                null
            }
            result.success(mapOf("elapsed_ms" to elapsed, "wall_ms" to wall, "boot" to boot))
        }
    }
}
