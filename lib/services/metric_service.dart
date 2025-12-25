import 'dart:async';
import 'package:flutter/services.dart';
import 'package:health/health.dart';
import 'package:flutter/foundation.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:permission_handler/permission_handler.dart';
import 'package:usage_stats/usage_stats.dart';

import 'history_service.dart';
import 'step_service.dart';

class MetricService {
  final Health _health = Health();
  final HistoryService _historyService = HistoryService();
  final List<HealthDataType> _types = [HealthDataType.STEPS];

  // Direct Method Channel to bypass fragile wrapper classes
  static const MethodChannel _channel = MethodChannel('usage_stats');

  // Android UsageEvents constants
  static const int _MOVE_TO_FOREGROUND = 1;
  static const int _MOVE_TO_BACKGROUND = 2;

  // DEBUG: Set this to 'CATEGORY', 'APP', 'UNLOCKS', 'STEPS', 'FALLBACK', or null (for real data)
  static const String? TEST_SCENARIO = null;

  Future<Map<String, dynamic>> fetchYesterdayStats() async {
    // 1. Check for UI-injected Mock Data (Persistent across isolates)
    final prefs = await SharedPreferences.getInstance();
    if (prefs.getBool('debug_mock_enabled') == true) {
      return _getUiMockStats(prefs);
    }

    if (TEST_SCENARIO != null) return _getMockStats();
    try {
      final now = DateTime.now();
      // Yesterday 00:00:00 to 23:59:59
      final startOfYesterday = DateTime(now.year, now.month, now.day - 1, 0, 0);
      final endOfYesterday = DateTime(
        now.year,
        now.month,
        now.day - 1,
        23,
        59,
        59,
      );

      debugPrint("--- Yesterday Event Stats Inquiry ($startOfYesterday) ---");

      final stats = await _calculateUsageFromEvents(
        startOfYesterday,
        endOfYesterday,
      );

      // Calculate total steps for yesterday
      int? steps = await _fetchStepsSafely(startOfYesterday, endOfYesterday);

      // Get unlock count (Now calculated directly from UsageStats history!)
      final prefs = await SharedPreferences.getInstance();
      // int yesterdayUnlocks = prefs.getInt('yesterday_unlock_count') ?? 0;
      int yesterdayUnlocks = stats['calculatedUnlocks'] ?? 0;

      final finalStats = {
        'topApps': stats['topApps'],
        'totalScreenTime': stats['totalScreenTime'],
        'longestSession': stats['longestSession'] ?? 0, // Pass it through
        'steps': steps ?? 0,
        'unlocks': yesterdayUnlocks,
        'date': startOfYesterday,
      };

      // --- STREAK LOGIC ---
      int dailyGoalMs = 4 * 60 * 60 * 1000; // 4 Hours Goal
      int currentStreak = prefs.getInt('streak_count') ?? 0;
      int lastStreakEpoch = prefs.getInt('last_streak_date') ?? 0;

      // Check if we hit the goal yesterday
      if ((stats['totalScreenTime'] ?? 0) < dailyGoalMs) {
        // Success!
        DateTime lastDate = DateTime.fromMillisecondsSinceEpoch(
          lastStreakEpoch,
        );
        DateTime yesterday = startOfYesterday;

        // If last streak was day before yesterday (sequential), increment
        // Or if first time (0), set to 1.
        // Or if last streak was yesterday (already calculated), keep same (idempotent)

        bool isConsecutive = false;
        if (lastStreakEpoch == 0) {
          isConsecutive = true;
        } else {
          final diff = yesterday.difference(lastDate).inDays;
          if (diff == 1) isConsecutive = true;
          if (diff == 0) isConsecutive = false; // Already counted
        }

        if (isConsecutive) {
          currentStreak++;
          await prefs.setInt('streak_count', currentStreak);
          await prefs.setInt(
            'last_streak_date',
            yesterday.millisecondsSinceEpoch,
          );
          debugPrint("Streak Incremented! New Streak: $currentStreak");
        }
      } else {
        // Failed Goal
        // Only reset if we missed YESTERDAY.
        // If we haven't calculated yesterday yet, and yesterday was bad, reset.
        // Logic: If lastStreakDate < DayBeforeYesterday, we broke the chain.
        // Actually, simpler: If we are calculating Yesterday and it failed, Streak is 0.
        // UNLESS we already processed yesterday? No this function fetches fresh.
        // Wait, if user opens app 5 times today, we don't want to reset 5 times.
        // We only reset if 'last_streak_date' is surprisingly old.

        // Safe Simple Logic:
        // If yesterday > lastStreakDate + 1 day -> Reset.
        // But here we know we are calculating "yesterday".
        // So if usage > goal, the streak is broken for "yesterday".
        // But maybe we "froze" the streak?
        // Let's be strict: Usage > 4h = 0 Streak.

        // Only reset if the last successful streak wasn't TODAY (impossible) or YESTERDAY.
        // If we failed yesterday, we reset.

        // Idempotency Check: if we already marked yesterday as failed (how?), we don't need to do anything.
        // We can't really "mark failed".

        // Let's just say: Final Streak = (Success ? Old+1 : 0).
        // BUT we must only update if we haven't updated for yesterday yet.

        // Check if we already processed yesterday
        bool alreadyProcessed = false;
        if (lastStreakEpoch != 0) {
          final diff = startOfYesterday
              .difference(DateTime.fromMillisecondsSinceEpoch(lastStreakEpoch))
              .inDays;
          if (diff == 0) alreadyProcessed = true;
        }

        if (!alreadyProcessed) {
          currentStreak = 0;
          await prefs.setInt('streak_count', 0);
          // Don't update date, so we know it's stale? Or update date to mark failure?
          // Better to just set 0.
        }
      }

      finalStats['streak'] = currentStreak; // Pass to UI

      // Save to history
      _historyService.saveDailyStat(finalStats);

      return finalStats;
    } catch (e, stack) {
      debugPrint("CRITICAL ERROR in fetchYesterdayStats: $e\n$stack");
      return generateEmptyStats(
        DateTime.now().subtract(const Duration(days: 1)),
      );
    }
  }

