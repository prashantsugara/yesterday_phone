import 'dart:async';
import 'package:flutter/material.dart';
import 'package:flutter/foundation.dart'; // For kDebugMode
import 'package:google_fonts/google_fonts.dart';
import 'package:google_mobile_ads/google_mobile_ads.dart';
import 'package:flutter_background_service/flutter_background_service.dart';

import 'package:shared_preferences/shared_preferences.dart';
import '../services/metric_service.dart';
import '../services/step_service.dart';
import 'package:morning_mirror/services/config_service.dart';
import 'package:morning_mirror/services/insight_service.dart';
import 'package:morning_mirror/services/local_device_apps.dart';
import 'package:permission_handler/permission_handler.dart';
import 'package:usage_stats/usage_stats.dart';
import 'package:flutter_local_notifications/flutter_local_notifications.dart';
import 'history_screen.dart';
import '../services/morning_worker.dart';

class DashboardScreen extends StatefulWidget {
  const DashboardScreen({super.key});

  @override
  State<DashboardScreen> createState() => _DashboardScreenState();
}

class _DashboardScreenState extends State<DashboardScreen>
    with WidgetsBindingObserver {
  final MetricService _metricService = MetricService();
  Map<String, dynamic>? _stats; // Yesterday
  Map<String, dynamic>? _todayStats; // Today
  bool _isLoading = true;

  // App Data & Categorization
  Map<String, Application> _appInfos = {};
  Map<String, double> _categoryUsage = {};
  Map<String, double> _todayCategoryUsage = {}; // NEW: Today's Categories
  bool _isAppListExpanded = false;

  String _insightText = "Loading insight..."; // Yesterday Insight
  String _todayInsightText = "Loading insight..."; // Today Insight

  // Refactor State
  bool _isTodaySelected = false; // Default to Yesterday

  // State variables for Steps/Unlocks
  int _steps = 0;
  String _distanceText = "0 km";
  int _unlockCount = 0;
  int _streakCount = 0; // Gamification Streak

  final InsightService _insightService = InsightService();

  // Rewarded Ad for History Access
  RewardedAd? _rewardedAd;
  bool _isRewardedAdLoaded = false;
  Timer? _pollingTimer;

  // Realtime Services
  final StepService _stepService = StepService();

  // Permission States
  bool _hasUsagePermission = false;
  bool _hasActivityPermission = false;
  bool _hasNotificationPermission = false;

  final FlutterLocalNotificationsPlugin flutterLocalNotificationsPlugin =
      FlutterLocalNotificationsPlugin();

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    _checkPermissions(); // Check permissions first, will trigger _loadData
    _initNotificationListener(); // Initialize Notification Listener
    _initStepService(); // NEW: Start Pedometer Stream
    _startPolling();
    _loadRewardedAd();

    FlutterBackgroundService().invoke('setAsBackground');

    // Initialize & Schedule Daily Notification (Service-Free)
    _setupNotifications();
  }

  Future<void> _initStepService() async {
    await _stepService.init();
  }

  Future<void> _setupNotifications() async {
    // Register the periodic background check
    await MorningWorker.registerPeriodicTask();
  }

  Future<void> _initNotificationListener() async {
    try {
      // 1. Check if launched from notification
      final NotificationAppLaunchDetails? notificationAppLaunchDetails =
          await flutterLocalNotificationsPlugin
              .getNotificationAppLaunchDetails();

      if (notificationAppLaunchDetails?.didNotificationLaunchApp ?? false) {
        // Cancel the notification that launched us (Recap ID 889)
        await flutterLocalNotificationsPlugin.cancel(889);

        if (notificationAppLaunchDetails?.notificationResponse?.payload ==
            'SHOW_STATS') {
          _switchToYesterday();
        }
      }

      // 2. Listen for stream (if app is running)
      const AndroidInitializationSettings initializationSettingsAndroid =
          AndroidInitializationSettings('@mipmap/ic_launcher');
      const InitializationSettings initializationSettings =
          InitializationSettings(android: initializationSettingsAndroid);

      await flutterLocalNotificationsPlugin.initialize(
        initializationSettings,
        onDidReceiveNotificationResponse: (NotificationResponse response) async {
          if (response.payload == 'SHOW_STATS') {
            // Explicitly cancel the notification (ID 889) to ensure it clears
            await flutterLocalNotificationsPlugin.cancel(889);
            _switchToYesterday();
          }
        },
      );
    } catch (e) {
      debugPrint("Error initializing notification listener: $e");
    }
  }

  void _switchToYesterday() {
    debugPrint("Switching to Yesterday Tab due to Notification");
    if (mounted) {
      setState(() {
        _isTodaySelected = false; // Switch to Yesterday
      });
      _loadData(); // Refresh
    }
  }

  Future<void> _checkPermissions() async {
    bool usage = false;
    // Retry logic for Usage Permission (resolves cold-start false negatives)
    for (int i = 0; i < 3; i++) {
      usage = await UsageStats.checkUsagePermission() ?? false;
      if (usage) break;
      await Future.delayed(const Duration(milliseconds: 500));
    }

    bool activity = await Permission.activityRecognition.isGranted;
    bool notification = await Permission.notification.isGranted;

    if (!notification) {
      // Prompt for notification permission on start (Android 13+)
      final status = await Permission.notification.request();
      notification = status.isGranted;
    }

    if (mounted) {
      setState(() {
        _hasUsagePermission = usage;
        _hasActivityPermission = activity;
        _hasNotificationPermission = notification;
      });
      _loadData(); // Load data NOW that permissions are updated
    }
  }

  void _startPolling() {
    _pollingTimer = Timer.periodic(const Duration(seconds: 2), (timer) {
      _pollRealtimeData();
    });
  }

  Future<void> _pollRealtimeData() async {
    // FIX: Do not overwrite "Yesterday" data with "Today" live data
    if (!_isTodaySelected) return;

    // Unlocks: Query UsageStats directly (No background service needed)
    final unlocks = await _metricService.getTodayUnlockCount();

    // Steps: Read from Prefs (updated by _stepService stream)
    final prefs = await SharedPreferences.getInstance();
    await prefs.reload();
    final steps = prefs.getInt('step_today_steps') ?? 0;

    // ERROR/FLICKER PROTECTION
    // 1. Ignore Error Signal (-1)
    if (unlocks == -1) return;

    // 2. Ignore Drops (flicker to 0) unless it's midnight reset
    final now = DateTime.now();
    final isMidnightReset = (now.hour == 0 && now.minute < 5);

    if (!isMidnightReset && unlocks < _unlockCount) {
      // Ignore random drops during the day
      return;
    }

    bool shouldUpdate = false;

    if (unlocks != _unlockCount) shouldUpdate = true;
    if (steps != _steps) shouldUpdate = true;

    if (shouldUpdate && mounted) {
      // Calc distance
      final double km = (steps * 0.000762);
      final String distStr = km < 1.0
          ? "${(km * 1000).toStringAsFixed(0)} m"
          : "${km.toStringAsFixed(1)} km";

      // NEW: Regenerate Insight for Today dynamically
      if (_todayStats != null) {
        _todayStats!['unlocks'] = unlocks;
        _todayStats!['steps'] = steps;
        // Note: We don't have realtime screen time/top apps here, keeping them as is.
        final newInsight = await _insightService.generateInsight(
          _todayStats!,
          isToday: true,
          comparisonStats: _stats, // Compare with Yesterday
        );
        _todayInsightText = newInsight;
      }

      setState(() {
        _unlockCount = unlocks;
        _steps = steps;
        _distanceText = distStr;
      });
    }
  }

  void _loadRewardedAd({String? specificId}) {
    bool enableAd = ConfigService().getBool('enable_ads');
    debugPrint("DashboardScreen: enable_ads value is: $enableAd");
    if (!enableAd) {
      debugPrint(
        "DashboardScreen: Ad loading blocked because enable_ads is false",
      );
      return;
    }
    // Dynamic Ad Unit ID
    String adUnitId = specificId ?? ConfigService().getRewardedAdUnitId();
    debugPrint("DashboardScreen: Loading Rewarded Ad with ID: $adUnitId");

    RewardedAd.load(
      adUnitId: adUnitId,
      request: const AdRequest(),
      rewardedAdLoadCallback: RewardedAdLoadCallback(
        onAdLoaded: (ad) {
          debugPrint('$ad loaded.');
          _rewardedAd = ad;
          _isRewardedAdLoaded = true;
          debugPrint("REWARDED AD LOADED SUCCESSFULLY");
        },
        onAdFailedToLoad: (LoadAdError error) {
          debugPrint('RewardedAd failed to load: $error');
          debugPrint('Error Code: ${error.code}');
          debugPrint('Error Message: ${error.message}');
          debugPrint('Error Domain: ${error.domain}');
          debugPrint('Response Info: ${error.responseInfo}');

          // Fallback to Test ID if Error Code 1 (Invalid Request) or 3 (No Fill)
          // and we are NOT already using the test ID.
          if ((error.code == 1 || error.code == 3) &&
              adUnitId != ConfigService.testRewardedId) {
            debugPrint(
              "Ad Load Failed with Code ${error.code}. Retrying with TEST ID...",
            );
            _loadRewardedAd(specificId: ConfigService.testRewardedId);
          }
        },
      ),
    );
  }

  void _showHistoryWithAd() {
    if (_rewardedAd != null && _isRewardedAdLoaded) {
      _rewardedAd!.show(
        onUserEarnedReward: (AdWithoutView ad, RewardItem rewardItem) {
          Navigator.push(
            context,
            MaterialPageRoute(builder: (context) => const HistoryScreen()),
          );
          _loadRewardedAd();
        },
      );
      _rewardedAd = null;
      _isRewardedAdLoaded = false;
    } else {
      Navigator.push(
        context,
        MaterialPageRoute(builder: (context) => const HistoryScreen()),
      );
      _loadRewardedAd();
    }
  }

  Future<void> _loadData() async {
    try {
      final prefs = await SharedPreferences.getInstance();
      await prefs.reload();
      var unlocks = prefs.getInt('daily_unlock_count') ?? 0;
      var steps = prefs.getInt('step_today_steps') ?? 0;

      // Optimistic Permission Check
      // Even if checkUsagePermission returns false (flaky on some devices),
      // we attempt to fetch data. If we get data, we know we have permission.
      bool isPermissionLikelyMissing = !_hasUsagePermission;

      // Double check if we think it's missing
      if (isPermissionLikelyMissing) {
        bool actualStatus = await UsageStats.checkUsagePermission() ?? false;
        if (actualStatus) isPermissionLikelyMissing = false;
      }

      final stats = await _metricService.fetchYesterdayStats().timeout(
        const Duration(seconds: 5),
        onTimeout: () {
          debugPrint("fetchYesterdayStats timed out");
          return _metricService.generateEmptyStats(
            DateTime.now().subtract(const Duration(days: 1)),
          );
        },
      );

      // If we got valid data, we definitely have permission
      if ((stats['totalScreenTime'] ?? 0) > 0 ||
          (stats['topApps'] as List).isNotEmpty) {
        isPermissionLikelyMissing = false;
        if (!_hasUsagePermission) {
          _hasUsagePermission = true; // Auto-correct the flag
        }
      }

      // NOW handle the blocking UI if we still think permission is missing AND we got no data
      if (isPermissionLikelyMissing && (stats['totalScreenTime'] ?? 0) == 0) {
        debugPrint(
          "_loadData: No usage permission & no data. Showing permission prompt.",
        );
        if (mounted) {
          setState(() {
            _stats = _metricService.generateEmptyStats(
              DateTime.now().subtract(const Duration(days: 1)),
            );
            _todayStats = _metricService.generateEmptyStats(DateTime.now());
            _insightText = "Usage access needed to show insights.";
            _isLoading = false;
            _hasUsagePermission = false; // Confirm it's false
          });
        }
        return;
      }

      final todayStats = await _metricService.fetchTodayStats().timeout(
        const Duration(seconds: 5),
        onTimeout: () {
          debugPrint("fetchTodayStats timed out");
          return _metricService.generateEmptyStats(DateTime.now());
        },
      );

      // --- LAZY RESET LOGIC ---
      final now = DateTime.now();
      final todayDate =
          "${now.year}-${now.month.toString().padLeft(2, '0')}-${now.day.toString().padLeft(2, '0')}";
      final todayDayInt = now.day;

      // 1. Steps Lazy Reset
      String storedStepDate = prefs.getString('step_last_date') ?? todayDate;
      if (storedStepDate != todayDate) {
        steps = 0; // Stale data, show 0 locally
      }

      // 2. Unlocks Lazy Reset
      int storedUnlockDay = prefs.getInt('last_unlock_day') ?? todayDayInt;
      if (storedUnlockDay != todayDayInt) {
        unlocks = 0; // Stale data, show 0 locally
      }
      // ------------------------

      // Pre-fetch App Info for BOTH lists to minimize lookups
      final yesterdayApps = stats['topApps'] as List<dynamic>? ?? [];
      final todayAppsList = todayStats['topApps'] as List<dynamic>? ?? [];

      // Create superset
      final Set<String> allPkgs = {};
      for (var app in yesterdayApps) allPkgs.add(app['packageName']);
      for (var app in todayAppsList) allPkgs.add(app['packageName']);

      Map<String, Application> infos = {};
      for (var pkg in allPkgs) {
        if (!infos.containsKey(pkg)) {
          try {
            final info = await LocalDeviceApps.getApp(pkg, true);
            if (info != null) infos[pkg] = info;
          } catch (e) {
            debugPrint("Error fetching info for $pkg");
          }
        }
      }

      // Calculate Usage for both
      final yesterdayCatUsage = _calculateCategoryUsage(yesterdayApps, infos);
      final todayCatUsage = _calculateCategoryUsage(todayAppsList, infos);

      String insight = await _insightService.generateInsight(
        stats,
        isToday: false,
      );
      String todayInsight = await _insightService.generateInsight(
        todayStats,
        isToday: true,
        comparisonStats: stats, // Compare with Yesterday
      );

      // Calculate Distance
      final double km = (steps * 0.000762);
      final String distStr = km < 1.0
          ? "${(km * 1000).toStringAsFixed(0)} m"
          : "${km.toStringAsFixed(1)} km";

      if (mounted) {
        setState(() {
          _steps = steps;
          _distanceText = distStr;
          _unlockCount = unlocks;
          _stats = stats;
          _todayStats = todayStats;
          _appInfos = infos;
          _categoryUsage = yesterdayCatUsage;
          _todayCategoryUsage = todayCatUsage;
          _insightText = insight;
          _todayInsightText = todayInsight;
          _isLoading = false;
        });
      }
    } catch (e) {
      debugPrint("Error loading dashboard data: $e");
      if (mounted) {
        setState(() {
          _isLoading = false;
          _insightText = "Pull to refresh to see your stats.";
        });
      }
    }
  }

  Map<String, double> _calculateCategoryUsage(
    List<dynamic> apps,
    Map<String, Application> infos,
  ) {
    Map<String, double> usage = {};
    double totalMs = 0;

    for (var app in apps) {
      final pkg = app['packageName'];
      final duration =
          double.tryParse(app['totalTimeInForeground'] ?? '0') ?? 0;

      if (infos.containsKey(pkg)) {
        String cat = _getCategoryName(infos[pkg]?.category);
        // Filter System Apps & Launchers
        if (cat == "System Apps") continue;
        if (pkg.toString().toLowerCase().contains("launcher")) continue;

        usage[cat] = (usage[cat] ?? 0) + duration;
        totalMs += duration;
      }
    }
    // Normalize
    if (totalMs > 0) {
      usage.updateAll((key, val) => (val / totalMs) * 100);
    }
    return usage;
  }

  String _getCategoryName(dynamic cat) {
    if (cat == null) return "System Apps"; // Fixed Undefined -> System Apps
    String name = cat.toString().split('.').last.replaceAll('_', ' ');
    if (name.toLowerCase() == "undefined") return "System Apps";
    return name;
  }

  String _formatValue(int val) {
    return "$val"; // Fix flickering: Show 0 instead of --
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    _pollingTimer?.cancel();
    super.dispose();
  }

  @override
  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    // Disable UI-driven service toggling for Morning Mirror logic.
    // The service should only run when explicitly started by WorkManager or Alarm.
    /*
    final service = FlutterBackgroundService();
    if (state == AppLifecycleState.resumed) {
      debugPrint("DashboardScreen: App Resumed - Hiding Service Notification");
      service.invoke('setAsBackground'); // Hide Notification
      _checkPermissions(); // Re-check in case user granted in settings
    } else if (state == AppLifecycleState.paused) {
      debugPrint("DashboardScreen: App Paused - Showing Service Notification");
      service.invoke('setAsForeground'); // Show Notification
    }
    */
    if (state == AppLifecycleState.resumed) {
      _checkPermissions();
    }
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: const Color(0xFF121212),
      body: _isLoading
          ? const Center(child: CircularProgressIndicator(color: Colors.amber))
          : RefreshIndicator(
              onRefresh: _loadData,
              child: CustomScrollView(
                slivers: [
                  SliverAppBar.large(
                    expandedHeight: 200,
                    backgroundColor: const Color(0xFF121212),
                    floating: false,
                    pinned: true,
                    actions: [
                      IconButton(
                        icon: const Icon(Icons.settings, color: Colors.white),
                        onPressed: _showSettingsDialog,
                      ),
                      const SizedBox(width: 8),
                    ],
                    flexibleSpace: FlexibleSpaceBar(
                      titlePadding: const EdgeInsets.only(left: 20, bottom: 20),
                      title: Text(
                        'Yesterday Phone',
                        style: GoogleFonts.outfit(
                          fontWeight: FontWeight.bold,
                          color: Colors.white,
                        ),
                      ),
                      background: Container(
                        decoration: const BoxDecoration(
                          gradient: LinearGradient(
                            begin: Alignment.topCenter,
                            end: Alignment.bottomCenter,
                            colors: [Color(0xFF2C3E50), Color(0xFF121212)],
                          ),
                        ),
                      ),
                    ),
                  ),
                  SliverToBoxAdapter(
                    child: Padding(
                      padding: const EdgeInsets.all(16.0),
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          _buildToggle(), // NEW: Toggle
                          _buildHeroMetric(),
                          _buildInsightCard(), // NEW: Insight
                          const SizedBox(height: 20),
                          _buildHistoryButton(),
                          const SizedBox(height: 20),
                          _buildGridMetrics(),
                          _buildDoomscrollCard(), // NEW
                          const SizedBox(height: 24),

                          // Categories Section Logic Integrated below

                          // Apps Section Header
                          Row(
                            mainAxisAlignment: MainAxisAlignment.spaceBetween,
                            children: [
                              Text(
                                "Most Used Apps",
                                style: GoogleFonts.outfit(
                                  fontSize: 20,
                                  fontWeight: FontWeight.bold,
                                  color: Colors.white70,
                                ),
                              ),
                            ],
                          ),
                          const SizedBox(height: 16),

                          // Category List (Moved Here)
                          if (_categoryUsage.isNotEmpty) ...[
                            _buildCategoryList(),
                            const SizedBox(height: 24),
                          ],

                          _buildAppList(),

                          // Show More Button
                          if ((_stats?['topApps'] as List?)!.length > 5)
                            TextButton(
                              onPressed: () {
                                setState(() {
                                  _isAppListExpanded = !_isAppListExpanded;
                                });
                              },
                              child: Row(
                                mainAxisAlignment: MainAxisAlignment.center,
                                children: [
                                  Text(
                                    _isAppListExpanded
                                        ? "Show Less"
                                        : "Show More",
                                    style: GoogleFonts.outfit(
                                      color: Colors.amber,
                                    ),
                                  ),
                                  Icon(
                                    _isAppListExpanded
                                        ? Icons.keyboard_arrow_up
                                        : Icons.keyboard_arrow_down,
                                    color: Colors.amber,
                                  ),
                                ],
                              ),
                            ),
                        ],
                      ),
                    ),
                  ),
                ],
              ),
            ),
    );
  }

  Widget _buildHistoryButton() {
    return GestureDetector(
      onTap: _showHistoryWithAd,
      child: Container(
        width: double.infinity,
        padding: const EdgeInsets.symmetric(vertical: 16),
        decoration: BoxDecoration(
          color: const Color(0xFF2C3E50),
          borderRadius: BorderRadius.circular(16),
          border: Border.all(color: Colors.white10),
        ),
        child: Row(
          mainAxisAlignment: MainAxisAlignment.center,
          children: [
            const Icon(Icons.history, color: Colors.white70),
            const SizedBox(width: 8),
            Text(
              "View 12-Month History",
              style: GoogleFonts.outfit(
                color: Colors.white,
                fontSize: 16,
                fontWeight: FontWeight.w600,
              ),
            ),
            const SizedBox(width: 8),
            Container(
              padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
              decoration: BoxDecoration(
                color: Colors.amber,
                borderRadius: BorderRadius.circular(8),
              ),
              child: Text(
                "AD",
                style: GoogleFonts.outfit(
                  color: Colors.black,
                  fontSize: 10,
                  fontWeight: FontWeight.bold,
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }

  Widget _buildToggle() {
    return Container(
      margin: const EdgeInsets.only(bottom: 16),
      width: double.infinity,
      child: SegmentedButton<bool>(
        segments: const [
          ButtonSegment(
            value: false,
            label: Text("Yesterday"),
            icon: Icon(Icons.history),
          ),
          ButtonSegment(
            value: true,
            label: Text("Today"),
            icon: Icon(Icons.today),
          ),
        ],
        selected: {_isTodaySelected},
        onSelectionChanged: (Set<bool> newSelection) {
          setState(() {
            _isTodaySelected = newSelection.first;
            // Re-calc specific data if needed, but setState handles rebuild
          });
        },
        style: ButtonStyle(
          visualDensity: VisualDensity.compact,
          tapTargetSize: MaterialTapTargetSize.shrinkWrap,
          backgroundColor: MaterialStateProperty.resolveWith<Color>((states) {
            if (states.contains(MaterialState.selected)) {
              return Colors.amber;
            }
            return Colors.grey[900]!;
          }),
          foregroundColor: MaterialStateProperty.resolveWith<Color>((states) {
            if (states.contains(MaterialState.selected)) {
              return Colors.black;
            }
            return Colors.white70;
          }),
        ),
      ),
    );
  }

  Widget _buildInsightCard() {
    return GestureDetector(
      onTap: !_hasNotificationPermission
          ? () async {
              // Open settings if request doesn't pop up (permanently denied)
              PermissionStatus status = await Permission.notification.request();
              if (status.isPermanentlyDenied) {
                await openAppSettings();
              }
              _checkPermissions();
            }
          : null,
      child: Container(
        margin: const EdgeInsets.only(top: 12),
        padding: const EdgeInsets.all(16),
        width: double.infinity,
        decoration: BoxDecoration(
          color: const Color(0xFF1E1E1E),
          borderRadius: BorderRadius.circular(16),
          border: Border.all(
            color: !_hasNotificationPermission
                ? Colors.redAccent
                : Colors.white10,
          ),
        ),
        child: Row(
          children: [
            Icon(
              !_hasNotificationPermission
                  ? Icons.notifications_off
                  : Icons.lightbulb_outline,
              color: !_hasNotificationPermission
                  ? Colors.redAccent
                  : Colors.amber,
              size: 20,
            ),
            const SizedBox(width: 12),
            Expanded(
              child: Text(
                !_hasNotificationPermission
                    ? "Notifications are disabled. Tap here to enable in Settings." // Explicit CTA
                    : (_isTodaySelected ? _todayInsightText : _insightText),
                style: GoogleFonts.outfit(
                  color: !_hasNotificationPermission
                      ? Colors.redAccent
                      : Colors.white.withOpacity(0.9),
                  fontSize: 14,
                  fontStyle: FontStyle.italic,
                  fontWeight: !_hasNotificationPermission
                      ? FontWeight.bold
                      : FontWeight.normal,
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }

  Widget _buildHeroMetric() {
    // Check Permission First
    if (!_hasUsagePermission) {
      return GestureDetector(
        onTap: _showUsagePermissionTutorial,
        child: Container(
          width: double.infinity,
          padding: const EdgeInsets.symmetric(vertical: 32, horizontal: 24),
          decoration: BoxDecoration(
            gradient: const LinearGradient(
              colors: [Color(0xFFFDC830), Color(0xFFF37335)],
              begin: Alignment.topLeft,
              end: Alignment.bottomRight,
            ),
            borderRadius: BorderRadius.circular(24),
          ),
          child: Column(
            children: [
              const Icon(Icons.lock_clock, size: 48, color: Colors.white),
              const SizedBox(height: 16),
              Text(
                "Usage Permission Needed",
                style: GoogleFonts.outfit(
                  color: Colors.white,
                  fontSize: 20,
                  fontWeight: FontWeight.bold,
                ),
              ),
              const SizedBox(height: 8),
              Text(
                "Tap here to grant access so we can show your Screen Time.",
                textAlign: TextAlign.center,
                style: GoogleFonts.outfit(color: Colors.white70, fontSize: 14),
              ),
            ],
          ),
        ),
      );
    }

    final Map<String, dynamic>? currentStats = _isTodaySelected
        ? _todayStats
        : _stats;
    int totalMs = currentStats?['totalScreenTime'] ?? 0;
    String timeStr = _formatDuration(totalMs);
    String label = _isTodaySelected
        ? "Today's Screen Time"
        : "Yesterday's Screen Time";

    // Debug: Long press to mock data
    return GestureDetector(
      onLongPress: kDebugMode ? _showDebugMockDialog : null,
      child: Container(
        width: double.infinity,
        decoration: BoxDecoration(
          gradient: const LinearGradient(
            colors: [Color(0xFFFDC830), Color(0xFFF37335)],
            begin: Alignment.topLeft,
            end: Alignment.bottomRight,
          ),
          borderRadius: BorderRadius.circular(24),
          boxShadow: [
            BoxShadow(
              color: const Color(0xFFF37335).withOpacity(0.4),
              blurRadius: 20,
              offset: const Offset(0, 10),
            ),
          ],
        ),
        child: Stack(
          children: [
            Padding(
              padding: const EdgeInsets.all(24),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    label,
                    style: GoogleFonts.outfit(
                      color: Colors.white.withOpacity(0.9),
                      fontSize: 16,
                      fontWeight: FontWeight.w500,
                    ),
                  ),
                  const SizedBox(height: 8),
                  Text(
                    timeStr,
                    style: GoogleFonts.outfit(
                      color: Colors.white,
                      fontSize: 48,
                      fontWeight: FontWeight.bold,
                    ),
                  ),
                  if (_streakCount > 0) ...[
                    const SizedBox(height: 8),
                    Container(
                      padding: const EdgeInsets.symmetric(
                        horizontal: 10,
                        vertical: 4,
                      ),
                      decoration: BoxDecoration(
                        color: Colors.white.withOpacity(0.2),
                        borderRadius: BorderRadius.circular(12),
                      ),
                      child: Row(
                        mainAxisSize: MainAxisSize.min,
                        children: [
                          const Text("🔥", style: TextStyle(fontSize: 14)),
                          const SizedBox(width: 6),
                          Text(
                            "$_streakCount Day Streak!",
                            style: GoogleFonts.outfit(
                              color: Colors.white,
                              fontSize: 14,
                              fontWeight: FontWeight.w600,
                            ),
                          ),
                        ],
                      ),
                    ),
                  ],
                ],
              ),
            ),
            Positioned(
              top: 16,
              right: 16,
              child: IconButton(
                icon: const Icon(
                  Icons.help_outline,
                  color: Colors.white30,
                  size: 20,
                ),
                onPressed: () => _showExplanationDialog(
                  label,
                  "This shows the total time the screen was active/unlocked.\n\nCompare Yesterday vs Today to see your progress!",
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }

  void _showUsagePermissionTutorial() {
    showDialog(
      context: context,
      builder: (context) {
        return AlertDialog(
          backgroundColor: const Color(0xFF1E1E1E),
          shape: RoundedRectangleBorder(
            borderRadius: BorderRadius.circular(20),
            side: BorderSide(color: Colors.white.withOpacity(0.1)),
          ),
          title: Text(
            "Enable Usage Access",
            style: GoogleFonts.outfit(
              color: Colors.white,
              fontWeight: FontWeight.bold,
            ),
          ),
          content: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              // 1. Why we need this
              Text(
                "Why? We need to see which apps you used yesterday to give you your daily reflection.",
                style: GoogleFonts.outfit(
                  color: Colors.white70,
                  fontSize: 14,
                  fontStyle: FontStyle.italic,
                ),
                textAlign: TextAlign.center,
              ),
              const SizedBox(height: 24),

              // 2. Open Settings
              _buildTutorialStep(
                number: "1",
                title: "Go to Settings",
                subtitle: "Tap below to open the 'Usage Access' list.",
                buttonText: "Open Settings",
                onPressed: () async {
                  await UsageStats.grantUsagePermission();
                },
                color: Colors.blueAccent,
              ),
              const SizedBox(height: 16),

              // 3. Restricted Setting Help
              _buildTutorialStep(
                number: "2",
                title: "Greyed out? (Restricted)",
                subtitle:
                    "If switch is disabled: Tap below > 3 dots (top-right) > 'Allow restricted settings'.",
                buttonText: "Open App Info",
                onPressed: () async {
                  await openAppSettings();
                },
                color: Colors.orangeAccent,
              ),
              const SizedBox(height: 16),

              // 4. Toggle ON (with Open Settings button -> 'Again step 2')
              _buildTutorialStep(
                number: "3",
                title: "Turn it ON",
                subtitle: "Find 'Yesterday Phone' and toggle it ON.",
                buttonText: "Open Settings & Toggle",
                onPressed: () async {
                  await UsageStats.grantUsagePermission();
                },
                color: Colors.green,
              ),
              const SizedBox(height: 24),

              // Verify / Done
              SizedBox(
                width: double.infinity,
                child: ElevatedButton(
                  onPressed: () async {
                    bool granted =
                        await UsageStats.checkUsagePermission() ?? false;
                    if (granted) {
                      if (mounted) {
                        Navigator.pop(context);
                        _checkPermissions();
                        _loadData();
                      }
                    } else {
                      if (mounted) {
                        ScaffoldMessenger.of(context).showSnackBar(
                          SnackBar(
                            content: Text(
                              "Permission not active. Please Toggle ON.",
                              style: GoogleFonts.outfit(),
                            ),
                            backgroundColor: Colors.redAccent,
                          ),
                        );
                      }
                    }
                  },
                  style: ElevatedButton.styleFrom(
                    backgroundColor: Colors.white,
                    foregroundColor: Colors.black,
                    padding: const EdgeInsets.symmetric(vertical: 16),
                    shape: RoundedRectangleBorder(
                      borderRadius: BorderRadius.circular(12),
                    ),
                  ),
                  child: Text(
                    "I Tried It / Verify",
                    style: GoogleFonts.outfit(fontWeight: FontWeight.bold),
                  ),
                ),
              ),
            ],
          ),
        );
      },
    );
  }

  Widget _buildTutorialStep({
    required String number,
    required String title,
    required String subtitle,
    String? buttonText,
    VoidCallback? onPressed,
    required Color color,
  }) {
    return Row(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Container(
          width: 32,
          height: 32,
          decoration: BoxDecoration(
            color: color.withOpacity(0.2),
            shape: BoxShape.circle,
            border: Border.all(color: color),
          ),
          child: Center(
            child: Text(
              number,
              style: GoogleFonts.outfit(
                color: color,
                fontWeight: FontWeight.bold,
              ),
            ),
          ),
        ),
        const SizedBox(width: 12),
        Expanded(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(
                title,
                style: GoogleFonts.outfit(
                  color: Colors.white,
                  fontWeight: FontWeight.w600,
                  fontSize: 16,
                ),
              ),
              const SizedBox(height: 4),
              Text(
                subtitle,
                style: GoogleFonts.outfit(color: Colors.white54, fontSize: 13),
              ),
              if (buttonText != null) ...[
                const SizedBox(height: 8),
                SizedBox(
                  height: 36,
                  child: ElevatedButton(
                    onPressed: onPressed,
                    style: ElevatedButton.styleFrom(
                      backgroundColor: color,
                      foregroundColor: Colors.white,
                      shape: RoundedRectangleBorder(
                        borderRadius: BorderRadius.circular(8),
                      ),
                      padding: const EdgeInsets.symmetric(horizontal: 16),
                    ),
                    child: Text(
                      buttonText,
                      style: GoogleFonts.outfit(fontWeight: FontWeight.w600),
                    ),
                  ),
                ),
              ],
            ],
          ),
        ),
      ],
    );
  }

  void _showDebugMockDialog() async {
    final prefs = await SharedPreferences.getInstance();
    final stepsCtrl = TextEditingController(
      text: (prefs.getInt('debug_mock_steps') ?? 5000).toString(),
    );
    final unlocksCtrl = TextEditingController(
      text: (prefs.getInt('debug_mock_unlocks') ?? 50).toString(),
    );
    final appNameCtrl = TextEditingController(
      text: prefs.getString('debug_mock_app_name') ?? 'com.social.app',
    );
    final appMinsCtrl = TextEditingController(
      text: (prefs.getInt('debug_mock_app_mins') ?? 120).toString(),
    );

    // Debug Toggle State
    bool notifyEveryUnlock =
        prefs.getBool('debug_notify_every_unlock') ?? false;

    if (!mounted) return;

    showDialog(
      context: context,
      builder: (context) {
        return StatefulBuilder(
          // Use StatefulBuilder to update switch in dialog
          builder: (context, setState) {
            return AlertDialog(
              title: const Text("Debug Mock Data"),
              content: SingleChildScrollView(
                child: Column(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    SwitchListTile(
                      title: const Text("Notify on EVERY Unlock"),
                      subtitle: const Text("Ignore 4AM rules & 1/day limit"),
                      value: notifyEveryUnlock,
                      onChanged: (val) {
                        setState(() {
                          notifyEveryUnlock = val;
                        });
                      },
                    ),
                    const Divider(),
                    TextField(
                      controller: stepsCtrl,
                      decoration: const InputDecoration(labelText: "Steps"),
                      keyboardType: TextInputType.number,
                    ),
                    TextField(
                      controller: unlocksCtrl,
                      decoration: const InputDecoration(labelText: "Unlocks"),
                      keyboardType: TextInputType.number,
                    ),
                    TextField(
                      controller: appNameCtrl,
                      decoration: const InputDecoration(
                        labelText: "Top App Pkg",
                      ),
                    ),
                    TextField(
                      controller: appMinsCtrl,
                      decoration: const InputDecoration(
                        labelText: "App Duration (mins)",
                      ),
                      keyboardType: TextInputType.number,
                    ),
                  ],
                ),
              ),
              actions: [
                TextButton(
                  onPressed: () async {
                    await prefs.remove('debug_mock_enabled');
                    await prefs.remove(
                      'debug_notify_every_unlock',
                    ); // Clear toggle
                    await _loadData(); // Reload real data
                    Navigator.pop(context);
                  },
                  child: const Text("Clear/Reset"),
                ),
                ElevatedButton(
                  onPressed: () async {
                    await prefs.setBool('debug_mock_enabled', true);
                    await prefs.setBool(
                      'debug_notify_every_unlock',
                      notifyEveryUnlock,
                    ); // SaveToggle
                    await prefs.setInt(
                      'debug_mock_steps',
                      int.parse(stepsCtrl.text),
                    );
                    await prefs.setInt(
                      'debug_mock_unlocks',
                      int.parse(unlocksCtrl.text),
                    );
                    await prefs.setString(
                      'debug_mock_app_name',
                      appNameCtrl.text,
                    );
                    await prefs.setInt(
                      'debug_mock_app_mins',
                      int.parse(appMinsCtrl.text),
                    );

                    await _loadData(); // Reload with mock data
                    Navigator.pop(context);
                  },
                  child: const Text("Save & Apply"),
                ),
              ],
            );
          },
        );
      },
    );
  }

  String _formatDuration(int ms) {
    if (ms == 0) return "0 min";
    final totalMins = (ms / (1000 * 60)).round();
    if (totalMins >= 60) {
      final h = totalMins ~/ 60;
      final m = totalMins % 60;
      return "${h}hr ${m}min";
    }
    return "$totalMins min";
  }

  Widget _buildCategoryList() {
    final Map<String, double> targetUsage = _isTodaySelected
        ? _todayCategoryUsage
        : _categoryUsage;

    // Sort Categories by usage desc
    var sortedEntries =
        targetUsage.entries
            .where((e) => e.key != "Undefined" && e.key != "undefined")
            .toList()
          ..sort((a, b) => b.value.compareTo(a.value));

    // Take top 3 + Other? Or just horizontal scroll. Let's do horizontal scroll list
    return SizedBox(
      height: 110,
      child: ListView.separated(
        scrollDirection: Axis.horizontal,
        itemCount: sortedEntries.length,
        separatorBuilder: (ctx, i) => const SizedBox(width: 12),
        itemBuilder: (context, index) {
          final entry = sortedEntries[index];
          return Container(
            padding: const EdgeInsets.all(12),
            decoration: BoxDecoration(
              color: const Color(0xFF1E1E1E),
              borderRadius: BorderRadius.circular(12),
              border: Border.all(color: Colors.white10),
            ),
            child: Column(
              mainAxisAlignment: MainAxisAlignment.center,
              children: [
                Icon(
                  _getCategoryIcon(entry.key),
                  color: Colors.blueAccent,
                  size: 20,
                ),
                const SizedBox(height: 4),
                Text(
                  entry.key, // Category Name
                  style: GoogleFonts.outfit(
                    color: Colors.white70,
                    fontSize: 12,
                  ),
                ),
                const SizedBox(height: 2),
                Text(
                  "${entry.value.toStringAsFixed(1)}%",
                  style: GoogleFonts.outfit(
                    color: Colors.amber,
                    fontSize: 14,
                    fontWeight: FontWeight.bold,
                  ),
                ),
              ],
            ),
          );
        },
      ),
    );
  }

  Widget _buildGridMetrics() {
    final Map<String, dynamic>? currentStats = _isTodaySelected
        ? _todayStats
        : _stats;

    // Use specific counts if today (handles lazy reset), else stats map
    int unlockVal = _isTodaySelected
        ? _unlockCount
        : (currentStats?['unlocks'] ?? 0);

    int stepVal = _isTodaySelected ? _steps : (currentStats?['steps'] ?? 0);

    return Row(
      children: [
        Expanded(
          child: GestureDetector(
            onTap: !_hasUsagePermission
                ? () {
                    _showUsagePermissionTutorial();
                  }
                : null,
            child: _hasUsagePermission
                ? _buildInfoCard(
                    "Unlocks",
                    _formatValue(unlockVal),
                    Icons.lock_open_rounded,
                    const Color(0xFF00C6FF),
                    helpTitle: "Unlocks",
                    helpDescription:
                        "The total number of times you've unlocked your phone today.\n\nFewer unlocks suggests better focus!",
                  )
                : Container(
                    padding: const EdgeInsets.all(20),
                    decoration: BoxDecoration(
                      color: const Color(0xFF1E1E1E),
                      borderRadius: BorderRadius.circular(20),
                      border: Border.all(color: Colors.white.withOpacity(0.05)),
                    ),
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.center,
                      children: [
                        const Icon(
                          Icons.lock_clock,
                          size: 48,
                          color: Colors.white,
                        ),
                        const SizedBox(height: 16),
                        Text(
                          "Usage Permission Needed", // Clearer Title
                          style: GoogleFonts.outfit(
                            color: Colors.white,
                            fontSize: 20,
                            fontWeight: FontWeight.bold,
                          ),
                          textAlign: TextAlign.center,
                        ),
                        const SizedBox(height: 8),
                        Text(
                          "Tap here to grant access so we can show your Screen Time.", // Clear Instruction
                          textAlign: TextAlign.center,
                          style: GoogleFonts.outfit(
                            color: Colors.white70,
                            fontSize: 14,
                          ),
                        ),
                      ],
                    ),
                  ),
          ),
        ),
        const SizedBox(width: 16),
        Expanded(
          child: GestureDetector(
            onTap: !_hasActivityPermission
                ? () async {
                    PermissionStatus status = await Permission
                        .activityRecognition
                        .request();
                    if (status.isPermanentlyDenied) {
                      await openAppSettings();
                    }
                    _checkPermissions();
                  }
                : null,
            child: _buildInfoCard(
              "Steps",
              !_hasActivityPermission
                  ? "Tap to Grant" // Clearer CTA
                  : _formatValue(stepVal),
              Icons.directions_walk_rounded,
              !_hasActivityPermission ? Colors.orange : const Color(0xFF0072FF),
              subValue: _hasActivityPermission
                  ? (_isTodaySelected
                        ? _distanceText
                        : MetricService.convertToDistance(stepVal)['display'])
                  : null,
              helpTitle: "Steps",
              helpDescription:
                  "Steps taken today provided by your device/pedometer.\n\nStaying active can help reduce screen dependency.",
            ),
          ),
        ),
      ],
    );
  }

  Widget _buildInfoCard(
    String title,
    String value,
    IconData icon,
    Color color, {
    String? subValue, // For Distance
    String? helpTitle,
    String? helpDescription,
  }) {
    return Container(
      decoration: BoxDecoration(
        color: const Color(0xFF1E1E1E),
        borderRadius: BorderRadius.circular(20),
        border: Border.all(color: Colors.white.withOpacity(0.05)),
      ),
      child: Stack(
        children: [
          Padding(
            padding: const EdgeInsets.all(20),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Icon(icon, color: color, size: 28),
                const SizedBox(height: 12),
                Text(
                  value,
                  style: GoogleFonts.outfit(
                    color: Colors.white,
                    fontSize: 24,
                    fontWeight: FontWeight.bold,
                  ),
                ),
                const SizedBox(height: 4),
                Text(
                  title,
                  style: GoogleFonts.outfit(
                    color: Colors.white54,
                    fontSize: 14,
                  ),
                ),
                if (subValue != null) ...[
                  const SizedBox(height: 4),
                  Text(
                    subValue,
                    style: GoogleFonts.outfit(
                      color: Colors.white38,
                      fontSize: 12,
                      fontStyle: FontStyle.italic,
                    ),
                  ),
                ],
              ],
            ),
          ),
          if (helpTitle != null && helpDescription != null)
            Positioned(
              top: 8,
              right: 8,
              child: IconButton(
                icon: const Icon(
                  Icons.help_outline,
                  color: Colors.white30,
                  size: 18,
                ),
                onPressed: () =>
                    _showExplanationDialog(helpTitle, helpDescription),
              ),
            ),
        ],
      ),
    );
  }

  IconData _getCategoryIcon(String category) {
    // Map common categories to icons
    final cat = category.toUpperCase();
    if (cat.contains("GAME")) return Icons.sports_esports;
    if (cat.contains("VIDEO")) return Icons.play_circle_fill;
    if (cat.contains("AUDIO") || cat.contains("MUSIC")) return Icons.music_note;
    if (cat.contains("IMAGE") || cat.contains("PHOTO")) return Icons.image;
    if (cat.contains("SOCIAL")) return Icons.people;
    if (cat.contains("COMMUNICATION")) return Icons.chat;
    if (cat.contains("MAP")) return Icons.map;
    if (cat.contains("PRODUCTIVITY")) return Icons.work;
    if (cat.contains("TOOL")) return Icons.build;
    if (cat.contains("NEWS")) return Icons.newspaper;
    if (cat.contains("SHOP")) return Icons.shopping_bag;
    return Icons.category; // Default
  }

  Widget _buildAppList() {
    final Map<String, dynamic>? currentStats = _isTodaySelected
        ? _todayStats
        : _stats;

    final List<dynamic> apps = currentStats?['topApps'] ?? [];

    if (!_hasUsagePermission) {
      return GestureDetector(
        onTap: _showUsagePermissionTutorial,
        child: Container(
          width: double.infinity,
          padding: const EdgeInsets.all(24),
          decoration: BoxDecoration(
            color: const Color(0xFF1E1E1E),
            borderRadius: BorderRadius.circular(16),
            border: Border.all(color: Colors.white10),
          ),
          child: Column(
            mainAxisAlignment: MainAxisAlignment.center,
            children: [
              const Icon(Icons.lock_clock, size: 32, color: Colors.white54),
              const SizedBox(height: 12),
              Text(
                "App usage details hidden",
                style: GoogleFonts.outfit(
                  color: Colors.white70,
                  fontSize: 16,
                  fontWeight: FontWeight.w600,
                ),
              ),
              const SizedBox(height: 4),
              Text(
                "Tap to Grant Access",
                style: GoogleFonts.outfit(
                  color: Colors.amber,
                  fontSize: 14,
                  fontWeight: FontWeight.bold,
                ),
              ),
            ],
          ),
        ),
      );
    }

    // Filter System Apps & Launchers from the list
    final filteredApps = apps.where((app) {
      final pkg = app['packageName'];
      final appInfo = _appInfos[pkg];
      final bool isSystem = appInfo?.systemApp ?? false;

      // Whitelist popular apps that might be categorized as System/Undefined
      const whitelist = {
        'com.google.android.youtube',
        'com.android.chrome',
        'com.google.android.gm', // Gmail
        'com.google.android.apps.maps',
        'com.google.android.apps.photos',
        'com.google.android.calendar',
        'com.android.camera',
        'com.android.vending', // Play Store
        'com.instagram.android',
        'com.facebook.katana',
        'com.whatsapp',
        'com.twitter.android',
        'com.snapchat.android',
        'com.linkedin.android',
        'com.pinterest',
        'com.reddit.frontpage',
        'com.zhiliaoapp.musically', // TikTok
      };

      if (whitelist.contains(pkg)) return true;

      // Filter logic: Only hide if it's explicitly a system app AND not whitelisted
      if (isSystem) {
        return false;
      }

      // Also filter launchers
      if (pkg.toString().toLowerCase().contains("launcher")) return false;
      return true;
    }).toList();

    if (filteredApps.isEmpty) {
      return Padding(
        padding: const EdgeInsets.symmetric(vertical: 20),
        child: Center(
          child: Text(
            "No user apps used today.",
            style: GoogleFonts.outfit(color: Colors.white30),
          ),
        ),
      );
    }

    // Sort by time duration
    filteredApps.sort((a, b) {
      int timeA = int.parse(a['totalTimeInForeground'] ?? '0');
      int timeB = int.parse(b['totalTimeInForeground'] ?? '0');
      return timeB.compareTo(timeA);
    });

    final visibleApps = _isAppListExpanded
        ? filteredApps
        : filteredApps.take(5).toList();

    return ListView.builder(
      shrinkWrap: true,
      physics: const NeverScrollableScrollPhysics(),
      itemCount: visibleApps.length,
      itemBuilder: (context, index) {
        final appStat = visibleApps[index];
        final pkg = appStat['packageName'];
        final totalMs = int.parse(appStat['totalTimeInForeground'] ?? '0');

        final timeString = _formatDuration(totalMs);
        final appInfo = _appInfos[pkg];
        final appName = appInfo?.appName ?? pkg ?? "Unknown";
        final Widget appIcon = (appInfo is ApplicationWithIcon)
            ? Image.memory(appInfo.icon, width: 24, height: 24)
            : const Icon(Icons.android, color: Colors.white, size: 24);
        final category = _getCategoryName(appInfo?.category);
        final catIcon = _getCategoryIcon(category);

        return Container(
          margin: const EdgeInsets.only(bottom: 12),
          padding: const EdgeInsets.all(16),
          decoration: BoxDecoration(
            color: const Color(0xFF1E1E1E),
            borderRadius: BorderRadius.circular(16),
          ),
          child: Row(
            children: [
              Container(
                width: 40,
                height: 40,
                decoration: const BoxDecoration(
                  color: Colors.white10,
                  shape: BoxShape.circle,
                ),
                child: Center(
                  child: Text(
                    "${index + 1}",
                    style: const TextStyle(color: Colors.white),
                  ),
                ),
              ),
              const SizedBox(width: 16),
              appIcon,
              const SizedBox(width: 16),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      appName,
                      style: GoogleFonts.outfit(
                        color: Colors.white,
                        fontWeight: FontWeight.w600,
                      ),
                      overflow: TextOverflow.ellipsis,
                    ),
                    const SizedBox(height: 4),
                    Row(
                      children: [
                        Icon(catIcon, size: 12, color: Colors.white30),
                        const SizedBox(width: 4),
                        Text(
                          category,
                          style: GoogleFonts.outfit(
                            color: Colors.white30,
                            fontSize: 10,
                            fontStyle: FontStyle.italic,
                          ),
                        ),
                      ],
                    ),
                  ],
                ),
              ),
              Column(
                crossAxisAlignment: CrossAxisAlignment.end,
                children: [
                  Text(
                    timeString,
                    style: GoogleFonts.outfit(
                      color: Colors.white,
                      fontSize: 13,
                      fontWeight: FontWeight.bold,
                    ),
                  ),
                  const SizedBox(height: 4),
                  Row(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      _buildCountBadge(
                        "${appStat['openCount'] ?? 0} opens",
                        Colors.orangeAccent,
                      ),
                      const SizedBox(width: 6),
                      // Only show notifications if > 0 to keep it clean?
                      // Or just show it. User wants simple.
                      _buildCountBadge(
                        "${appStat['notificationCount'] ?? 0} notifs",
                        Colors.blueAccent,
                      ),
                    ],
                  ),
                ],
              ),
            ],
          ),
        );
      },
    );
  }

  Widget _buildCountBadge(String text, Color color) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 2),
      decoration: BoxDecoration(
        color: color.withOpacity(0.1),
        borderRadius: BorderRadius.circular(4),
        border: Border.all(color: color.withOpacity(0.3)),
      ),
      child: Text(
        text,
        style: GoogleFonts.outfit(
          color: color.withOpacity(0.9),
          fontSize: 10,
          fontWeight: FontWeight.w500,
        ),
      ),
    );
  }

  Future<void> _showSettingsDialog() async {
    final prefs = await SharedPreferences.getInstance();

    // Load existing (default to 4:00 and 11:00)
    int startHour = prefs.getInt('notification_start_hour') ?? 4;
    int startMinute = prefs.getInt('notification_start_minute') ?? 0;

    int endHour = prefs.getInt('notification_end_hour') ?? 11;
    int endMinute = prefs.getInt('notification_end_minute') ?? 0;

    TimeOfDay startTime = TimeOfDay(hour: startHour, minute: startMinute);
    TimeOfDay endTime = TimeOfDay(hour: endHour, minute: endMinute);

    if (!mounted) return;

    showDialog(
      context: context,
      builder: (context) {
        return StatefulBuilder(
          builder: (context, setState) {
            return AlertDialog(
              backgroundColor: const Color(0xFF1E1E1E),
              title: Text(
                "Notification Settings",
                style: GoogleFonts.outfit(color: Colors.white),
              ),
              content: Column(
                mainAxisSize: MainAxisSize.min,
                children: [
                  Text(
                    "Morning Mirror Notification Window",
                    style: GoogleFonts.outfit(color: Colors.white70),
                  ),
                  const SizedBox(height: 16),
                  _buildTimeRow("Start Time", startTime, (newTime) {
                    setState(() => startTime = newTime);
                  }),
                  const SizedBox(height: 8),
                  _buildTimeRow("End Time", endTime, (newTime) {
                    setState(() => endTime = newTime);
                  }),
                ],
              ),
              actions: [
                TextButton(
                  onPressed: () => Navigator.pop(context),
                  child: const Text("Cancel"),
                ),
                ElevatedButton(
                  onPressed: () async {
                    await prefs.setInt(
                      'notification_start_hour',
                      startTime.hour,
                    );
                    await prefs.setInt(
                      'notification_start_minute',
                      startTime.minute,
                    );

                    await prefs.setInt('notification_end_hour', endTime.hour);
                    await prefs.setInt(
                      'notification_end_minute',
                      endTime.minute,
                    );

                    // Reset "sent" flag and 'last_day' to allow immediate re-trigger
                    await prefs.setBool(
                      'morning_notification_sent_today',
                      false,
                    );
                    await prefs.remove('last_day');
                    await prefs.remove('morning_notification_last_sent_date');

                    // Trigger Immediate Re-Check with new settings
                    await MorningWorker.registerPeriodicTask();

                    if (mounted) {
                      Navigator.pop(context);
                      ScaffoldMessenger.of(context).showSnackBar(
                        const SnackBar(
                          content: Text("Settings Saved & Daily Limit Reset"),
                        ),
                      );
                    }
                  },
                  child: const Text("Save"),
                ),
              ],
            );
          },
        );
      },
    );
  }

  Widget _buildTimeRow(
    String label,
    TimeOfDay time,
    Function(TimeOfDay) onChanged,
  ) {
    // Format Time: 9:05 AM
    final local = MaterialLocalizations.of(context);
    String formattedTime = local.formatTimeOfDay(
      time,
      alwaysUse24HourFormat: false,
    );

    return Row(
      mainAxisAlignment: MainAxisAlignment.spaceBetween,
      children: [
        Text(label, style: GoogleFonts.outfit(color: Colors.white)),
        TextButton(
          onPressed: () async {
            final TimeOfDay? picked = await showTimePicker(
              context: context,
              initialTime: time,
              builder: (BuildContext context, Widget? child) {
                return Theme(
                  data: ThemeData.dark().copyWith(
                    colorScheme: const ColorScheme.dark(
                      primary: Colors.amber,
                      onPrimary: Colors.black,
                      surface: Color(0xFF1E1E1E),
                      onSurface: Colors.white,
                    ),
                    dialogBackgroundColor: const Color(0xFF1E1E1E),
                  ),
                  child: child!,
                );
              },
            );
            if (picked != null) {
              onChanged(picked);
            }
          },
          child: Text(
            formattedTime,
            style: GoogleFonts.outfit(
              color: Colors.amber,
              fontWeight: FontWeight.bold,
            ),
          ),
        ),
      ],
    );
  }

  // --- NEW: Metrics & Explanations ---

  void _showExplanationDialog(String title, String description) {
    showDialog(
      context: context,
      builder: (context) {
        return AlertDialog(
          backgroundColor: const Color(0xFF1E1E1E),
          shape: RoundedRectangleBorder(
            borderRadius: BorderRadius.circular(20),
            side: BorderSide(color: Colors.white.withOpacity(0.1)),
          ),
          title: Row(
            children: [
              const Icon(Icons.info_outline, color: Colors.amber),
              const SizedBox(width: 12),
              Expanded(
                child: Text(
                  title,
                  style: GoogleFonts.outfit(
                    color: Colors.white,
                    fontWeight: FontWeight.bold,
                  ),
                ),
              ),
            ],
          ),
          content: Text(
            description,
            style: GoogleFonts.outfit(color: Colors.white70, fontSize: 16),
          ),
          actions: [
            TextButton(
              onPressed: () => Navigator.pop(context),
              child: Text(
                "Got it",
                style: GoogleFonts.outfit(color: Colors.blueAccent),
              ),
            ),
          ],
        );
      },
    );
  }

  Widget _buildDoomscrollCard() {
    final Map<String, dynamic>? currentStats = _isTodaySelected
        ? _todayStats
        : _stats;
    int longestSessionMs = currentStats?['longestSession'] ?? 0;
    String timeStr = _formatDuration(longestSessionMs);

    return Container(
      margin: const EdgeInsets.symmetric(vertical: 16),
      width: double.infinity,
      decoration: BoxDecoration(
        color: const Color(0xFF1E1E1E),
        borderRadius: BorderRadius.circular(24),
        border: Border.all(color: Colors.white.withOpacity(0.05)),
      ),
      child: Stack(
        children: [
          Padding(
            padding: const EdgeInsets.all(24),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Row(
                  children: [
                    const Icon(
                      Icons.timer_off_outlined,
                      color: Colors.deepOrangeAccent,
                      size: 28,
                    ),
                    const SizedBox(width: 12),
                    Text(
                      "Longest Session (Doomscroll)",
                      style: GoogleFonts.outfit(
                        color: Colors.white.withOpacity(0.9),
                        fontSize: 16,
                        fontWeight: FontWeight.w500,
                      ),
                    ),
                  ],
                ),
                const SizedBox(height: 16),
                Text(
                  timeStr,
                  style: GoogleFonts.outfit(
                    color: Colors.white,
                    fontSize: 32,
                    fontWeight: FontWeight.bold,
                  ),
                ),
                const SizedBox(height: 4),
                Text(
                  "Single longest continuous use of one app.",
                  style: GoogleFonts.outfit(
                    color: Colors.white38,
                    fontSize: 12,
                    fontStyle: FontStyle.italic,
                  ),
                ),
              ],
            ),
          ),
          Positioned(
            top: 8,
            right: 8,
            child: IconButton(
              icon: const Icon(
                Icons.help_outline,
                color: Colors.white30,
                size: 20,
              ),
              onPressed: () => _showExplanationDialog(
                "Longest Session (Doomscroll)",
                "This tracks the longest continuous period you spent on a single app without locking your phone or switching apps.\n\nA high number here means you got 'sucked in'!",
              ),
            ),
          ),
        ],
      ),
    );
  }
}
