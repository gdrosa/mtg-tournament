/// Small locale-free formatting helpers for the host UI (no `intl` dependency,
/// keeping the APK lean per NFR-03).
library;

const _months = [
  'Jan',
  'Feb',
  'Mar',
  'Apr',
  'May',
  'Jun',
  'Jul',
  'Aug',
  'Sep',
  'Oct',
  'Nov',
  'Dec',
];

/// e.g. `6 Jun 2026`.
String formatDate(DateTime d) {
  final local = d.toLocal();
  return '${local.day} ${_months[local.month - 1]} ${local.year}';
}
