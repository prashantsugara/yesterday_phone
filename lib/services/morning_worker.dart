import 'package:flutter/foundation.dart';
import 'package:flutter_background_service/flutter_background_service.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:workmanager/workmanager.dart' as wm;
import 'package:usage_stats/usage_stats.dart';
import 'package:flutter_local_notifications/flutter_local_notifications.dart';
import 'metric_service.dart';
import 'insight_service.dart';
import 'package:intl/intl.dart';
import 'dart:convert';

const String workUniqueName = "morning_mirror_unlock_check";
const String nightlyWorkUniqueName = "morning_mirror_nightly_compute";
const String taskName = "check_first_unlock";
const String nightlyTaskName = "nightly_summary";

@pragma('vm:entry-point')
void callbackDispatcher() {
  wm.Workmanager().executeTask((task, inputData) async {
    print("[WorkManager] Task Started: $task");

    if (task == taskName || task == 'check_first_unlock_immediate') {
      await _checkUnlockAndNotify();
    } else if (task == nightlyTaskName) {
      await _performNightlySummary();
    }

    return Future.value(true);
  });
}

Future<void> _performNightlySummary() async {
  print(
    "[WorkManager] Starting Nightly Summary Computation (12:15 AM logic)...",
  );
  final prefs = await SharedPreferences.getInstance();
  final now = DateTime.now();
  final yesterday = now.subtract(const Duration(days: 1));
  final dateStr = DateFormat('yyyy-MM-dd').format(yesterday);

  // Check if already computed for yesterday
  final existingDate = prefs.getString('morning_summary_date');
  if (existingDate == dateStr && !kDebugMode) {
    print("[WorkManager] Summary for $dateStr already exists. Skipping.");
    return;
  }

  try {
    final metricService = MetricService();
    // 1. Fetch Stats for Yesterday
    // Returns: { 'topApps': [], 'totalScreenTime': int_ms, 'steps': int, 'unlocks': int, ... }
    final stats = await metricService.fetchYesterdayStats();

    // 2. Extract Key Values
    final int totalMs = stats['totalScreenTime'] ?? 0;
    final int steps = stats['steps'] ?? 0;
    final List<dynamic> apps = stats['topApps'] ?? [];

    // Format Screen Time (e.g. "4h 15m")
    final int h = totalMs ~/ 3600000;
    final int m = (totalMs % 3600000) ~/ 60000;
    final String screenTimeStr = "${h}h ${m}m";

    final String topApp = apps.isNotEmpty
        ? apps.first['packageName'] ?? 'None'
        : 'None';
    // Clean top app name if possible
    String displayTopApp = topApp;
    if (displayTopApp.contains('.')) {
      displayTopApp = displayTopApp.split('.').last;
      if (displayTopApp.isNotEmpty) {
        displayTopApp =
            displayTopApp[0].toUpperCase() + displayTopApp.substring(1);
      }
    }

    // 3. Store Values for Native Receiver
    await prefs.setString('morning_screen_time', screenTimeStr);
    await prefs.setInt('morning_steps', steps);
    await prefs.setString('morning_top_app', displayTopApp);
    await prefs.setString('morning_summary_date', dateStr);

    // 4. SAVE JSON for User Request
    await prefs.setString('morning_stats_json', jsonEncode(stats));

    // 5. Reset Notification Flag for TODAY (since we are technically in early morning)
    await prefs.setBool('morning_notification_sent_today', false);

    print(
      "[WorkManager] Nightly Summary Stored: $screenTimeStr, $steps steps, Top: $displayTopApp",
    );
    print("[WorkManager] JSON saved for date: $dateStr");
  } catch (e) {
    print("[WorkManager] Error in nightly computation: $e");
  }
}

