import 'package:morning_mirror/services/local_device_apps.dart';

class InsightService {
  Future<String> generateInsight(
    Map<String, dynamic>? stats, {
    bool isToday = false,
    Map<String, dynamic>? comparisonStats,
  }) async {
    final String dayLabel = isToday ? "today" : "yesterday";

    if (stats == null) {
      return "Welcome to your reflection journey.";
    }

    final int totalMs = stats['totalScreenTime'] ?? 0;
    final int steps = stats['steps'] ?? 0;
    final int unlocks = stats['unlocks'] ?? 0;
    final int longestSession = stats['longestSession'] ?? 0;
    final List<dynamic> apps = stats['topApps'] ?? [];

    if (totalMs == 0 && steps == 0 && unlocks == 0) {
      return "No activity recorded $dayLabel.";
    }

    // --- 0. Comparative Analysis (New) ---
    if (comparisonStats != null) {
      final int prevMs = comparisonStats['totalScreenTime'] ?? 0;
      final int prevUnlocks = comparisonStats['unlocks'] ?? 0;
      final int prevSteps = comparisonStats['steps'] ?? 0;

      // Only compare if previous data exists and is significant
      if (prevMs > 600000) {
        // > 10 mins usage yesterday
        double pctChange = 0;
        if (totalMs > prevMs) {
          pctChange = ((totalMs - prevMs) / prevMs);
          if (pctChange > 0.50) {
            // 50% increase
            return "Screen time Spike: Usage is up ${(pctChange * 100).toStringAsFixed(0)}% compared to yesterday. Time to unplug?";
          }
        } else {
          pctChange = ((prevMs - totalMs) / prevMs);
          if (pctChange > 0.30) {
            // 30% decrease
            return "Productivity Boost: Screen time is down ${(pctChange * 100).toStringAsFixed(0)}% compared to yesterday!";
          }
        }
      }

      // Step Comparison (Motivation)
      if (prevSteps > 1000 && steps > (prevSteps + 2000)) {
        return "On the Move: You've walked 2,000 more steps than yesterday! Keeping active helps digital detachment.";
      }

      // Unlock Comparison
      if (prevUnlocks > 20) {
        if (unlocks > (prevUnlocks * 1.5)) {
          return "High Distraction: You've unlocked your phone significantly more often than yesterday.";
        } else if (unlocks < (prevUnlocks * 0.6) && unlocks > 5) {
          return "Laser Focus: Your unlock count is way down compared to yesterday. Keep it up!";
        }
      }
    }

    // --- 1. Data Prep ---
    Map<String, double> catUsage = {};
    String topAppName = "";
    double topAppDuration = 0;
    double socialDuration = 0;

    for (var app in apps) {
      final pkg = app['packageName'];
      final duration =
          double.tryParse(app['totalTimeInForeground'] ?? '0') ?? 0;

      if (duration > topAppDuration) {
        topAppDuration = duration;
        topAppName = pkg;
      }

      if (pkg != null) {
        try {
          // Note: Background service might not be able to fetch labels easily.
          // We'll try our best or use package name.
          Application? info = await LocalDeviceApps.getApp(pkg, true);
          String cat = "Other";
          if (info != null) {
            cat = info.category.toString().split('.').last.replaceAll('_', ' ');
            if (cat.toLowerCase() == 'undefined') cat = "System Apps";
            if (pkg == topAppName) topAppName = info.appName;

            if (cat.toUpperCase().contains("SOCIAL")) {
              socialDuration += duration;
            }
          }
          catUsage[cat] = (catUsage[cat] ?? 0) + duration;
        } catch (e) {
          // Ignore
        }
      }
    }

    // Clean up Top App Name
    if (topAppName.contains('.')) {
      // 1. Try fetching from device (Platform Channel)
      try {
        // Force fresh fetch for the name
        Application? info = await LocalDeviceApps.getApp(topAppName, true);
        if (info != null && info.appName.isNotEmpty) {
          topAppName = info.appName;
        }
      } catch (_) {}

      // 2. If still a package name (contains dot), try Static Map
      if (topAppName.contains('.')) {
        final mappedName = _commonAppNames[topAppName];
        if (mappedName != null) {
          topAppName = mappedName;
        } else {
          // 3. Smart String Cleaning (last resort)
          // e.g. com.google.android.youtube -> YouTube
          // e.g. com.whatsapp -> Whatsapp
          String suffix = topAppName.split('.').last;

          // Common prefixes to ignore if they somehow end up as suffix (unlikely but safe)
          if (suffix.toLowerCase() != "android" && suffix.isNotEmpty) {
            topAppName = suffix[0].toUpperCase() + suffix.substring(1);
          }
        }
      }
    }

    // --- 2. Weighted Heuristic System ---

    // Insight 1: Digital Detox (High Priority)
    // < 1 hour screen time and moderate activity
    if (totalMs > 0 && totalMs < 3600000) {
      return "Digital Detox detected! You spent less than 1 hour on your phone $dayLabel. Great job!";
    }

    // Insight 2: Active Life (High Priority)
    // > 8000 steps and < 3 hours screen time
    if (steps > 8000 && totalMs < 10800000) {
      return "Active Day! You walked $steps steps and kept screen time low. Ideally balanced.";
    }

    // Insight 3: Doomscroll Alert (Medium Priority)
    // Longest Session > 1 hour
    if (longestSession > 3600000) {
      int minutes = (longestSession / 60000).round();
      int hours = minutes ~/ 60;
      int mins = minutes % 60;
      String timeStr = hours > 0 ? "${hours}h ${mins}m" : "${mins}m";
      return "Doomscroll Alert: You spent $timeStr in a single app.";
    }

    // Insight 4: Fragmented Attention (Medium Priority)
    // > 80 unlocks but < 2 hours screen time (Checking habit)
    if (unlocks > 80 && totalMs < 7200000) {
      return "Fragmented Focus: You unlocked your phone $unlocks times, averaging very short sessions. Try to batch your notifications.";
    }

    // Insight 5: Social Binge
    // > 50% time on Social Media
    if (totalMs > 0 && socialDuration > 0) {
      double socialPct = socialDuration / totalMs;
      if (socialPct > 0.5) {
        return "Social Binge: Over 50% of your screen time $dayLabel was spent on Social Media apps.";
      }
    }

    // Insight 6: Category Dominance (General)
    if (totalMs > 0) {
      for (var entry in catUsage.entries) {
        double pct = (entry.value / totalMs);
        if (pct > 0.40 && entry.key != "System Apps" && entry.key != "Other") {
          return "Most of your digital day was spent on ${entry.key} apps.";
        }
      }
    }

    // Insight 7: Top App (General)
    if (totalMs > 0 && topAppDuration > 0) {
      double pct = topAppDuration / totalMs;
      if (pct > 0.25) {
        return "Your most used app $dayLabel took up ${(pct * 100).toStringAsFixed(0)}% of your screen time.";
      }
    }

    // Fallback: Steps or Unlocks
    if (steps > 1000) return "You walked $steps steps $dayLabel.";
    if (unlocks > 0) return "You unlocked your phone $unlocks times $dayLabel.";

    return "Check out your daily summary to see where your time went.";
  }

