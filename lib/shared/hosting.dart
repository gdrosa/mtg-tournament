/// How players reach the organizer's authoritative tournament server.
enum HostingMode { lan, online }

extension HostingModeX on HostingMode {
  String get label => switch (this) {
    HostingMode.lan => 'LAN',
    HostingMode.online => 'Online',
  };
}