Future<void> _checkUnlockAndNotify() async {
  final prefs = await SharedPreferences.getInstance();
  final now = DateTime.now();

  // 1. Time Window Check (e.g., 4 AM to 12 PM)
  int startHour = prefs.getInt('notification_start_hour') ?? 4;
  int startMinute = prefs.getInt('notification_start_minute') ?? 0;

  int endHour = prefs.getInt('notification_end_hour') ?? 12;
  int endMinute = prefs.getInt('notification_end_minute') ?? 0;

  // Calculate Target: 15 minutes BEFORE the start hour
  int startTotalMinutes = (startHour * 60) + startMinute;
  int targetTotalMinutes = startTotalMinutes - 15;
  int nowTotalMinutes = (now.hour * 60) + now.minute;
  int endTotalMinutes = (endHour * 60) + endMinute;

  // DEBUG OVERRIDE: Always run in valid window if Debug Mode
  bool isDebug = kDebugMode;
  if (!isDebug) {
    // Check if we are past the early start time AND before the end time
    if (nowTotalMinutes < targetTotalMinutes ||
        nowTotalMinutes >= endTotalMinutes) {
      print(
        "[WorkManager] Outside morning window (Target: $targetTotalMinutes mins). Skipping.",
      );
      return;
    }
  } else {
    print("[WorkManager] Debug Mode: Bypassing Time Window Check.");
  }

  // 2. Already Notified Today?
  bool sentToday = prefs.getBool('morning_notification_sent_today') ?? false;

  if (!isDebug) {
    if (sentToday) {
      print("[WorkManager] Already notified today. Skipping.");
      return;
    }
  } else {
    print("[WorkManager] Debug Mode: Bypassing 'Already Notified' Check.");
  }

  // 3. TRY TO START BACKGROUND SERVICE (Primary Method)
  // This "Arms the Trap" for instant detection.
  print("[WorkManager] Trying to start Background Service...");
  bool serviceStarted = false;
  try {
    final service = FlutterBackgroundService();
    if (!await service.isRunning()) {
      serviceStarted = await service.startService();
      print("[WorkManager] Service Start Signal Sent. Result: $serviceStarted");
    } else {
      serviceStarted = true;
      print("[WorkManager] Service already running.");
    }
  } catch (e) {
    print("[WorkManager] Failed to start service: $e");
    serviceStarted = false;
  }

  // 4. FALLBACK: CHECK USAGE STATS (Secondary Method)
  print("[WorkManager] Performing Fallback Usage Check...");

  // Check last 20 minutes for any interactive event
  DateTime endTime = DateTime.now();
  DateTime startTime = endTime.subtract(const Duration(minutes: 20));

  try {
    // We need permission for this. If not granted, this throws or returns empty.
    List<EventUsageInfo> events = await UsageStats.queryEvents(
      startTime,
      endTime,
    );

    bool hasRecentActivity = events.any(
      (e) =>
          e.eventType == '1' || // MOVE_TO_FOREGROUND
          e.eventType == '15' || // SCREEN_INTERACTIVE (API 28+)
          e.eventType == '16' || // SCREEN_NON_INTERACTIVE
          e.eventType == '17' || // KEYGUARD_DISMISSED
          e.eventType == '23',
    ); // ACTIVITY_RESUMED

    if (hasRecentActivity) {
      print(
        "[WorkManager] RECENT ACTIVITY DETECTED! Triggering Notification immediately.",
      );

      // Fallback Generate Insight
      String body = 'Tap to reflect on your yesterday.';
      try {
        final metricService = MetricService();
        final stats = await metricService.fetchYesterdayStats();
        body = await InsightService().generateInsight(stats);
      } catch (e) {
        print("[WorkManager] Error generating insight: $e");
      }

      // Try to use pre-computed if available
      String summaryDate = prefs.getString('morning_summary_date') ?? "";
      final yesterday = now.subtract(const Duration(days: 1));
      final yesterdayStr = DateFormat('yyyy-MM-dd').format(yesterday);

      if (summaryDate == yesterdayStr) {
        String t = prefs.getString('morning_screen_time') ?? "0m";
        int s = prefs.getInt('morning_steps') ?? 0;
        String a = prefs.getString('morning_top_app') ?? "None";
        body = "Screen time: $t • Steps: $s • Top: $a";
      }

      await _triggerLocalNotification(body);

      // Mark as done for TODAY
      await prefs.setBool('morning_notification_sent_today', true);
      // Robustness: Save the date to allow self-healing if nightly task fails
      final nowStr = DateFormat('yyyy-MM-dd').format(DateTime.now());
      await prefs.setString('morning_notification_last_sent_date', nowStr);
    } else {
      print("[WorkManager] No recent activity detected in last 20 mins.");
    }
  } catch (e) {
    print("[WorkManager] Fallback check failed (Permission?): $e");
  }
}

