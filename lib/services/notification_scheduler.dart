import 'package:flutter_local_notifications/flutter_local_notifications.dart';
// Note: timezone package is required for scheduled notifications
import 'package:timezone/data/latest_all.dart' as tz;
import 'package:timezone/timezone.dart' as tz;
import 'package:flutter/foundation.dart'; // for debugPrint

class NotificationScheduler {
  static final NotificationScheduler _instance =
      NotificationScheduler._internal();
  factory NotificationScheduler() => _instance;
  NotificationScheduler._internal();

  final FlutterLocalNotificationsPlugin _notifications =
      FlutterLocalNotificationsPlugin();

  Future<void> init() async {
    tz.initializeTimeZones();

    // Config
    const AndroidInitializationSettings androidSettings =
        AndroidInitializationSettings('@drawable/ic_stat_morning');
    const InitializationSettings settings = InitializationSettings(
      android: androidSettings,
    );

    await _notifications.initialize(
      settings,
      onDidReceiveNotificationResponse: (NotificationResponse response) async {
        // Handle tap if needed
      },
    );
  }

  Future<void> scheduleDailyMorningNotification() async {
    // Schedule for 7:00 AM Daily
    // If it's already past 7 AM, schedule for tomorrow.

    try {
      await _notifications.zonedSchedule(
        889, // ID for Morning Recap
        'Yesterday Phone',
        'Tap to see your daily summary.',
        _nextInstanceOf7AM(),
        const NotificationDetails(
          android: AndroidNotificationDetails(
            'morning_mirror_daily',
            'Daily Recap',
            channelDescription: 'Daily notification to check your stats',
            importance: Importance.high,
            priority: Priority.high,
            icon: '@drawable/ic_stat_morning',
          ),
        ),
        androidScheduleMode: AndroidScheduleMode.exactAllowWhileIdle,
        matchDateTimeComponents:
            DateTimeComponents.time, // Recurring daily at time
      );
      debugPrint("Daily Notification Scheduled for 7:00 AM");
    } catch (e) {
      debugPrint("Error scheduling notification: $e");
    }
  }

  tz.TZDateTime _nextInstanceOf7AM() {
    final tz.TZDateTime now = tz.TZDateTime.now(tz.local);
    tz.TZDateTime scheduledDate = tz.TZDateTime(
      tz.local,
      now.year,
      now.month,
      now.day,
      7,
    ); // 7:00 AM

    if (scheduledDate.isBefore(now)) {
      scheduledDate = scheduledDate.add(const Duration(days: 1));
    }
    return scheduledDate;
  }
}
