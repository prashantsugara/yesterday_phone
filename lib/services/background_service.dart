import 'dart:async';
import 'package:flutter/foundation.dart'; // for kDebugMode
import 'dart:ui';
import 'package:flutter_background_service/flutter_background_service.dart';
import 'package:flutter_local_notifications/flutter_local_notifications.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'metric_service.dart';
import 'step_service.dart';
import 'insight_service.dart';
import 'package:screen_state/screen_state.dart';

const notificationChannelId = 'morning_mirror_service';
const notificationId = 888;
const notificationChannelName = 'Morning Mirror Service';

Future<void> initializeService() async {
  final service = FlutterBackgroundService();

  const AndroidNotificationChannel channel = AndroidNotificationChannel(
    notificationChannelId,
    notificationChannelName,
    description: 'Background service for Morning Mirror',
    importance: Importance.low, // Visible icon, but silent
  );

  final FlutterLocalNotificationsPlugin flutterLocalNotificationsPlugin =
      FlutterLocalNotificationsPlugin();

  await flutterLocalNotificationsPlugin
      .resolvePlatformSpecificImplementation<
        AndroidFlutterLocalNotificationsPlugin
      >()
      ?.createNotificationChannel(channel);

  await service.configure(
    androidConfiguration: AndroidConfiguration(
      onStart: onStart,
      autoStart: false, // Changed to false: managed by WorkManager
      isForegroundMode: true,
      notificationChannelId: notificationChannelId,
      initialNotificationTitle: 'Yesterday Phone',
      initialNotificationContent: 'Monitoring usage...',
      foregroundServiceNotificationId: notificationId,
    ),
    iosConfiguration: IosConfiguration(
      // Not supporting iOS as per prompt "Android-specific"
      autoStart: false,
      onForeground: onStart,
      onBackground: onIosBackground,
    ),
  );
}

@pragma('vm:entry-point')
Future<bool> onIosBackground(ServiceInstance service) async {
  return true;
}