// DUPLICATED from background_service.dart to ensure isolation compliance
Future<void> _triggerLocalNotification(String insightBody) async {
  final flutterLocalNotificationsPlugin = FlutterLocalNotificationsPlugin();

  // Initialize for this isolate if needed
  const AndroidInitializationSettings initializationSettingsAndroid =
      AndroidInitializationSettings('@mipmap/ic_launcher');
  const InitializationSettings initializationSettings = InitializationSettings(
    android: initializationSettingsAndroid,
  );
  await flutterLocalNotificationsPlugin.initialize(initializationSettings);

  const AndroidNotificationDetails androidPlatformChannelSpecifics =
      AndroidNotificationDetails(
        'morning_mirror_alert_v2',
        'Morning Recap',
        channelDescription: 'Daily recap notification',
        importance: Importance.max,
        priority: Priority.high,
        showWhen: true,
        icon: '@drawable/ic_stat_morning',
        styleInformation: BigTextStyleInformation(''),
        autoCancel: true,
        visibility: NotificationVisibility.public,
        category: AndroidNotificationCategory.recommendation,
      );

  const NotificationDetails platformChannelSpecifics = NotificationDetails(
    android: androidPlatformChannelSpecifics,
  );

  await flutterLocalNotificationsPlugin.show(
    889, // Constant ID
    'Yesterday\'s Mirror (Worker)',
    insightBody,
    platformChannelSpecifics,
    payload: 'SHOW_STATS',
  );
}

class MorningWorker {
  static Future<void> initialize() async {
    await wm.Workmanager().initialize(
      callbackDispatcher,
      isInDebugMode: kDebugMode,
    );
  }

  static Future<void> registerPeriodicTask() async {
    await wm.Workmanager().registerPeriodicTask(
      workUniqueName,
      taskName,
      frequency: const Duration(minutes: 15), // Minimum allowed
      existingWorkPolicy: wm.ExistingPeriodicWorkPolicy.keep,
      constraints: wm.Constraints(
        networkType: wm.NetworkType.notRequired,
        requiresBatteryNotLow: false,
      ),
    );

    // NEW TASK: Nightly Computation at ~12:15 AM
    // Calculate initial delay
    final now = DateTime.now();

    // Target: Today at 00:15
    DateTime target = DateTime(now.year, now.month, now.day, 0, 15);

    // If target is in the past, schedule for tomorrow
    if (target.isBefore(now)) {
      target = target.add(const Duration(days: 1));
    }

    Duration initialDelay = target.difference(now);

    print(
      "[MorningWorker] Scheduling Nightly Task. Next run in: ${initialDelay.inHours}:${initialDelay.inMinutes % 60}",
    );

    await wm.Workmanager().registerPeriodicTask(
      nightlyWorkUniqueName,
      nightlyTaskName,
      frequency: const Duration(hours: 24),
      initialDelay: initialDelay,
      existingWorkPolicy:
          wm.ExistingPeriodicWorkPolicy.update, // UPDATE to apply new timing
      constraints: wm.Constraints(networkType: wm.NetworkType.notRequired),
    );

    /*
    // One-Off Task for testing - DISABLED for Production
    await wm.Workmanager().registerOneOffTask(
      "morning_mirror_test_immediate",
      "check_first_unlock_immediate",
      existingWorkPolicy: wm.ExistingWorkPolicy.replace,
      constraints: wm.Constraints(networkType: wm.NetworkType.notRequired),
    );
    */
  }
}
