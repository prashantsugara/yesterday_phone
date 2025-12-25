import 'package:flutter/material.dart';
import 'dart:async'; // Required for runZonedGuarded
import 'package:google_mobile_ads/google_mobile_ads.dart';
import 'screens/splash_screen.dart'; // IMPORT SPLASH SCREEN

import 'package:morning_mirror/services/config_service.dart'; // Import ConfigService

import 'services/morning_worker.dart'; // Import MorningWorker

void main() {
  runZonedGuarded(
    () async {
      WidgetsFlutterBinding.ensureInitialized();
      debugPrint(">>> APP LAUNCHING - MAIN STARTED <<<");

      // Initialize WorkManager (Background Worker)
      await MorningWorker.initialize();
      await MorningWorker.registerPeriodicTask();
      debugPrint(">>> WorkManager Initialized & Scheduled");

      // Initialize ConfigService (Firebase)
      // Note: Fails gracefully if google-services.json is missing
      await ConfigService().initialize();
      debugPrint(">>> ConfigService Initialized");

      // Initialize Mobile Ads
      await MobileAds.instance.initialize();
      debugPrint(">>> MobileAds Initialized");

      // Initialize Background Service
      // DISABLED: User requested removal of persistent notification.
      // We now rely on UsageStats history for unlocks and scheduled notifications for alerts.
      // await initializeService();

      runApp(const MorningMirrorApp());
    },
    (error, stack) {
      debugPrint("Global Async Error: $error\n$stack");
    },
  );
}

class MorningMirrorApp extends StatefulWidget {
  const MorningMirrorApp({super.key});

  @override
  State<MorningMirrorApp> createState() => _MorningMirrorAppState();
}

class _MorningMirrorAppState extends State<MorningMirrorApp>
    with WidgetsBindingObserver {
  AppOpenAd? _appOpenAd;
  bool _isShowingAd = false;
  // Test Ad Unit ID for App Open
  final String _adUnitId = 'ca-app-pub-3940256099942544/3419835294';

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    _loadAppOpenAd();
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    super.dispose();
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    debugPrint(">>> App Lifecycle State: $state");
    if (state == AppLifecycleState.resumed) {
      _showAppOpenAdIfAvailable();
    }
  }

  void _loadAppOpenAd() {
    if (!ConfigService().getBool('enable_ads')) {
      debugPrint('Ads disabled via Remote Config');
      return;
    }

    AppOpenAd.load(
      adUnitId: _adUnitId,
      request: const AdRequest(),
      adLoadCallback: AppOpenAdLoadCallback(
        onAdLoaded: (ad) {
          _appOpenAd = ad;
          _showAppOpenAdIfAvailable(); // Show immediately on load if it's the first time
        },
        onAdFailedToLoad: (error) {
          debugPrint('AppOpenAd failed to load: $error');
          debugPrint('AppOpenAd Error Code: ${error.code}');
          debugPrint('AppOpenAd Error Message: ${error.message}');
          debugPrint('AppOpenAd Response Info: ${error.responseInfo}');
        },
      ),
    );
  }

  void _showAppOpenAdIfAvailable() {
    if (_appOpenAd == null || _isShowingAd) {
      return;
    }

    _appOpenAd!.fullScreenContentCallback = FullScreenContentCallback(
      onAdDismissedFullScreenContent: (ad) {
        _isShowingAd = false;
        ad.dispose();
        _appOpenAd = null;
        _loadAppOpenAd();
      },
      onAdFailedToShowFullScreenContent: (ad, error) {
        _isShowingAd = false;
        ad.dispose();
        _appOpenAd = null;
      },
    );

    _appOpenAd!.show();
    _isShowingAd = true;
  }

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      title: 'Yesterday Phone',
      debugShowCheckedModeBanner: false,
      theme: ThemeData(useMaterial3: true, brightness: Brightness.dark),
      home: const SplashScreen(),
    );
  }
}
