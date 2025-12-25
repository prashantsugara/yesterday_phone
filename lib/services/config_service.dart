import 'package:firebase_core/firebase_core.dart';
import 'package:firebase_remote_config/firebase_remote_config.dart';
import 'package:flutter/foundation.dart';

class ConfigService {
  static final ConfigService _instance = ConfigService._internal();
  factory ConfigService() => _instance;
  ConfigService._internal();

  late final FirebaseRemoteConfig _remoteConfig;

  // Defaults
  final Map<String, dynamic> _defaults = {
    'welcome_message': 'Welcome to Morning Mirror!',
    'enable_new_notifications': true,
    'enable_ads': false, // Changed from enable_ad to match Remote Config
    'banner_ad_unit_id': '',
    'rewarded_ad_unit_id': '',
  };

  Future<void> initialize() async {
    try {
      await Firebase.initializeApp();
      _remoteConfig = FirebaseRemoteConfig.instance;

      // 1. Set Defaults
      await _remoteConfig.setDefaults(_defaults);

      // 2. Set Config Settings (Dev mode: minimal fetch interval)
      await _remoteConfig.setConfigSettings(
        RemoteConfigSettings(
          fetchTimeout: const Duration(minutes: 1),
          minimumFetchInterval: kDebugMode
              ? const Duration(minutes: 1) // Frequent fetch in debug
              : const Duration(hours: 12), // Production standard
        ),
      );

      // 3. Fetch and Activate
      bool updated = await _remoteConfig.fetchAndActivate();
      debugPrint("Remote Config Fetch Updated: $updated");
      debugPrint("Last Fetch Status: ${_remoteConfig.lastFetchStatus}");
      debugPrint("Last Fetch Time: ${_remoteConfig.lastFetchTime}");

      debugPrint("Remote Config Initialized.");
      debugPrint("welcome_message: ${getString('welcome_message')}");

      debugPrint("--- FIREBASE REMOTE CONFIG VALUES ---");
      _remoteConfig.getAll().forEach((key, value) {
        debugPrint(
          "Key: $key, Value: ${value.asString()}, Source: ${value.source}",
        );
      });
      debugPrint("-------------------------------------");
    } catch (e) {
      debugPrint("Failed to initialize Remote Config: $e");
      // Fallback to defaults is automatic
    }
  }

  // Test Ad Unit IDs (Google Defaults)
  // Test Ad Unit IDs (Google Defaults)
  static const String testBannerId = 'ca-app-pub-3940256099942544/6300978111';
  static const String testRewardedId = 'ca-app-pub-3940256099942544/5224354917';

  String getBannerAdUnitId() {
    String id = getString('banner_ad_unit_id').trim();
    if (id.isEmpty) {
      debugPrint("ConfigService: Using TEST Banner ID");
      return testBannerId;
    }
    debugPrint("ConfigService: Using Remote Banner ID: $id");
    return id;
  }

  String getRewardedAdUnitId() {
    String id = getString('rewarded_ad_unit_id').trim();
    if (id.isEmpty) {
      debugPrint("ConfigService: Using TEST Rewarded ID");
      return testRewardedId;
    }
    debugPrint("ConfigService: Using Remote Rewarded ID: $id");
    return id;
  }

  // Getters
  String getString(String key) => _remoteConfig.getString(key);
  bool getBool(String key) => _remoteConfig.getBool(key);
  int getInt(String key) => _remoteConfig.getInt(key);
  double getDouble(String key) => _remoteConfig.getDouble(key);
}
