import 'package:flutter/material.dart';
import 'package:google_fonts/google_fonts.dart';
import 'package:google_mobile_ads/google_mobile_ads.dart';
import 'package:intl/intl.dart';
import '../services/history_service.dart';
import '../services/metric_service.dart';
import 'package:morning_mirror/services/config_service.dart';
import 'package:morning_mirror/services/local_device_apps.dart';

enum HistoryViewMode { daily, weekly, monthly }

class HistoryScreen extends StatefulWidget {
  const HistoryScreen({super.key});

  @override
  State<HistoryScreen> createState() => _HistoryScreenState();
}

class _HistoryScreenState extends State<HistoryScreen> {
  final HistoryService _historyService = HistoryService();
  List<Map<String, dynamic>> _rawHistory = []; // Raw daily data
  List<Map<String, dynamic>> _groupedHistory = []; // Display data
  bool _isLoading = true;
  HistoryViewMode _viewMode = HistoryViewMode.weekly; // Default

  // Banner Ad
  BannerAd? _bannerAd;
  bool _bannerAdIsLoaded = false;

  @override
  void initState() {
    super.initState();
    _loadHistory();
    _loadBannerAd();
  }

  void _loadBannerAd({String? specificId}) {
    if (!ConfigService().getBool('enable_ads')) {
      return;
    }

    // Dynamic Ad Unit ID
    String adUnitId = specificId ?? ConfigService().getBannerAdUnitId();
    debugPrint("HistoryScreen: Loading Banner Ad with ID: $adUnitId");

    _bannerAd = BannerAd(
      adUnitId: adUnitId,
      request: const AdRequest(),
      size: AdSize.banner,
      listener: BannerAdListener(
        onAdLoaded: (_) {
          setState(() {
            _bannerAdIsLoaded = true;
          });
          debugPrint("BANNER AD LOADED SUCCESSFULLY");
        },
        onAdFailedToLoad: (ad, error) {
          ad.dispose();
          debugPrint('BannerAd failed to load: $error');
          debugPrint('Error Code: ${error.code}');
          debugPrint('Error Message: ${error.message}');

          // Retry with Test ID if Error Code 1 or 3 and not already testing
          if ((error.code == 1 || error.code == 3) &&
              adUnitId != ConfigService.testBannerId) {
            debugPrint(
              "Banner Ad Load Failed (Code ${error.code}). Retrying with TEST ID...",
            );
            _loadBannerAd(specificId: ConfigService.testBannerId);
          }
        },
      ),
    )..load();
  }

  @override
  void dispose() {
    _bannerAd?.dispose();
    super.dispose();
  }

  Future<void> _loadHistory() async {
    final history = await _historyService.getHistory();
    if (mounted) {
      setState(() {
        _rawHistory = history;
        _isLoading = false;
        _updateView();
      });
    }
  }

  // ... (View update methods remain same)

  void _updateView() {
    switch (_viewMode) {
      case HistoryViewMode.daily:
        _groupedHistory = List.from(_rawHistory);
        // Sort daily desc
        _groupedHistory.sort(
          (a, b) =>
              DateTime.parse(b['date']).compareTo(DateTime.parse(a['date'])),
        );
        break;
      case HistoryViewMode.weekly:
        _groupedHistory = _groupHistoryByWeek(_rawHistory);
        break;
      case HistoryViewMode.monthly:
        _groupedHistory = _groupHistoryByMonth(_rawHistory);
        break;
    }
  }

  List<Map<String, dynamic>> _groupHistoryByWeek(
    List<Map<String, dynamic>> dailyHistory,
  ) {
    Map<String, Map<String, dynamic>> weeklyGroups = {};

    for (var dayStat in dailyHistory) {
      DateTime date = DateTime.parse(dayStat['date']);
      // Find start of week (Monday)
      DateTime startOfWeek = date.subtract(Duration(days: date.weekday - 1));
      DateTime endOfWeek = startOfWeek.add(const Duration(days: 6));

      DateTime startKey = DateTime(
        startOfWeek.year,
        startOfWeek.month,
        startOfWeek.day,
      );

      String key =
          "${DateFormat('MMM d').format(startOfWeek)} - ${DateFormat('MMM d').format(endOfWeek)}";

      if (!weeklyGroups.containsKey(key)) {
        weeklyGroups[key] = {
          'dateRange': key,
          'startDate': startKey,
          'totalScreenTime': 0,
          'steps': 0,
          'days': <Map<String, dynamic>>[],
        };
      }

      var group = weeklyGroups[key]!;
      group['totalScreenTime'] =
          (group['totalScreenTime'] as int) +
          ((dayStat['totalScreenTime'] ?? 0) as int);
      group['steps'] =
          (group['steps'] as int) + ((dayStat['steps'] ?? 0) as int);
      (group['days'] as List<Map<String, dynamic>>).add(dayStat);
    }

    return _finalizeGroups(weeklyGroups);
  }

