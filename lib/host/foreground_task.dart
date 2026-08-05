/// Foreground-service plumbing that keeps the app process (and therefore the
/// main-isolate LAN server) alive while the organizer's screen is off.
///
/// The server runs on the MAIN isolate; this service exists only to raise the
/// process priority so Android doesn't kill it mid-tournament. The handler does
/// no periodic work.
library;

import 'package:flutter_foreground_task/flutter_foreground_task.dart';

/// Android invokes this in the service isolate when the service starts.
@pragma('vm:entry-point')
void hostingTaskCallback() {
  FlutterForegroundTask.setTaskHandler(_HostingTaskHandler());
}

class _HostingTaskHandler extends TaskHandler {
  @override
  Future<void> onStart(DateTime timestamp, TaskStarter starter) async {}

  @override
  void onRepeatEvent(DateTime timestamp) {}

  @override
  Future<void> onDestroy(DateTime timestamp) async {}

  /// The notification "Stop hosting" button. Tell the main isolate to tear down
  /// the LAN server (it owns it), then stop this service so the notification
  /// clears immediately.
  @override
  void onNotificationButtonPressed(String id) {
    if (id == 'stop') {
      FlutterForegroundTask.sendDataToMain('stopHosting');
      FlutterForegroundTask.stopService();
    }
  }
}
