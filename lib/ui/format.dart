String formatBytes(num? value) {
  if (value == null) return 'Unknown';
  if (value < 1024) return '${value.round()} B';
  const units = ['KB', 'MB', 'GB', 'TB'];
  var size = value.toDouble() / 1024;
  var unit = 0;
  while (size >= 1024 && unit < units.length - 1) {
    size /= 1024;
    unit++;
  }
  return '${size.toStringAsFixed(size >= 100 ? 0 : 2)} ${units[unit]}';
}

String formatRemaining(Duration? duration) {
  if (duration == null) return '—';
  if (duration.inHours > 0) {
    return '${duration.inHours} hr ${duration.inMinutes.remainder(60)} min';
  }
  if (duration.inMinutes > 0) {
    return '${duration.inMinutes} min ${duration.inSeconds.remainder(60)} sec';
  }
  return '${duration.inSeconds} sec';
}

String formatDate(DateTime date) =>
    '${date.year}-${date.month.toString().padLeft(2, '0')}-${date.day.toString().padLeft(2, '0')} '
    '${date.hour.toString().padLeft(2, '0')}:${date.minute.toString().padLeft(2, '0')}';