  List<Map<String, dynamic>> _groupHistoryByMonth(
    List<Map<String, dynamic>> dailyHistory,
  ) {
    Map<String, Map<String, dynamic>> monthlyGroups = {};

    for (var dayStat in dailyHistory) {
      DateTime date = DateTime.parse(dayStat['date']);
      DateTime startKey = DateTime(date.year, date.month, 1);

      String key = DateFormat('MMMM y').format(startKey);

      if (!monthlyGroups.containsKey(key)) {
        monthlyGroups[key] = {
          'dateRange': key,
          'startDate': startKey,
          'totalScreenTime': 0,
          'steps': 0,
          'days': <Map<String, dynamic>>[],
        };
      }

      var group = monthlyGroups[key]!;
      group['totalScreenTime'] =
          (group['totalScreenTime'] as int) +
          ((dayStat['totalScreenTime'] ?? 0) as int);
      group['steps'] =
          (group['steps'] as int) + ((dayStat['steps'] ?? 0) as int);
      (group['days'] as List<Map<String, dynamic>>).add(dayStat);
    }

    return _finalizeGroups(monthlyGroups);
  }

  List<Map<String, dynamic>> _finalizeGroups(
    Map<String, Map<String, dynamic>> groups,
  ) {
    List<Map<String, dynamic>> result = [];
    groups.forEach((key, value) {
      List<Map<String, dynamic>> days = value['days'];
      int dayCount = days.length;

      // Calculate Averages
      double avgScreenTime = dayCount > 0
          ? (value['totalScreenTime'] / dayCount)
          : 0;
      int avgSteps = dayCount > 0 ? (value['steps'] ~/ dayCount) : 0;

      // Sort days desc
      days.sort(
        (a, b) =>
            DateTime.parse(b['date']).compareTo(DateTime.parse(a['date'])),
      );

      result.add({
        'displayTitle': value['dateRange'],
        'sortDate': value['startDate'],
        'avgScreenTime': avgScreenTime,
        'avgSteps': avgSteps,
        'days': days,
      });
    });

    result.sort(
      (a, b) =>
          (b['sortDate'] as DateTime).compareTo(a['sortDate'] as DateTime),
    );
    return result;
  }

