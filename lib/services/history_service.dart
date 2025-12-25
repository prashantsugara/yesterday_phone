import 'dart:convert';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:intl/intl.dart';

class HistoryService {
  static const String _keyHistory = 'mirror_history_data';

  // Save a daily stat if it doesn't represent today (we only save "yesterday's" or older closed days)
  // or just overwrite the entry for that specific date key.
  Future<void> saveDailyStat(Map<String, dynamic> stats) async {
    final prefs = await SharedPreferences.getInstance();

    // Get existing history
    String? jsonString = prefs.getString(_keyHistory);
    List<dynamic> historyList = jsonString != null
        ? jsonDecode(jsonString)
        : [];

    // Check if entry for this date already exists
    // The 'date' in stats acts as the unique key (day level)
    final dateStr = stats['date'].toString().split(' ')[0]; // yyyy-mm-dd

    // Remove existing entry for this date if any (to update it)
    historyList.removeWhere((item) {
      final itemDate = item['date'].toString().split(' ')[0];
      return itemDate == dateStr;
    });

    // Add new stat
    // We might want to clear "topApps" from history to save space if it gets too big?
    // The prompt says "history of last 12 months".
    // Let's store essential metrics.

    // Prepare serializable map (DateTime needs to be string)
    Map<String, dynamic> serializableStats = Map.from(stats);
    serializableStats['date'] = stats['date'].toString();

    // Apps list might need serialization if it contains objects, but currently our MetricService returns basic Maps/Objects?
    // MetricService returns List<UsageInfo>. UsageInfo needs toJson.
    // Actually MetricService returns a Map. Let's check MetricService content.
    // 'topApps' is List<UsageInfo>. UsageInfo might not be directly jsonEncode-able if it doesn't have toJson?
    // UsageInfo from usage_stats package usually has toJson? Let's assume we map it manually to be safe.

    // Fix: Handle topApps as Map directly (since MetricService now returns Maps)
    if (stats['topApps'] is List) {
      serializableStats['topApps'] = (stats['topApps'] as List).map((e) {
        // e is already a Map<String, dynamic> from MetricService
        if (e is Map) {
          return e;
        }
        // Fallback for UsageInfo objects (old code)
        try {
          dynamic d = e;
          return {
            'packageName': d.packageName,
            'totalTimeInForeground': d.totalTimeInForeground,
          };
        } catch (_) {
          return {};
        }
      }).toList();
    }

    historyList.add(serializableStats);

    // Sort by date descending
    historyList.sort((a, b) {
      DateTime dA = DateTime.parse(a['date']);
      DateTime dB = DateTime.parse(b['date']);
      return dB.compareTo(dA);
    });

    // Prune entries older than 12 months (approx 365 days)
    if (historyList.length > 365) {
      historyList = historyList.sublist(0, 365);
    }

    await prefs.setString(_keyHistory, jsonEncode(historyList));
  }

  Future<List<Map<String, dynamic>>> getHistory() async {
    final prefs = await SharedPreferences.getInstance();
    String? jsonString = prefs.getString(_keyHistory);
    if (jsonString == null) return [];

    List<dynamic> list = jsonDecode(jsonString);
    return list.cast<Map<String, dynamic>>();
  }
}
