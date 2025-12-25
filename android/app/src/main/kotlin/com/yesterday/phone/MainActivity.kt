package com.yesterday.phone

import io.flutter.embedding.android.FlutterActivity
import io.flutter.embedding.engine.FlutterEngine
import io.flutter.plugins.googlemobileads.GoogleMobileAdsPlugin

class MainActivity : FlutterActivity() {
    private val unlockReceiver = UnlockReceiver()

    override fun configureFlutterEngine(flutterEngine: FlutterEngine) {
        super.configureFlutterEngine(flutterEngine)
        GoogleMobileAdsPlugin.registerNativeAdFactory(
            flutterEngine, "listTile", ListTileNativeAdFactory(context)
        )
        
        // Dynamically register UnlockReceiver
        val filter = android.content.IntentFilter(android.content.Intent.ACTION_USER_PRESENT)
        context.registerReceiver(unlockReceiver, filter)

        io.flutter.plugin.common.MethodChannel(flutterEngine.dartExecutor.binaryMessenger, "com.yesterday.phone/device_apps").setMethodCallHandler { call, result ->
            if (call.method == "getApp") {
                val packageName = call.argument<String>("packageName")
                val includeIcon = call.argument<Boolean>("includeIcon") ?: false
                if (packageName != null) {
                    try {
                        val pm = context.packageManager
                        val info = pm.getApplicationInfo(packageName, 0)
                        val map = HashMap<String, Any?>()
                        map["appName"] = pm.getApplicationLabel(info).toString()
                        map["packageName"] = info.packageName
                        map["isSystemApp"] = (info.flags and android.content.pm.ApplicationInfo.FLAG_SYSTEM) != 0
                        if (android.os.Build.VERSION.SDK_INT >= android.os.Build.VERSION_CODES.O) {
                             map["category"] = info.category
                        }
                        
                        if (includeIcon) {
                            val iconDrawable = pm.getApplicationIcon(info)
                            val bitmap = if (iconDrawable is android.graphics.drawable.BitmapDrawable) {
                                iconDrawable.bitmap
                            } else {
                                val bmp = android.graphics.Bitmap.createBitmap(iconDrawable.intrinsicWidth, iconDrawable.intrinsicHeight, android.graphics.Bitmap.Config.ARGB_8888)
                                val canvas = android.graphics.Canvas(bmp)
                                iconDrawable.setBounds(0, 0, canvas.width, canvas.height)
                                iconDrawable.draw(canvas)
                                bmp
                            }
                            val stream = java.io.ByteArrayOutputStream()
                            bitmap.compress(android.graphics.Bitmap.CompressFormat.PNG, 100, stream)
                            map["icon"] = stream.toByteArray()
                        }
                        result.success(map)
                    } catch (e: Exception) {
                        result.success(null)
                    }
                } else {
                    result.error("INVALID_ARGS", "Package name is null", null)
                }
            } else {
                result.notImplemented()
            }
        }
    }

    override fun cleanUpFlutterEngine(flutterEngine: FlutterEngine) {
        super.cleanUpFlutterEngine(flutterEngine)
        GoogleMobileAdsPlugin.unregisterNativeAdFactory(flutterEngine, "listTile")
        
        try {
            context.unregisterReceiver(unlockReceiver)
        } catch (e: Exception) {
            // Ignore if already unregistered
        }
    }
}