  // ... (Grouping methods remain same, skipping for brevity in replacement if possible, but I need to be careful with range)
  // Since I selected a large range, I should include them or just target the class start.
  // Actually, I'll use the 'Header' method to target the initial part of class and imports.

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: const Color(0xFF121212),
      appBar: AppBar(
        backgroundColor: const Color(0xFF121212),
        elevation: 0,
        title: Text(
          "History",
          style: GoogleFonts.outfit(
            fontWeight: FontWeight.bold,
            color: Colors.white,
          ),
        ),
        iconTheme: const IconThemeData(color: Colors.white),
      ),
      bottomNavigationBar: _bannerAdIsLoaded && _bannerAd != null
          ? SizedBox(
              height: _bannerAd!.size.height.toDouble(),
              width: _bannerAd!.size.width.toDouble(),
              child: AdWidget(ad: _bannerAd!),
            )
          : null,
      body: Column(
        children: [
          _buildViewSelector(),
          Expanded(
            child: _isLoading
                ? const Center(
                    child: CircularProgressIndicator(color: Colors.amber),
                  )
                : _groupedHistory.isEmpty
                ? Center(
                    child: Column(
                      mainAxisAlignment: MainAxisAlignment.center,
                      children: [
                        const Icon(
                          Icons.history_toggle_off,
                          size: 64,
                          color: Colors.white24,
                        ),
                        const SizedBox(height: 16),
                        Text(
                          "No history yet.",
                          style: GoogleFonts.outfit(
                            color: Colors.white54,
                            fontSize: 16,
                          ),
                        ),
                      ],
                    ),
                  )
                : ListView.builder(
                    padding: const EdgeInsets.all(16),
                    itemCount: _groupedHistory.length,
                    itemBuilder: (context, index) {
                      return _viewMode == HistoryViewMode.daily
                          ? _buildDailyCard(_groupedHistory[index])
                          : _buildGroupedCard(_groupedHistory[index]);
                    },
                  ),
          ),
        ],
      ),
    );
  }

  Widget _buildViewSelector() {
    return Container(
      margin: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
      width: double.infinity,
      child: SegmentedButton<HistoryViewMode>(
        segments: const [
          ButtonSegment(value: HistoryViewMode.daily, label: Text("Daily")),
          ButtonSegment(value: HistoryViewMode.weekly, label: Text("Weekly")),
          ButtonSegment(value: HistoryViewMode.monthly, label: Text("Monthly")),
        ],
        selected: {_viewMode},
        onSelectionChanged: (Set<HistoryViewMode> newSelection) {
          setState(() {
            _viewMode = newSelection.first;
            _updateView();
          });
        },
        style: ButtonStyle(
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

  Widget _buildGroupedCard(Map<String, dynamic> item) {
    final title = item['displayTitle'] as String;
    final avgSteps = item['avgSteps'] as int;
    final avgMs = item['avgScreenTime'] as double;
    final avgHours = (avgMs / (1000 * 60 * 60)).toStringAsFixed(1);
    final days = item['days'] as List<Map<String, dynamic>>;

    return Card(
      color: const Color(0xFF1E1E1E),
      shape: RoundedRectangleBorder(
        borderRadius: BorderRadius.circular(16),
        side: BorderSide(color: Colors.white.withOpacity(0.05)),
      ),
      margin: const EdgeInsets.only(bottom: 12),
      child: ExpansionTile(
        iconColor: Colors.white70,
        collapsedIconColor: Colors.white54,
        tilePadding: const EdgeInsets.all(8),
        leading: Container(
          padding: const EdgeInsets.all(12),
          decoration: BoxDecoration(
            color: Colors.blueGrey.withOpacity(0.2),
            borderRadius: BorderRadius.circular(12),
          ),
          child: Icon(
            _viewMode == HistoryViewMode.weekly
                ? Icons.date_range
                : Icons.calendar_month,
            color: Colors.blueGrey,
            size: 24,
          ),
        ),
        title: Text(
          title,
          style: GoogleFonts.outfit(
            color: Colors.white,
            fontSize: 16,
            fontWeight: FontWeight.bold,
          ),
        ),
        subtitle: Padding(
          padding: const EdgeInsets.only(top: 4.0),
          child: Row(
            children: [
              Icon(Icons.schedule, size: 14, color: Colors.orange[300]),
              const SizedBox(width: 4),
              Text(
                "$avgHours hrs avg",
                style: GoogleFonts.outfit(color: Colors.white70, fontSize: 14),
              ),
              const SizedBox(width: 16),
              Icon(Icons.directions_walk, size: 14, color: Colors.blue[300]),
              const SizedBox(width: 4),
              Text(
                "$avgSteps steps avg",
                style: GoogleFonts.outfit(color: Colors.white70, fontSize: 14),
              ),
              const SizedBox(width: 16),
              // Distance
              Text(
                MetricService.convertToDistance(avgSteps)['display']!,
                style: GoogleFonts.outfit(
                  color: Colors.white54,
                  fontSize: 14,
                  fontStyle: FontStyle.italic,
                ),
              ),
            ],
          ),
        ),
        children: [
          ListView.builder(
            shrinkWrap: true,
            physics: const NeverScrollableScrollPhysics(),
            itemCount: days.length,
            itemBuilder: (context, dayIndex) {
              return _buildDailyListTile(days[dayIndex]);
            },
          ),
        ],
      ),
    );
  }

  Widget _buildDailyCard(Map<String, dynamic> item) {
    // Top Apps handling for Daily View
    final topApps = item['topApps'] as List<dynamic>? ?? [];

    return Card(
      color: const Color(0xFF1E1E1E),
      shape: RoundedRectangleBorder(
        borderRadius: BorderRadius.circular(16),
        side: BorderSide(color: Colors.white.withOpacity(0.05)),
      ),
      margin: const EdgeInsets.only(bottom: 12),
      child: ExpansionTile(
        title: _buildDailyHeader(item), // Reusing the header row
        children: [
          if (topApps.isEmpty)
            Padding(
              padding: const EdgeInsets.all(16.0),
              child: Text(
                "No app usage details",
                style: GoogleFonts.outfit(color: Colors.white54),
              ),
            )
          else
            ListView.builder(
              shrinkWrap: true,
              physics: const NeverScrollableScrollPhysics(),
              itemCount: topApps.length,
              itemBuilder: (context, appIndex) {
                final appStat = topApps[appIndex];
                final pkg = appStat['packageName'] ?? 'Unknown';
                final duration =
                    int.tryParse(
                      appStat['totalTimeInForeground']?.toString() ?? '0',
                    ) ??
                    0;
                final min = (duration / (1000 * 60)).toStringAsFixed(0);

                return FutureBuilder<Application?>(
                  future: LocalDeviceApps.getApp(pkg, true),
                  builder: (context, snapshot) {
                    final appInfo = snapshot.data;
                    final name = appInfo?.appName ?? pkg;

                    Widget leadingIcon;
                    if (appInfo is ApplicationWithIcon) {
                      leadingIcon = Image.memory(
                        appInfo.icon,
                        width: 20,
                        height: 20,
                      );
                    } else {
                      leadingIcon = const Icon(
                        Icons.android,
                        size: 20,
                        color: Colors.white54,
                      );
                    }

                    return ListTile(
                      leading: leadingIcon,
                      title: Text(
                        name,
                        style: GoogleFonts.outfit(
                          color: Colors.white,
                          fontSize: 13,
                        ),
                      ),
                      trailing: Text(
                        "$min min",
                        style: GoogleFonts.outfit(
                          color: Colors.white54,
                          fontSize: 12,
                        ),
                      ),
                      dense: true,
                    );
                  },
                );
              },
            ),
        ],
      ),
    );
  }

  Widget _buildDailyHeader(Map<String, dynamic> item) {
    final date = DateTime.parse(item['date']);
    final dateStr = DateFormat('EEE, MMM d, y').format(date);
    final steps = item['steps'] ?? 0;
    final totalMs = item['totalScreenTime'] ?? 0;
    final hours = (totalMs / (1000 * 60 * 60)).toStringAsFixed(1);

    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text(
          dateStr,
          style: GoogleFonts.outfit(
            color: Colors.white,
            fontSize: 16,
            fontWeight: FontWeight.bold,
          ),
        ),
        const SizedBox(height: 4),
        Row(
          children: [
            Icon(Icons.schedule, size: 14, color: Colors.orange[300]),
            const SizedBox(width: 4),
            Text(
              "$hours hrs",
              style: GoogleFonts.outfit(color: Colors.white70, fontSize: 14),
            ),
            const SizedBox(width: 16),
            Icon(Icons.directions_walk, size: 14, color: Colors.blue[300]),
            const SizedBox(width: 4),
            Text(
              "$steps steps",
              style: GoogleFonts.outfit(color: Colors.white70, fontSize: 14),
            ),
          ],
        ),
        const SizedBox(height: 4),
        Text(
          "Distance: ${MetricService.convertToDistance(steps)['display']}",
          style: GoogleFonts.outfit(color: Colors.white54, fontSize: 12),
        ),
      ],
    );
  }

  Widget _buildDailyListTile(Map<String, dynamic> dayStat) {
    final date = DateTime.parse(dayStat['date']);
    final dayStr = DateFormat('EEE, MMM d').format(date);

    final steps = dayStat['steps'] ?? 0;
    final totalMs = dayStat['totalScreenTime'] ?? 0;
    final hours = (totalMs / (1000 * 60 * 60)).toStringAsFixed(1);

    return ListTile(
      title: Text(
        dayStr,
        style: GoogleFonts.outfit(
          color: Colors.white,
          fontSize: 14,
          fontWeight: FontWeight.w600,
        ),
      ),
      trailing: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          Icon(Icons.schedule, size: 12, color: Colors.orange[300]),
          const SizedBox(width: 4),
          Text(
            "$hours h",
            style: GoogleFonts.outfit(color: Colors.white70, fontSize: 12),
          ),
          const SizedBox(width: 12),
          Icon(Icons.directions_walk, size: 12, color: Colors.blue[300]),
          const SizedBox(width: 4),
          Text(
            "$steps",
            style: GoogleFonts.outfit(color: Colors.white70, fontSize: 12),
          ),
        ],
      ),
      subtitle: Text(
        "${MetricService.convertToDistance(steps)['display']}",
        style: GoogleFonts.outfit(color: Colors.white30, fontSize: 10),
      ),
      dense: true,
    );
  }
}