@pragma('vm:entry-point')
void onStart(ServiceInstance service) async {
  DartPluginRegistrant.ensureInitialized();

  // Initialize Local Notifications for this isolate
  final flutterLocalNotificationsPlugin = FlutterLocalNotificationsPlugin();
  const AndroidInitializationSettings initializationSettingsAndroid =
      AndroidInitializationSettings('@mipmap/ic_launcher');
  const InitializationSettings initializationSettings = InitializationSettings(
    android: initializationSettingsAndroid,
  );
  await flutterLocalNotificationsPlugin.initialize(initializationSettings);

  // Initialize dependencies
  final prefs = await SharedPreferences.getInstance();
  final metricService = MetricService();

  // Update the Foreground Notification with the correct ICON
  // The initial one setup by the service might use the default "leaf".
  // We overwrite it here with our custom icon.
  final AndroidNotificationDetails androidPlatformChannelSpecifics =
      AndroidNotificationDetails(
        notificationChannelId,
        notificationChannelName,
        channelDescription: 'Background monitoring service',
        importance: Importance.low, // silent
        priority: Priority.low,
        icon: '@drawable/ic_stat_morning', // CUSTOM ICON
        showWhen: false,
        ongoing: true, // Non-dismissible
        autoCancel: false,
      );
  final NotificationDetails platformChannelSpecifics = NotificationDetails(
    android: androidPlatformChannelSpecifics,
  );
  await flutterLocalNotificationsPlugin.show(
    notificationId,
    'Yesterday Phone',
    'Tracking your digital wellbeing',
    platformChannelSpecifics,
  );

  // Listen for native events (forwarded from MainActivity/Receiver)
  // Initialize Local Step Tracking
  final stepService = StepService();
  await stepService.init();

  // Initialize Screen State Stream for INSTANT Unlock Verification
  final Screen _screen = Screen();
  StreamSubscription<ScreenStateEvent>? _screenSubscription;

  try {
    _screenSubscription = _screen.screenStateStream!.listen((
      ScreenStateEvent event,
    ) async {
      if (event == ScreenStateEvent.SCREEN_UNLOCKED) {
        debugPrint("[BackgroundService] Unlock Detected: $event");

        await prefs.reload();
        final now = DateTime.now();
        int startHour = prefs.getInt('notification_start_hour') ?? 4;
        int startMinute = prefs.getInt('notification_start_minute') ?? 0;

        int endHour = prefs.getInt('notification_end_hour') ?? 12;
        int endMinute = prefs.getInt('notification_end_minute') ?? 0;

        int nowTotalMs = now.hour * 60 + now.minute;
        int startTotalMs = startHour * 60 + startMinute;
        int endTotalMs = endHour * 60 + endMinute;

        // Unified Check: Valid Window?
        if (nowTotalMs >= startTotalMs && nowTotalMs < endTotalMs) {
          // Unified Check: Already Sent Today?
          bool sentToday =
              prefs.getBool('morning_notification_sent_today') ?? false;
          if (sentToday) {
            debugPrint("[BackgroundService] Already notified today. Skipping.");
            return;
          }

          // Unified Check: Summary Ready? (Optional strictness, but good for consistency)
          String summaryDate = prefs.getString('morning_summary_date') ?? "";
          // Format yesterday
          final yesterday = now.subtract(const Duration(days: 1));
          final yesterdayStr =
              "${yesterday.year}-${yesterday.month.toString().padLeft(2, '0')}-${yesterday.day.toString().padLeft(2, '0')}";

          // Note: If nightly job hasn't run, summaryDate might be old.
          // If strict, we return. If loose, we compute on the fly.
          // Let's compute on the fly if missing (Fallback behavior).
          String body = "Tap to reflect on your yesterday.";

          if (summaryDate == yesterdayStr) {
            // Use pre-computed
            String t = prefs.getString('morning_screen_time') ?? "0m";
            int s = prefs.getInt('morning_steps') ?? 0;
            String a = prefs.getString('morning_top_app') ?? "None";
            body = "Screen time: $t • Steps: $s • Top: $a";
          } else {
            // Fallback Compute
            try {
              final stats = await metricService.fetchYesterdayStats();
              body = await InsightService().generateInsight(stats);
            } catch (e) {
              debugPrint("Error generating insight fallback: $e");
            }
          }

          debugPrint("[BackgroundService] Triggering Morning Notification!");
          await _triggerMorningNotification(body);

          // Mark Done (Unified Flag)
          await prefs.setBool('morning_notification_sent_today', true);

          // Stop Service (Mission Accomplished for this morning)
          if (service is AndroidServiceInstance) {
            service.stopSelf();
          }
        }
      }
    });
  } catch (e) {
    debugPrint("Screen Stream Error: $e");
  }

  // Listen to direct invoke if any
  service.on('stopService').listen((event) {
    _screenSubscription?.cancel();
    service.stopSelf();
  });

  // Listen to direct invoke if any
  service.on('stopService').listen((event) {
    service.stopSelf();
  });

  // Toggle Notification Visibility
  if (service is AndroidServiceInstance) {
    service.on('setAsForeground').listen((event) {
      service.setAsForegroundService();
    });
    service.on('setAsBackground').listen((event) {
      service.setAsBackgroundService();
    });
  }
}

