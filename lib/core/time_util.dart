/// Date/time helpers for the xsrs notations (plan 12.5).
///
/// The device is asymmetric: it accepts `+09:00` (colon form) on input
/// and returns `+0900` (compact form). The asymmetry is absorbed here,
/// in the transport-adjacent layer, so models only hold [DateTime].
library;

/// Parses an xsrs / WebAPI timestamp in either offset notation
/// (`+0900` or `+09:00`), returning null when unparseable.
DateTime? parseNasneDateTime(String? value) {
  if (value == null || value.isEmpty) return null;
  var s = value.trim();
  // Normalise a trailing compact offset +0900 to the colon form +09:00.
  final m = RegExp(r'([+-]\d{2})(\d{2})$').firstMatch(s);
  if (m != null && !s.endsWith('Z')) {
    s = '${s.substring(0, m.start)}${m.group(1)}:${m.group(2)}';
  }
  return DateTime.tryParse(s);
}

/// Parses an ISO-8601 timestamp treating offset-less date+time strings as JST
/// (`+09:00`). Explicit offsets (`Z` / `+HH:MM` / `-HHMM`) are preserved.
DateTime? parseJstDateTime(String? value) {
  if (value == null) return null;
  var s = value.trim();
  if (s.isEmpty) return null;
  final compactOffset = RegExp(r'([+-]\d{2})(\d{2})$').firstMatch(s);
  if (compactOffset != null && !s.endsWith('Z') && !s.endsWith('z')) {
    s = '${s.substring(0, compactOffset.start)}'
        '${compactOffset.group(1)}:${compactOffset.group(2)}';
  } else if (RegExp(r'\d{2}:\d{2}').hasMatch(s) &&
      !s.endsWith('Z') &&
      !s.endsWith('z') &&
      !RegExp(r'[+-]\d{2}:?\d{2}$').hasMatch(s)) {
    s = '$s+09:00';
  }
  return DateTime.tryParse(s);
}

/// Formats [value] the way the device expects on input:
/// `2026-11-18T04:00:00+09:00` (colon offset form, plan 11.7).
///
/// The nasne is a Japan-only product and every measured timestamp
/// uses the +0900 offset, so the wall clock is rendered in JST
/// (UTC+9, no DST) regardless of the runtime's local zone: a
/// reservation means "this wall time at the device".
String formatNasneDateTime(DateTime value) {
  String two(int v) => v.toString().padLeft(2, '0');
  final jst = value.toUtc().add(const Duration(hours: 9));
  return '${jst.year.toString().padLeft(4, '0')}-${two(jst.month)}-'
      '${two(jst.day)}T${two(jst.hour)}:${two(jst.minute)}:'
      '${two(jst.second)}+09:00';
}
