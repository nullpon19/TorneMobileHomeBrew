/// Display formatting helpers for the UI layer.
///
/// The device lives in JST and every measured timestamp uses the
/// +0900 offset (plan 13.8), so the UI renders wall-clock times in
/// JST regardless of the host timezone, matching the core's send-side
/// convention (core/time_util.dart).
library;

String _two(int v) => v.toString().padLeft(2, '0');

/// The JST wall clock of [instant], as a UTC DateTime whose fields
/// hold the JST values. Read the fields only; do not pass this to
/// timezone-aware formatters.
DateTime jstWallClock(DateTime instant) =>
    instant.toUtc().add(const Duration(hours: 9));

/// Interprets [wall]'s fields as a JST wall time and returns the
/// corresponding instant.
DateTime instantFromJstWall(DateTime wall) => DateTime.utc(
  wall.year,
  wall.month,
  wall.day,
  wall.hour,
  wall.minute,
  wall.second,
).subtract(const Duration(hours: 9));

/// `2026/11/18`
String formatDateJst(DateTime instant) {
  final w = jstWallClock(instant);
  return '${w.year}/${_two(w.month)}/${_two(w.day)}';
}

/// `04:00`
String formatTimeJst(DateTime instant) {
  final w = jstWallClock(instant);
  return '${_two(w.hour)}:${_two(w.minute)}';
}

/// `2026/11/18 04:00`
String formatDateTimeJst(DateTime instant) =>
    '${formatDateJst(instant)} ${formatTimeJst(instant)}';

/// Japanese weekday label of the JST wall clock.
String formatWeekdayJst(DateTime instant) {
  const labels = ['月', '火', '水', '木', '金', '土', '日'];
  return labels[jstWallClock(instant).weekday - 1];
}

/// `2026/11/18 (水) 04:00`
String formatDateTimeWithWeekdayJst(DateTime instant) =>
    '${formatDateJst(instant)} (${formatWeekdayJst(instant)}) '
    '${formatTimeJst(instant)}';

/// `2026/11/18 (水) 04:00–04:30` (or `2026/11/18 (水) 04:00` if duration unset).
String formatRecordedBroadcastTimeRangeJst(
  DateTime start,
  int? durationSeconds,
) {
  final head = formatDateTimeWithWeekdayJst(start);
  if (durationSeconds == null || durationSeconds <= 0) return head;
  final end = start.add(Duration(seconds: durationSeconds));
  return '$head–${formatTimeJst(end)}';
}

/// Duration text: `30秒` / `45分` / `1時間` / `1時間30分`.
String formatDurationSeconds(int seconds) {
  if (seconds < 60) return '$seconds秒';
  final m = seconds ~/ 60;
  if (m < 60) return '$m分';
  final h = m ~/ 60;
  final rest = m % 60;
  return rest == 0 ? '$h時間' : '$h時間$rest分';
}

/// Human-readable byte size (binary units).
String formatBytes(int bytes) {
  if (bytes < 1024) return '$bytes B';
  const units = ['KB', 'MB', 'GB', 'TB'];
  var value = bytes / 1024;
  var i = 0;
  while (value >= 1024 && i < units.length - 1) {
    value /= 1024;
    i++;
  }
  final text = value >= 100
      ? value.toStringAsFixed(0)
      : value.toStringAsFixed(1);
  return '$text ${units[i]}';
}

/// Official label of a recording quality mode (`desiredQualityMode`).
///
/// The nasne recording modes are named, not numbered, in the official
/// apps (plan 5.0 principle 5). In the XSRS value space — the space
/// reservations and recorded titles are read and written in — the
/// measured torne values are 100 = DR and 230 = 3倍 (plan 28:
/// torne-created reservations sampled 2026-11-11 and 2026-11-17,
/// the latter a 3倍 reservation carrying 230). The value 101 that
/// earlier builds labelled 3倍 came from the WebAPI JSON surface
/// (recNgList), a different value space; no XSRS item with 101 has
/// been observed, and an update writing 101 was accepted yet not
/// stored (plan 13.7), so 101 is NOT labelled here. Values whose
/// official label has not been confirmed fall back to the raw
/// number; labels are never invented (plan 16.4).
String qualityModeLabel(int mode) => switch (mode) {
  100 => 'DR',
  230 => '3倍',
  _ => '$mode',
};

/// Display label for `desiredQualityMode` in WebAPI `recNgListGet`, where
/// `101` (alongside XSRS `230`) represents 3倍 mode.
String recNgQualityModeLabel(int mode) => switch (mode) {
  100 => 'DR',
  101 || 230 => '3倍',
  _ => qualityModeLabel(mode),
};

/// Display label of a DIDL res `quality` value (plan 33): the
/// `quality` query parameter of a res URL (`dr` / `x3` / `mobile`,
/// measured in plan 11.8). Unknown values fall back to the raw
/// string; labels are never invented (plan 16.4).
String resQualityLabel(String? quality) => switch (quality) {
  'dr' => 'DR',
  'x3' => '3倍',
  'mobile' => 'モバイル',
  null => '元画質',
  _ => quality,
};

