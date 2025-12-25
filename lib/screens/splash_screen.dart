import 'package:flutter/material.dart';
import 'package:google_fonts/google_fonts.dart';
import 'package:permission_handler/permission_handler.dart';
import 'package:usage_stats/usage_stats.dart';
import 'dashboard_screen.dart';
import '../services/metric_service.dart';

class SplashScreen extends StatefulWidget {
  const SplashScreen({super.key});

  @override
  State<SplashScreen> createState() => _SplashScreenState();
}

class _SplashScreenState extends State<SplashScreen> {
  final MetricService _metricService = MetricService();
  String _loadingText = "Warming up...";

  @override
  void initState() {
    super.initState();
    _initializeApp();
  }

  Future<void> _initializeApp() async {
    // 1. Initial Delay (User requested Splash, gives native services time to spin up)
    await Future.delayed(const Duration(seconds: 1));

    setState(() {
      _loadingText = "Checking permissions...";
    });

    // 2. Check & Request Basic Permissions (Not Usage Access yet, handled in Dashboard if missing)
    await _checkBasicPermissions();

    // 3. Warm Up Usage Stats Service
    // The core issue is that UsageStats returns empty/0 on cold start.
    // We try to fetch "Yesterday's Stats" here. If it works, great. If not, we wait a bit and retry.
    setState(() {
      _loadingText = "Loading stats...";
    });

    // Try up to 3 times (3 seconds total)
    for (int i = 0; i < 3; i++) {
      try {
        // We check usage permission first to avoid crashing if absolutely denied
        bool hasUsage = await UsageStats.checkUsagePermission() ?? false;
        if (hasUsage) {
          final stats = await _metricService.fetchYesterdayStats();
          if ((stats['totalScreenTime'] ?? 0) > 0) {
            break;
          }
        } else {
          // If we don't have permission yet, we can't warm up.
          // Just proceed to Dashboard which shows the "Grant Permission" UI.
          break;
        }
      } catch (e) {
        debugPrint("Warm up fetch failed: $e");
      }
      await Future.delayed(const Duration(seconds: 1));
    }

    if (mounted) {
      // 4. Navigate to Dashboard
      Navigator.pushReplacement(
        context,
        MaterialPageRoute(builder: (context) => const DashboardScreen()),
      );
    }
  }

  Future<void> _checkBasicPermissions() async {
    // Notification (Android 13+)
    if (await Permission.notification.isDenied) {
      await Permission.notification.request();
    }
    // Activity - Critical for Steps!
    // We check status first. If denied or limited, we request.
    var activityStatus = await Permission.activityRecognition.status;
    if (!activityStatus.isGranted) {
      debugPrint("Requesting Activity Recognition permission...");
      await Permission.activityRecognition.request();
    }

    // Battery
    if (await Permission.ignoreBatteryOptimizations.isDenied) {
      await Permission.ignoreBatteryOptimizations.request();
    }
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: const Color(0xFF121212),
      body: Container(
        decoration: const BoxDecoration(
          gradient: LinearGradient(
            begin: Alignment.topCenter,
            end: Alignment.bottomCenter,
            colors: [Color(0xFF2C3E50), Color(0xFF121212)],
          ),
        ),
        child: Center(
          child: Column(
            mainAxisAlignment: MainAxisAlignment.center,
            children: [
              // Logo / Icon
              Container(
                padding: const EdgeInsets.all(24),
                decoration: BoxDecoration(
                  color: Colors.white.withOpacity(0.05),
                  shape: BoxShape.circle,
                ),
                child: const Icon(
                  Icons.hourglass_empty_rounded,
                  size: 80,
                  color: Colors.amber,
                ),
              ),
              const SizedBox(height: 32),
              Text(
                'Yesterday Phone',
                style: GoogleFonts.outfit(
                  fontSize: 32,
                  fontWeight: FontWeight.bold,
                  color: Colors.white,
                ),
              ),
              const SizedBox(height: 16),
              SizedBox(
                width: 40,
                height: 40,
                child: CircularProgressIndicator(
                  color: Colors.amber.withOpacity(0.8),
                  strokeWidth: 3,
                ),
              ),
              const SizedBox(height: 24),
              Text(
                _loadingText,
                style: GoogleFonts.outfit(
                  color: Colors.white54,
                  fontSize: 14,
                  letterSpacing: 1.2,
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}
