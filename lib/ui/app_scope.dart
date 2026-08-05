import 'package:flutter/material.dart';

import '../host/host_controller.dart';

/// Exposes the single app-wide [HostController] to the whole widget tree.
///
/// The controller owns the embedded LAN server, the foreground service, and the
/// durable store (decks + tournament history). Lifting it above the navigation
/// shell — rather than creating one per [HostScreen] — lets the Decks / Events /
/// Profile tabs read real persisted data, and lets the notification "Stop
/// hosting" button reach a live controller even when no host screen is mounted.
///
/// Because this is an [InheritedNotifier], any widget that reads
/// `AppScope.of(context)` rebuilds automatically whenever the controller (and
/// thus tournament state) changes.
class AppScope extends InheritedNotifier<HostController> {
  const AppScope({
    super.key,
    required HostController controller,
    required super.child,
  }) : super(notifier: controller);

  static HostController of(BuildContext context) {
    final scope = context.dependOnInheritedWidgetOfExactType<AppScope>();
    assert(scope != null, 'No AppScope found in the widget tree.');
    return scope!.notifier!;
  }
}