/// Official display form of the software version.
///
/// `softwareVersionGet` returns a 4-digit string ("0260"); the
/// official nasne settings screen shows the version as "2.60"
/// ("Ver:2.60"), so the raw value is re-dotted for display (plan 5.0
/// principle 5, plan 18). Unexpected shapes fall back to the raw
/// value; the model keeps the raw string.
String softwareVersionLabel(String version) {
  if (version.length == 4 && int.tryParse(version) != null) {
    final major = int.parse(version.substring(0, 2));
    return '$major.${version.substring(2)}';
  }
  return version;
}

/// Official area name for the region reported by `areaInfoGet`.
///
/// The response carries no name field; it carries two numbers,
/// `areaIdentifierCode` and `pref`, and the official nasne settings
/// UI (the unit's own Web UI, `nasne_home/lib/app.js`) resolves the
/// pair against a built-in table of 56 entries — that table is
/// reproduced in [_areaNamesByPair] (plan 19). The anchor entry was
/// verified live: the owner's unit returns (55, 41), which the table
/// names 福岡, matching its Fukuoka setting.
///
/// `pref` on its own is the JIS prefecture code + 1 (Hokkaido is
/// split across pref 1 and 2; 49 = Tokyo islands and 50 = Kagoshima
/// islands are extras), so it identifies every region except the
/// eight Hokkaido sub-areas; the pair is the exact key. Name
/// spellings follow torne's official area list (PvrResource.cxml,
/// 53 names); the three Web-UI-only splits torne does not name
/// (Asahikawa-Sorachi, the Tokyo islands, the Kagoshima islands)
/// are rendered in the same style from the Web UI names. Unmatched
/// values fall back to the raw number; labels are never invented
/// (plan 5.0 principle 5).
String areaLabel(String? areaIdentifierCode, String? pref) {
  final code = int.tryParse(areaIdentifierCode ?? '');
  final prefCode = int.tryParse(pref ?? '');
  if (code != null && prefCode != null) {
    final name = _areaNamesByPair[(code, prefCode)];
    if (name != null) return name;
  }
  if (prefCode != null) {
    final name = _areaNameByUniquePref[prefCode];
    if (name != null) return name;
  }
  return pref ?? areaIdentifierCode ?? '';
}

/// (areaIdentifierCode, pref) -> official area name. Source: the
/// area table built into the unit's own Web UI (plan 19).
const _areaNamesByPair = <(int, int), String>{
  (13, 1): '北海道（帯広）',
  (14, 1): '北海道（釧路）',
  (15, 1): '北海道（北見）',
  (12, 1): '北海道（旭川）',
  (12, 2): '北海道（旭川・空知）',
  (10, 2): '北海道（札幌）',
  (11, 2): '北海道（函館）',
  (16, 2): '北海道（室蘭）',
  (22, 3): '青森',
  (20, 4): '岩手',
  (17, 5): '宮城',
  (18, 6): '秋田',
  (19, 7): '山形',
  (21, 8): '福島',
  (26, 9): '茨城',
  (28, 10): '栃木',
  (25, 11): '群馬',
  (29, 12): '埼玉',
  (27, 13): '千葉',
  (23, 14): '東京',
  (23, 49): '東京（島部）',
  (24, 15): '神奈川',
  (31, 16): '新潟',
  (37, 17): '富山',
  (34, 18): '石川',
  (36, 19): '福井',
  (32, 20): '山梨',
  (30, 21): '長野',
  (39, 22): '岐阜',
  (35, 23): '静岡',
  (33, 24): '愛知',
  (38, 25): '三重',
  (45, 26): '滋賀',
  (41, 27): '京都',
  (40, 28): '大阪',
  (42, 29): '兵庫',
  (44, 30): '奈良',
  (43, 31): '和歌山',
  (49, 32): '鳥取',
  (48, 33): '島根',
  (47, 34): '岡山',
  (46, 35): '広島',
  (50, 36): '山口',
  (53, 37): '徳島',
  (52, 38): '香川',
  (51, 39): '愛媛',
  (54, 40): '高知',
  (55, 41): '福岡',
  (61, 42): '佐賀',
  (57, 43): '長崎',
  (56, 44): '熊本',
  (60, 45): '大分',
  (59, 46): '宮崎',
  (58, 47): '鹿児島',
  (58, 50): '鹿児島（南西諸島）',
  (62, 48): '沖縄',
};

/// pref -> name for the prefs that identify exactly one area (all
/// except Hokkaido's 1 and 2). Derived from [_areaNamesByPair].
final _areaNameByUniquePref = _buildUniquePrefIndex();

Map<int, String> _buildUniquePrefIndex() {
  final byPref = <int, String?>{};
  for (final entry in _areaNamesByPair.entries) {
    final pref = entry.key.$2;
    byPref[pref] = byPref.containsKey(pref) && byPref[pref] != entry.value
        ? null
        : entry.value;
  }
  return {
    for (final e in byPref.entries)
      if (e.value != null) e.key: e.value!,
  };
}

/// Masks an identifier for display, keeping only the last [keep]
/// characters (B-CAS card ids and similar, plan section 7).
String maskTail(String value, {int keep = 4}) {
  if (value.length <= keep) return '••';
  return '••${value.substring(value.length - keep)}';
}

/// Masks a MAC address: the last three octets are the PIN derivation
/// source (plan 11.5), so only the first three octets are shown.
String maskMac(String mac) {
  final parts = mac.split(':');
  if (parts.length == 6) {
    return '${parts[0]}:${parts[1]}:${parts[2]}:••:••:••';
  }
  return maskTail(mac);
}