  // OPTIMIZED: Fetch ONLY unlock count for lightweight polling
  Future<int> getTodayUnlockCount() async {
    try {
      final now = DateTime.now();
      final start = DateTime(now.year, now.month, now.day, 0, 0);

      // Query events efficiently
      List<EventUsageInfo> events = await UsageStats.queryEvents(start, now);

      int count = 0;
      const int _KEYGUARD_HIDDEN = 18;

      for (var e in events) {
        if (int.parse(e.eventType!) == _KEYGUARD_HIDDEN) {
          count++;
        }
      }
      return count;
    } catch (e) {
      debugPrint("Error in getTodayUnlockCount: $e");
      return -1; // Error signal
    }
  }

  Future<Map<String, dynamic>> fetchTodayStats() async {
    try {
      final now = DateTime.now();
      // Today 00:00:00 to NOW
      final startOfToday = DateTime(now.year, now.month, now.day, 0, 0);
      final endOfToday = now;

      debugPrint("--- Today Event Stats Inquiry ($startOfToday) ---");

      final stats = await _calculateUsageFromEvents(startOfToday, endOfToday);

      int? steps = await _fetchStepsSafely(startOfToday, endOfToday);

      final prefs = await SharedPreferences.getInstance();
      await prefs
          .reload(); // Force reload from disk to get updates from Native/BackgroundService
      // 'daily_unlock_count' is typically updated by BackgroundService for the current day
      // But now we calculate it dynamically from UsageStats
      // int todayUnlocks = prefs.getInt('daily_unlock_count') ?? 0;
      int todayUnlocks = stats['calculatedUnlocks'] ?? 0;

      return {
        'topApps': stats['topApps'],
        'totalScreenTime': stats['totalScreenTime'],
        'steps': steps ?? 0,
        'unlocks': todayUnlocks,
        'date': startOfToday,
      };
    } catch (e, stack) {
      debugPrint("CRITICAL ERROR in fetchTodayStats: $e\n$stack");
      return generateEmptyStats(DateTime.now());
    }
  }