  // Static Fallback Map for Background Services where MethodChannels might fail
  static final Map<String, String> _commonAppNames = {
    // Social
    'com.instagram.android': 'Instagram',
    'com.facebook.katana': 'Facebook',
    'com.facebook.orca': 'Messenger',
    'com.whatsapp': 'WhatsApp',
    'com.twitter.android': 'X',
    'com.snapchat.android': 'Snapchat',
    'com.zhiliaoapp.musically': 'TikTok',
    'com.linkedin.android': 'LinkedIn',
    'com.pinterest': 'Pinterest',
    'com.reddit.frontpage': 'Reddit',
    'com.discord': 'Discord',
    'org.telegram.messenger': 'Telegram',

    // Google
    'com.google.android.youtube': 'YouTube',
    'com.google.android.gm': 'Gmail',
    'com.google.android.googlequicksearchbox': 'Google',
    'com.android.chrome': 'Chrome',
    'com.google.android.apps.maps': 'Maps',
    'com.google.android.calendar': 'Calendar',
    'com.google.android.apps.photos': 'Photos',
    'com.google.android.keep': 'Keep Notes',
    'com.google.android.apps.docs': 'Drive',

    // Entertainment
    'com.netflix.mediaclient': 'Netflix',
    'com.spotify.music': 'Spotify',
    'com.amazon.avod.thirdpartyclient': 'Prime Video',
    'com.disney.disneyplus': 'Disney+',

    // Shopping / Utils
    'com.amazon.mShop.android.shopping': 'Amazon',
    'com.ebay.mobile': 'eBay',
    'com.ubercab': 'Uber',
    'com.ubercab.eats': 'Uber Eats',
  };
}
