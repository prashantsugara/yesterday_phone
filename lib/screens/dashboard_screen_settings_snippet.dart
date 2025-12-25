import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart'; // Assuming this is needed for showDialog, AlertDialog, etc.
import 'package:google_fonts/google_fonts.dart'; // Assuming this is needed for GoogleFonts
import 'package:shared_preferences/shared_preferences.dart'; // Assuming this is needed for SharedPreferences

// Assuming 'context' and 'mounted' are available, implying this is part of a StatefulWidget.
// For this example, I'll assume a dummy context and mounted for compilation if not provided.
// In a real app, this would be inside a State class.
BuildContext? context; // Placeholder
bool mounted = true; // Placeholder

Future<void> _showSettingsDialog() async {
  final prefs = await SharedPreferences.getInstance();
  int startHour = prefs.getInt('notification_start_hour') ?? 4;
  int startMinute = prefs.getInt('notification_start_minute') ?? 0;

  int endHour = prefs.getInt('notification_end_hour') ?? 11;
  int endMinute = prefs.getInt('notification_end_minute') ?? 0;

  if (!mounted) return;

  showDialog(
    context: context!, // Use ! for placeholder context
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
                _buildTimeRow("Start Time", startHour, startMinute, (h, m) {
                  setState(() {
                    startHour = h;
                    startMinute = m;
                  });
                }),
                const SizedBox(height: 8),
                _buildTimeRow("End Time", endHour, endMinute, (h, m) {
                  setState(() {
                    endHour = h;
                    endMinute = m;
                  });
                }),
                const SizedBox(height: 16),
                // Always show for now (User Request)
                TextButton.icon(
                  onPressed: () async {
                    await prefs.setBool(
                      'morning_notification_sent_today',
                      false,
                    );
                    if (mounted) {
                      ScaffoldMessenger.of(context).showSnackBar(
                        const SnackBar(
                          content: Text("DEBUG: Daily Flag Reset!"),
                        ),
                      );
                    }
                  },
                  icon: const Icon(Icons.refresh, color: Colors.amber),
                  label: const Text(
                    "Reset Daily Flag",
                    style: TextStyle(color: Colors.amber),
                  ),
                ),
              ],
            ),
            actions: [
              TextButton(
                onPressed: () => Navigator.pop(context),
                child: const Text("Cancel"),
              ),
              ElevatedButton(
                onPressed: () async {
                  await prefs.setInt('notification_start_hour', startHour);
                  await prefs.setInt('notification_start_minute', startMinute);

                  await prefs.setInt('notification_end_hour', endHour);
                  await prefs.setInt('notification_end_minute', endMinute);

                  // Reset "sent" flag so if the new window is valid NOW, it can trigger.
                  await prefs.setBool('morning_notification_sent_today', false);

                  // Double check
                  bool verify =
                      prefs.getBool('morning_notification_sent_today') ?? true;

                  debugPrint(
                    "Settings Saved: Window $startHour:$startMinute - $endHour:$endMinute. Reset Sent Flag: $verify",
                  );
                  if (mounted) {
                    Navigator.pop(context);
                    ScaffoldMessenger.of(context).showSnackBar(
                      const SnackBar(content: Text("Settings Saved")),
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
  int hour,
  int minute,
  Function(int, int) onChanged,
) {
  // Simple 12-hour format display
  String period = hour >= 12 ? "PM" : "AM";
  int displayHour = hour > 12 ? hour - 12 : (hour == 0 ? 12 : hour);
  String displayMinute = minute.toString().padLeft(2, '0');

  return Row(
    mainAxisAlignment: MainAxisAlignment.spaceBetween,
    children: [
      Text(label, style: GoogleFonts.outfit(color: Colors.white)),
      TextButton(
        onPressed: () async {
          final TimeOfDay? picked = await showTimePicker(
            context: context!, // Use ! for placeholder context
            initialTime: TimeOfDay(hour: hour, minute: minute),
          );
          if (picked != null) {
            onChanged(picked.hour, picked.minute);
          }
        },
        child: Text(
          "$displayHour:$displayMinute $period",
          style: GoogleFonts.outfit(
            color: Colors.amber,
            fontWeight: FontWeight.bold,
          ),
        ),
      ),
    ],
  );
}