  /// Calculates usage strictly within [start] and [end].
  /// To ensure we don't miss sessions starting before [start], we query
  /// events from an earlier point, then CLIP the result to [start].
  Future<Map<String, dynamic>> _calculateUsageFromEvents(
    DateTime start,
    DateTime end,
  ) async {
    // REVERT: Query strictly the requested window to avoid TransactionTooLargeException (1MB limit)
    // The 24h buffer was likely causing 'line 653' codec crashes due to payload size.
    final int startMs = start.millisecondsSinceEpoch;
    final int endMs = end.millisecondsSinceEpoch;

    // We fetch events in batches (e.g. 2 hours) to avoid TransactionTooLargeException (1MB limit)
    // trying to pass a huge list of events from Native to Dart.
    List<dynamic> events = [];

    // Chunk size: 2 hours
    const int chunkMillis = 2 * 60 * 60 * 1000;

    for (
      int currentStart = startMs;
      currentStart < endMs;
      currentStart += chunkMillis
    ) {
      int currentEnd = currentStart + chunkMillis;
      if (currentEnd > endMs) currentEnd = endMs;

      try {
        final List<dynamic> batch =
            await _channel.invokeMethod('queryEvents', {
              'start': currentStart,
              'end': currentEnd,
            }) ??
            [];
        events.addAll(batch);
      } catch (e) {
        debugPrint("Error fetching batch ($currentStart - $currentEnd): $e");
      }
    }

    // Maps packageName -> total duration in ms
    Map<String, int> appUsage = {};
    // Maps packageName -> timestamp of last RESUME
    Map<String, int> lastResumeTime = {};
    // NEW: Count Opens and Notifications
    Map<String, int> appOpens = {};
    Map<String, int> notificationCounts = {};

    // Track acts of closure to preventing double-counting orphans
    // If we process a BG event (orphan or paired), we consider the session CLOSED.
    // If we see another BG event without an intervening FG, we MUST ignore it.
    Set<String> hasClosedSession = {};

    int windowStartMs = start.millisecondsSinceEpoch;
    int windowEndMs = end.millisecondsSinceEpoch;

    // Constant for Notification
    const int eventNotificationInterruption = 12;
    const int eventScreenNonInteractive = 16; // Screen Off

    // NEW: Count Keyguard Hidden (Unlocks) events
    int calculatedUnlocks = 0;
    const int _KEYGUARD_HIDDEN = 18;
    int longestSession = 0;

    for (var eventObj in events) {
      dynamic event = eventObj;
      if (event == null) continue;

      String? pkg;
      String? eventTypeStr;
      String? timeStampStr;

      if (event is Map) {
        pkg = event['packageName'];
        eventTypeStr = event['eventType']?.toString();
        timeStampStr = event['timeStamp']?.toString();
      } else {
        try {
          dynamic d = eventObj;
          pkg = d.packageName;
          eventTypeStr = d.eventType?.toString();
          timeStampStr = d.timeStamp?.toString();
        } catch (_) {
          continue;
        }
      }

      int? eventType = int.tryParse(eventTypeStr ?? '');
      int? timeStamp = int.tryParse(timeStampStr ?? '');

      if (eventType == null || timeStamp == null)
        continue; // Pkg can be null for system events

      // COUNT UNLOCKS (Event 18)
      if (eventType == _KEYGUARD_HIDDEN) {
        if (timeStamp >= windowStartMs && timeStamp <= windowEndMs) {
          calculatedUnlocks++;
        }
      }

      if (pkg == null) continue; // Below logic requires package name

      if (eventType == _MOVE_TO_FOREGROUND) {
        lastResumeTime[pkg] = timeStamp;
        hasClosedSession.remove(
          pkg,
        ); // New session started, so it's not "just closed"

        // Count Open strictly within window
        if (timeStamp >= windowStartMs && timeStamp <= windowEndMs) {
          appOpens[pkg] = (appOpens[pkg] ?? 0) + 1;
        }
      } else if (eventType == _MOVE_TO_BACKGROUND) {
        // If we already closed a session for this app (and haven't reopened), ignore this BG
        // This prevents the "120h bug" where multiple BG events accumulated duration from 00:00
        if (hasClosedSession.contains(pkg)) {
          continue;
        }

        int startTime = lastResumeTime.remove(pkg) ?? -1;

        if (startTime != -1) {
          // Normal Paired Session
          // Clip to window
          int effectiveStart = startTime < windowStartMs
              ? windowStartMs
              : startTime;
          int effectiveEnd = timeStamp > windowEndMs ? windowEndMs : timeStamp;

          if (effectiveEnd > effectiveStart) {
            int duration = effectiveEnd - effectiveStart;
            appUsage[pkg] = (appUsage[pkg] ?? 0) + duration;
            if (duration > longestSession) longestSession = duration;
          }
        } else {
          // ORPHAN (No Start Time known) -> Implies open since Window Start
          // Calculate duration from startMs
          int duration = timeStamp - windowStartMs;
          if (duration > 0) {
            appUsage[pkg] = (appUsage[pkg] ?? 0) + duration;
            if (duration > longestSession) longestSession = duration;
          }
        }

        // Mark as closed to block subsequent duplicate BG events
        hasClosedSession.add(pkg);
      } else if (eventType == eventScreenNonInteractive) {
        // SCREEN OFF: Close ALL currently open sessions
        // We iterate through a copy of keys to avoid concurrent modification issues (though removing safe here)
        final openPackages = lastResumeTime.keys.toList();

        for (var p in openPackages) {
          int startTime = lastResumeTime.remove(p) ?? -1;
          if (startTime != -1) {
            // Treat as "End of Session" at Screen Off time
            // Clip to window
            int effectiveStart = startTime < windowStartMs
                ? windowStartMs
                : startTime;
            int effectiveEnd = timeStamp > windowEndMs
                ? windowEndMs
                : timeStamp;

            if (effectiveEnd > effectiveStart) {
              int duration = effectiveEnd - effectiveStart;
              appUsage[p] = (appUsage[p] ?? 0) + duration;
              if (duration > longestSession) longestSession = duration;
            }
            // Mark as closed so subsequent BG event (if any) is ignored
            hasClosedSession.add(p);
          }
        }
      } else if (eventType == eventNotificationInterruption) {
        if (timeStamp >= windowStartMs && timeStamp <= windowEndMs) {
          notificationCounts[pkg] = (notificationCounts[pkg] ?? 0) + 1;
        }
      }
    }

    // Edge Case: Handling apps still open at the end (FG without BG)
    lastResumeTime.forEach((pkg, startTime) {
      int effectiveStart = startTime < windowStartMs
          ? windowStartMs
          : startTime;
      int effectiveEnd = windowEndMs;

      if (effectiveEnd > effectiveStart) {
        int duration = effectiveEnd - effectiveStart;
        appUsage[pkg] = (appUsage[pkg] ?? 0) + duration;
        // Don't count edges as "longest session" usually, but technically valid.
        // Let's count it.
        if (duration > longestSession) longestSession = duration;
      }
    });

    // Formatting Output
    List<Map<String, dynamic>> topApps = [];
    int totalScreenTime = 0;

    appUsage.forEach((pkg, duration) {
      if (duration > 0) {
        totalScreenTime += duration;
        topApps.add({
          'packageName': pkg,
          'totalTimeInForeground': duration.toString(),
          'openCount': (appOpens[pkg] ?? 0).toString(),
          'notificationCount': (notificationCounts[pkg] ?? 0).toString(),
        });
      }
    });

    // Sort descending
    topApps.sort((a, b) {
      int timeA = int.parse(a['totalTimeInForeground']);
      int timeB = int.parse(b['totalTimeInForeground']);
      return timeB.compareTo(timeA);
    });

    return {
      'topApps': topApps,
      'totalScreenTime': totalScreenTime,
      'longestSession': longestSession,
      'calculatedUnlocks': calculatedUnlocks, // NEW
    };
  }

