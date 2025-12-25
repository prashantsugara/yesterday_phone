import 'dart:async';
import 'package:pedometer/pedometer.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:intl/intl.dart';
import 'package:flutter/foundation.dart';

class StepService {
  static const String _keyLastCounter = 'step_last_counter';
  static const String _keyTodaySteps = 'step_today_steps';
  static const String _keyYesterdaySteps = 'step_yesterday_steps';
  static const String _keyLastDate = 'step_last_date';

  StreamSubscription<StepCount>? _subscription;

  Future<void> init() async {
    _subscription = Pedometer.stepCountStream.listen(
      _onStepCount,
      onError: _onStepCountError,
      cancelOnError: true,
    );
  }

  void dispose() {
    _subscription?.cancel();
  }

  void _onStepCount(StepCount event) async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.reload(); // Ensure fresh data on every event

    final currentCounter = event.steps;
    final now = DateTime.now();
    final todayDate = DateFormat('yyyy-MM-dd').format(now);

    int? lastCounter = prefs.getInt(
      _keyLastCounter,
    ); // Nullable check for first run
    int todaySteps = prefs.getInt(_keyTodaySteps) ?? 0;
    int yesterdaySteps = prefs.getInt(_keyYesterdaySteps) ?? 0;
    String lastDate = prefs.getString(_keyLastDate) ?? todayDate;

    // RULE 1: First Run
    if (lastCounter == null) {
      debugPrint(
        '[StepService] First Run. Initializing baseline: $currentCounter on $todayDate',
      );
      await prefs.setInt(_keyLastCounter, currentCounter);
      await prefs.setInt(_keyTodaySteps, 0); // Start at 0 relative to now
      await prefs.setInt(_keyYesterdaySteps, 0);
      await prefs.setString(_keyLastDate, todayDate);
      return; // STOP
    }

    // RULE 2: Device Reboot (Counter Reset)
    if (currentCounter < lastCounter) {
      debugPrint(
        '[StepService] Reboot Detected! Current ($currentCounter) < Last ($lastCounter). Resetting baseline.',
      );
      await prefs.setInt(_keyLastCounter, currentCounter);
      await prefs.setInt(_keyTodaySteps, 0); // New baseline
      await prefs.setInt(
        _keyYesterdaySteps,
        0,
      ); // Lost data due to reboot/reset
      await prefs.setString(_keyLastDate, todayDate);
      return; // STOP
    }

    // RULE 3: Same Day Update
    if (todayDate == lastDate) {
      todaySteps = currentCounter - lastCounter;
      // Safety check for negative steps (should be covered by reboot check, but good practice)
      if (todaySteps < 0) todaySteps = 0;

      debugPrint(
        '[StepService] Update (Same Day): Raw=$currentCounter, Base=$lastCounter, TodaySteps=$todaySteps',
      );

      await prefs.setInt(_keyTodaySteps, todaySteps);
      return; // STOP
    }

    // RULE 4: Day Change (Rollover)
    if (todayDate != lastDate) {
      debugPrint(
        '[StepService] Day Change detected! Old: $lastDate, New: $todayDate. Finalizing Yesterday: $todaySteps',
      );

      // Finalise yesterday using the accumulated value from the previous "todaySteps"
      // Note: We don't calc diff here because we might have missed updates between
      // 11:59PM and now. We just take what was accumulated as "today" and call it "yesterday".
      yesterdaySteps = todaySteps;

      lastCounter = currentCounter; // Reset baseline for new day
      todaySteps = 0;
      lastDate = todayDate;

      await prefs.setInt(_keyYesterdaySteps, yesterdaySteps);
      await prefs.setInt(_keyLastCounter, lastCounter);
      await prefs.setInt(_keyTodaySteps, todaySteps);
      await prefs.setString(_keyLastDate, lastDate);
      return; // STOP
    }
  }

  void _onStepCountError(error) {
    print('Pedometer Error: $error');
  }

  // Public getters
  static Future<int> getTodaySteps() async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.reload();
    return prefs.getInt(_keyTodaySteps) ?? 0;
  }

  static Future<int> getYesterdaySteps() async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.reload();
    return prefs.getInt(_keyYesterdaySteps) ?? 0;
  }
}
