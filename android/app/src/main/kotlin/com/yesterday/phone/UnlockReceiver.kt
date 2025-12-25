package com.yesterday.phone

import android.content.BroadcastReceiver
import android.content.Context
import android.content.Intent
import android.util.Log     
import java.text.SimpleDateFormat
import java.util.Date
import java.util.Locale
import java.util.Calendar // Might need this later, harmless to add

class UnlockReceiver : BroadcastReceiver() {
    override fun onReceive(context: Context, intent: Intent) {
        if (Intent.ACTION_USER_PRESENT == intent.action) {
            Log.d("UnlockReceiver", "!!! USER PRESENT DETECTED !!! Starting Morning Mirror Check...")

            val prefs = context.getSharedPreferences("FlutterSharedPreferences", Context.MODE_PRIVATE)
            
            // --- ROBUSTNESS: Check Date to Self-Heal ---
            val sdf = SimpleDateFormat("yyyy-MM-dd", Locale.getDefault())
            val todayStr = sdf.format(Date())
            val lastSentDate = prefs.getString("flutter.morning_notification_last_sent_date", "")
            
            // If the last sent date is NOT today, we force 'alreadySent' to False
            // This handles cases where the Nightly Worker failed (e.g. phone off)
            var alreadySent = prefs.getBoolean("flutter.morning_notification_sent_today", false)
            if (lastSentDate != todayStr) {
                 Log.d("UnlockReceiver", "New Day Detected ($todayStr vs $lastSentDate). Resetting 'sent' flag implicitly.")
                 alreadySent = false
                 // Update the flag in storage to keep it clean (optional but good)
                 prefs.edit().putBoolean("flutter.morning_notification_sent_today", false).apply()
            } // Else: Trust the flag

            Log.d("UnlockReceiver", "Flag 'morning_notification_sent_today' (Effective): $alreadySent")

            if (alreadySent) {
                Log.d("UnlockReceiver", ">> EXIT: Already notified today.")
                return
            }

            // 2. Check Time Window
            val now = java.util.Calendar.getInstance()
            val hour = now.get(java.util.Calendar.HOUR_OF_DAY)
            val minute = now.get(java.util.Calendar.MINUTE)
            val nowTotalMinutes = hour * 60 + minute
            
            // Default 6 AM - 11 AM if not set
            val startHour = prefs.getLong("flutter.notification_start_hour", 4).toInt()
            val startMinute = prefs.getLong("flutter.notification_start_minute", 0).toInt()
            val startTotalMinutes = startHour * 60 + startMinute

            val endHour = prefs.getLong("flutter.notification_end_hour", 12).toInt() // User usually sets this to something like 11 or 12
            val endMinute = prefs.getLong("flutter.notification_end_minute", 0).toInt()
            val endTotalMinutes = endHour * 60 + endMinute

            Log.d("UnlockReceiver", "Time Check: Current=$hour:$minute ($nowTotalMinutes)  | Window=$startHour:$startMinute ($startTotalMinutes) to $endHour:$endMinute ($endTotalMinutes)")

            if (nowTotalMinutes < startTotalMinutes || nowTotalMinutes >= endTotalMinutes) {
                Log.d("UnlockReceiver", ">> EXIT: Outside coverage window.")
                return
            }

            var screenTime = prefs.getString("flutter.morning_screen_time", "0m")
            var steps = prefs.getLong("flutter.morning_steps", 0)
            var topApp = prefs.getString("flutter.morning_top_app", "None")

            // 3. Check if Summary is Ready for Yesterday
            val summaryDate = prefs.getString("flutter.morning_summary_date", "")
            val yesterday = java.util.Calendar.getInstance()
            yesterday.add(java.util.Calendar.DAY_OF_YEAR, -1)
            val yesterdayStr = java.text.SimpleDateFormat("yyyy-MM-dd", java.util.Locale.US).format(yesterday.time)

            Log.d("UnlockReceiver", "Data Check: Needed Date=$yesterdayStr | Found Date=$summaryDate")
            Log.d("UnlockReceiver", "Data Values: ScreenTime=$screenTime, Steps=$steps, TopApp=$topApp")

            var isGeneric = false
            if (summaryDate != yesterdayStr) {
                Log.d("UnlockReceiver", ">> NOTICE: Summary data mismatch. Preparing GENERIC notification.")
                isGeneric = true
            }

            // 4. Trigger Notification
            Log.i("UnlockReceiver", ">>> ALL CONDITIONS MET! Sending Notification (Generic: $isGeneric) <<<")
            
            if (isGeneric) {
                 sendNotification(context, null, 0, null)
            } else {
                 sendNotification(context, screenTime, steps, topApp)
            }
            
            // Mark as sent for today
            Log.d("UnlockReceiver", ">> SUCCESS: Marking as sent for today ($todayStr).")
            prefs.edit()
                .putBoolean("flutter.morning_notification_sent_today", true)
                .putString("flutter.morning_notification_last_sent_date", todayStr)
                .apply()
        }
    }

    private fun sendNotification(context: Context, screenTime: String?, steps: Long, topApp: String?) {
        val channelId = "morning_mirror_alert_v2" // Must match Dart side for consistency if needed, or create new
        val notificationId = 889

        val nm = context.getSystemService(Context.NOTIFICATION_SERVICE) as android.app.NotificationManager

        // Ensure Channel Exists (Native side creation to be safe)
        if (android.os.Build.VERSION.SDK_INT >= android.os.Build.VERSION_CODES.O) {
            val channel = android.app.NotificationChannel(
                channelId,
                "Morning Recap",
                android.app.NotificationManager.IMPORTANCE_HIGH
            )
            channel.description = "Daily recap notification"
            nm.createNotificationChannel(channel)
        }

        val intent = android.content.Intent(context, MainActivity::class.java)
        intent.flags = android.content.Intent.FLAG_ACTIVITY_NEW_TASK or android.content.Intent.FLAG_ACTIVITY_CLEAR_TASK
        // Add payload if needed by Flutter side
        intent.putExtra("route", "/dashboard") 
        intent.putExtra("payload", "SHOW_STATS")

        val pendingIntent = android.app.PendingIntent.getActivity(
            context, 
            0, 
            intent, 
            android.app.PendingIntent.FLAG_UPDATE_CURRENT or android.app.PendingIntent.FLAG_IMMUTABLE
        )

        var contentText = "Tap to view your yesterday's summary."
        if (screenTime != null && topApp != null) {
             contentText = "Screen time: $screenTime • Steps: $steps • Top: $topApp"
        }

        val builder = android.app.Notification.Builder(context)
            .setSmallIcon(android.R.drawable.ic_menu_my_calendar) // Fallback icon, ideally use R.drawable.ic_stat_morning if available
            .setContentTitle("Yesterday's Summary")
            .setContentText(contentText)
            .setStyle(android.app.Notification.BigTextStyle().bigText(contentText))
            .setAutoCancel(true)
            .setContentIntent(pendingIntent)
        
        if (android.os.Build.VERSION.SDK_INT >= android.os.Build.VERSION_CODES.O) {
            builder.setChannelId(channelId)
        }
        
        // Try to load custom icon by name if possible, or stick to system default for now to avoid resource compilation errors
        // resource lookup: context.resources.getIdentifier("ic_stat_morning", "drawable", context.packageName)

        val iconResId = context.resources.getIdentifier("ic_stat_morning", "drawable", context.packageName)
        if (iconResId != 0) {
            builder.setSmallIcon(iconResId)
        }

        nm.notify(notificationId, builder.build())
    }
}