  Future<int?> _fetchStepsSafely(DateTime start, DateTime end) async {
    try {
      int healthSteps = 0;
      try {
        await _health.configure();
        bool requested = await _health.requestAuthorization(_types);
        if (requested) {
          healthSteps = await _health.getTotalStepsInInterval(start, end) ?? 0;
        }
      } catch (e) {
        debugPrint("Health package error: $e");
      }

      debugPrint("Health Steps: $healthSteps. Falling back if 0.");

      if (healthSteps > 0) return healthSteps;

      try {
        var status = await Permission.activityRecognition.status;
        if (!status.isGranted) {
          status = await Permission.activityRecognition.request();
        }

        if (status.isGranted) {
          final now = DateTime.now();
          final isToday = start.day == now.day && start.month == now.month;

          int localSteps = 0;
          if (isToday) {
            localSteps = await StepService.getTodaySteps();
          } else {
            localSteps = await StepService.getYesterdaySteps();
          }
          return localSteps;
        } else {
          return 0;
        }
      } catch (e) {
        debugPrint("StepService error: $e");
        return 0;
      }
    } catch (e) {
      debugPrint("Fatal Step Error: $e");
      return 0;
    }
  }

  Map<String, dynamic> generateEmptyStats(DateTime date) {
    return {
      'topApps': [],
      'totalScreenTime': 0,
      'steps': 0,
      'unlocks': 0,
      'date': date,
    };
  }

