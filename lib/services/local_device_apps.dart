import 'package:flutter/services.dart';
import 'dart:typed_data';

class Application {
  final String appName;
  final String packageName;
  final dynamic category; // Can be int or specific enum if we map it
  final bool systemApp;

  Application({
    required this.appName,
    required this.packageName,
    this.category,
    this.systemApp = false,
  });
}

class ApplicationWithIcon extends Application {
  final Uint8List icon;

  ApplicationWithIcon({
    required String appName,
    required String packageName,
    dynamic category,
    bool systemApp = false,
    required this.icon,
  }) : super(
         appName: appName,
         packageName: packageName,
         category: category,
         systemApp: systemApp,
       );
}

class LocalDeviceApps {
  static const MethodChannel _channel = MethodChannel(
    'com.yesterday.phone/device_apps',
  );

  static Future<Application?> getApp(
    String packageName,
    bool includeIcon,
  ) async {
    try {
      final Map<dynamic, dynamic>? data = await _channel.invokeMethod(
        'getApp',
        {'packageName': packageName, 'includeIcon': includeIcon},
      );

      if (data == null) return null;

      final String name = data['appName'] ?? packageName;
      final String pkg = data['packageName'] ?? packageName;

      // Map Category Int to String
      dynamic rawCat = data['category'];
      String categoryStr = "Other";
      if (rawCat is int) {
        switch (rawCat) {
          case 0:
            categoryStr = 'Game';
            break;
          case 1:
            categoryStr = 'Audio';
            break;
          case 2:
            categoryStr = 'Video';
            break;
          case 3:
            categoryStr = 'Image';
            break;
          case 4:
            categoryStr = 'Social';
            break;
          case 5:
            categoryStr = 'News';
            break;
          case 6:
            categoryStr = 'Maps';
            break;
          case 7:
            categoryStr = 'Productivity';
            break;
          case -1:
            categoryStr = 'System Apps';
            break;
          default:
            categoryStr = 'Other';
        }
      } else if (rawCat is String) {
        categoryStr = rawCat;
      }

      final bool isSystem = data['isSystemApp'] == true;
      final Uint8List? iconBytes = data['icon'];

      if (includeIcon && iconBytes != null && iconBytes.isNotEmpty) {
        return ApplicationWithIcon(
          appName: name,
          packageName: pkg,
          category: categoryStr,
          systemApp: isSystem,
          icon: iconBytes,
        );
      } else {
        return Application(
          appName: name,
          packageName: pkg,
          category: categoryStr,
          systemApp: isSystem,
        );
      }
    } catch (e) {
      return null;
    }
  }
}