// This method is called when we detect a CHANGE in unlock count via polling
Future<void> _handleUnlockDetected(
  SharedPreferences prefs,
  MetricService metricService,
  int currentUnlocksRaw,
) async {
  final now = DateTime.now();
  final today = now.day;
  final lastDayNotified = prefs.getInt('last_day') ?? -1;

  print("[BackgroundService] Unlock Detected. Count: $currentUnlocksRaw");

  // Reset unlock count at midnight logic
  final lastUnlockDay = prefs.getInt('last_unlock_day') ?? -1;

  if (lastUnlockDay != today && lastUnlockDay != -1) {
    int yesterdayTotal = currentUnlocksRaw > 0 ? currentUnlocksRaw - 1 : 0;
    await prefs.setInt('yesterday_unlock_count', yesterdayTotal);
    await prefs.setInt('daily_unlock_count', 1);
    await prefs.setInt('last_unlock_day', today);
    print(
      "[BackgroundService] Day Changed. Yesterday: $yesterdayTotal. Reset Today to 1.",
    );
  } else if (lastUnlockDay == -1) {
    await prefs.setInt('last_unlock_day', today);
  }

  // Check if we should notify (Morning Window)
  // Request: Trigger after first unlock between Start and End time (Configurable)
  int startHour = prefs.getInt('notification_start_hour') ?? 4;
  int startMinute = prefs.getInt('notification_start_minute') ?? 0;

  int endHour = prefs.getInt('notification_end_hour') ?? 11;
  int endMinute = prefs.getInt('notification_end_minute') ?? 0;

  // Convert to "Minutes from Midnight" for easier comparison
  int nowMinutes = now.hour * 60 + now.minute;
  int startTotalMinutes = startHour * 60 + startMinute;
  int endTotalMinutes = endHour * 60 + endMinute;

  bool isTimeWindow =
      (nowMinutes >= startTotalMinutes && nowMinutes < endTotalMinutes);

  // Debug Override: Notify Every Unlock
  bool debugEveryUnlock =
      kDebugMode && (prefs.getBool('debug_notify_every_unlock') ?? false);

  if (debugEveryUnlock) {
    print(
      "[BackgroundService] Debug Mode: Notifying because 'notify_every_unlock' is TRUE.",
    );
    // Skip logic checking 'lastDayNotified'
    String insightBody = 'Tap to reflect on your yesterday.';
    try {
      final stats = await metricService.fetchYesterdayStats();
      insightBody = await InsightService().generateInsight(stats);
    } catch (e) {
      print("[BackgroundService] Error generating insight: $e");
    }
    await _triggerMorningNotification(insightBody);
  } else if (kDebugMode || isTimeWindow) {
    // Notify only if we haven't notified today yet
    if (today != lastDayNotified) {
      print(
        "[BackgroundService] First unlock ($today). TimeWindow: $isTimeWindow. Calculating Insight...",
      );

      // Calculate Insight
      String insightBody = 'Tap to reflect on your yesterday.';
      try {
        final stats = await metricService.fetchYesterdayStats();
        insightBody = await InsightService().generateInsight(stats);
      } catch (e) {
        print("[BackgroundService] Error generating insight: $e");
      }

      await _triggerMorningNotification(insightBody);
      await prefs.setInt('last_day', today);
    } else {
      print(
        "[BackgroundService] Already notified for today ($today). Skipping.",
      );
    }
  }
}

Future<void> _triggerMorningNotification(String insightBody) async {
  final flutterLocalNotificationsPlugin = FlutterLocalNotificationsPlugin();

  // Use a NEW Channel ID to force update Android settings (remove "Silent" status)
  const AndroidNotificationDetails androidPlatformChannelSpecifics =
      AndroidNotificationDetails(
        'morning_mirror_alert_v2', // CHANGED: v2 to force high importance
        'Morning Recap',
        channelDescription: 'Daily recap notification',
        importance: Importance.max,
        priority: Priority.high,
        showWhen: true,
        icon: '@drawable/ic_stat_morning',
        styleInformation: BigTextStyleInformation(''),
        autoCancel: true,
        visibility: NotificationVisibility.public, // Show on lock screen
        category: AndroidNotificationCategory.recommendation,
      );

  const NotificationDetails platformChannelSpecifics = NotificationDetails(
    android: androidPlatformChannelSpecifics,
  );

  // Use a CONSTANT ID so we can cancel it reliably from DashboardScreen
  const int notifId = 889;

  // Use the passed insight body directly
  final String body = insightBody;

  await flutterLocalNotificationsPlugin.show(
    notifId,
    'Yesterday\'s Mirror',
    body,
    platformChannelSpecifics,
    payload: 'SHOW_STATS',
  );
}