  // --- UI MOCK DATA (From Long Press) ---
  Map<String, dynamic> _getUiMockStats(SharedPreferences prefs) {
    debugPrint("!!! USING UI MOCK DATA !!!");
    final date = DateTime.now().subtract(const Duration(days: 1));

    int steps = prefs.getInt('debug_mock_steps') ?? 0;
    int unlocks = prefs.getInt('debug_mock_unlocks') ?? 0;
    String appName = prefs.getString('debug_mock_app_name') ?? 'Test App';
    int appMins = prefs.getInt('debug_mock_app_mins') ?? 0;

    int totalMs = appMins * 60 * 1000;

    // Construct a simple top list with one dominant app if duration > 0
    List<Map<String, String>> topApps = [];
    if (totalMs > 0) {
      topApps.add({
        'packageName': appName, // Using name as pkg for simplicity in mock
        'totalTimeInForeground': totalMs.toString(),
      });
    }

    return {
      'topApps': topApps,
      'totalScreenTime': totalMs, // Simplified: Total = Top App
      'steps': steps,
      'unlocks': unlocks,
      'date': date,
    };
  }

  // --- MOCK DATA FOR TESTING (Hardcoded scenarios) ---
  Map<String, dynamic> _getMockStats() {
    debugPrint("!!! USING MOCK DATA FOR SCENARIO: $TEST_SCENARIO !!!");
    final date = DateTime.now().subtract(const Duration(days: 1));

    switch (TEST_SCENARIO) {
      case 'CATEGORY':
        return {
          'topApps': [
            {
              'packageName': 'com.instagram.android',
              'totalTimeInForeground': '${4 * 3600 * 1000}',
            }, // 4 hours
            {
              'packageName': 'com.whatsapp',
              'totalTimeInForeground': '${1 * 3600 * 1000}',
            },
          ],
          'totalScreenTime': 6 * 3600 * 1000,
          'steps': 100,
          'unlocks': 10,
          'date': date,
        };
      case 'APP':
        return {
          'topApps': [
            {
              'packageName': 'com.google.android.youtube',
              'totalTimeInForeground': '${2 * 3600 * 1000}',
            }, // 2 hours
            {
              'packageName': 'com.whatsapp',
              'totalTimeInForeground': '${50 * 60 * 1000}',
            },
          ], // Total time is low enough that 2 hours of YT is > 25% of... wait using 4h total
          'totalScreenTime': 4 * 3600 * 1000,
          'steps': 100,
          'unlocks': 8,
          'date': date,
        };
      case 'UNLOCKS':
        return {
          'topApps': [],
          'totalScreenTime': 60 * 60 * 1000,
          'steps': 200,
          'unlocks': 85, // High unlocks
          'date': date,
        };
      case 'STEPS':
        return {
          'topApps': [],
          'totalScreenTime': 10 * 60 * 1000,
          'steps': 6000, // High steps
          'unlocks': 5,
          'date': date,
        };
      default: // FALLBACK
        return {
          'topApps': [],
          'totalScreenTime': 30 * 60 * 1000,
          'steps': 100,
          'unlocks': 5,
          'date': date,
        };
    }
  }

  // --- Helper: Steps to Distance ---
  static Map<String, String> convertToDistance(int steps) {
    if (steps <= 0) {
      return {'km': '0.00', 'miles': '0.00', 'display': '0 km'};
    }

    // Average stride length ~0.762 meters
    double meters = steps * 0.762;
    double km = meters / 1000;
    double miles = km * 0.621371;

    return {
      'km': km.toStringAsFixed(2),
      'miles': miles.toStringAsFixed(2),
      'display': '${km.toStringAsFixed(1)} km', // Short display
    };
  }
}
