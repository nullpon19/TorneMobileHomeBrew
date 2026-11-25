/// Search, sort and filtering for the recorded title list
/// (plan 86.5). Pure view logic over the merged [RecordedTitle]
/// list: the screen holds the user's choices, this file decides
/// what they mean. Before this the list was the raw fetch order
/// with no way to find anything in it (plan 85 item 5).
library;

import '../core/models/title.dart';

/// Sort orders offered above the title list.
enum TitleSortOrder {
  recordedNewest('新しい順'),
  recordedOldest('古い順'),
  titleAsc('番組名順');

  const TitleSortOrder(this.label);

  final String label;
}

/// The user's search / filter choices for the title list.
class TitleListFilter {
  const TitleListFilter({
    this.query = '',
    this.channelKey,
    this.genre,
    this.unwatchedOnly = false,
  });

  /// Title substring to match (case-insensitive); empty matches all.
  final String query;

  /// Channel grouping key (see [titleChannelKey]); null = all.
  final String? channelKey;

  /// DIDL genre text; null = all.
  final String? genre;

  /// Only titles the unit still flags as new (unwatched).
  final bool unwatchedOnly;

  bool get isActive =>
      query.trim().isNotEmpty ||
      channelKey != null ||
      genre != null ||
      unwatchedOnly;
}

/// The channel a title is grouped and filtered by: the DIDL
/// channel name when the merge provided one, else the XSRS
/// service in the same fallback form the detail view shows.
String? titleChannelKey(RecordedTitle title) {
  final name = title.channelName;
  if (name != null && name.isNotEmpty) return name;
  final channel = title.channel;
  if (channel != null) return 'サービス ${channel.serviceIdHex}';
  return null;
}

/// Distinct channel keys present in [titles], sorted for display.
List<String> titleChannelChoices(List<RecordedTitle> titles) {
  final keys = <String>{for (final t in titles) ?titleChannelKey(t)};
  return keys.toList()..sort();
}

/// Distinct genre texts present in [titles], sorted for display.
List<String> titleGenreChoices(List<RecordedTitle> titles) {
  final genres = <String>{
    for (final t in titles)
      if (t.genre case final genre? when genre.isNotEmpty) genre,
  };
  return genres.toList()..sort();
}

/// Applies [filter] and [sort] to [titles]; the input list is
/// not modified. Undated titles sort last in both date orders,
/// so a missing timestamp never floats to the top.
List<RecordedTitle> applyTitleListView(
  List<RecordedTitle> titles, {
  required TitleListFilter filter,
  required TitleSortOrder sort,
}) {
  final query = filter.query.trim().toLowerCase();
  final result = [
    for (final t in titles)
      if ((query.isEmpty || t.title.toLowerCase().contains(query)) &&
          (filter.channelKey == null ||
              titleChannelKey(t) == filter.channelKey) &&
          (filter.genre == null || t.genre == filter.genre) &&
          (!filter.unwatchedOnly || t.newFlag))
        t,
  ];
  int byTitle(RecordedTitle a, RecordedTitle b) {
    final c = a.title.compareTo(b.title);
    return c != 0 ? c : a.id.compareTo(b.id);
  }

  int byDate(RecordedTitle a, RecordedTitle b, {required bool newestFirst}) {
    final ad = a.scheduledStart;
    final bd = b.scheduledStart;
    if (ad == null && bd == null) return byTitle(a, b);
    if (ad == null) return 1;
    if (bd == null) return -1;
    final c = newestFirst ? bd.compareTo(ad) : ad.compareTo(bd);
    return c != 0 ? c : byTitle(a, b);
  }

  result.sort(switch (sort) {
    TitleSortOrder.recordedNewest => (a, b) => byDate(a, b, newestFirst: true),
    TitleSortOrder.recordedOldest => (a, b) => byDate(a, b, newestFirst: false),
    TitleSortOrder.titleAsc => byTitle,
  });
  return result;
}

/// A grouped entry in the recorded titles list.
///
/// When [isFolder] is true ([titles.length] >= 2), the UI renders a
/// collapsible series folder header whose episodes expand inline underneath.
/// Singletons ([titles.length] == 1) render as normal individual rows.
class TitleGroup {
  const TitleGroup({
    required this.key,
    required this.label,
    required this.titles,
  });

  final String key;
  final String label;
  final List<RecordedTitle> titles;

  bool get isFolder => titles.length >= 2;
  bool get hasUnwatched => titles.any((t) => t.newFlag);
  bool get allProtected =>
      titles.isNotEmpty && titles.every((t) => t.protectFlag);

  DateTime? get earliestStart {
    DateTime? min;
    for (final t in titles) {
      final s = t.scheduledStart;
      if (s == null) continue;
      if (min == null || s.isBefore(min)) min = s;
    }
    return min;
  }

  DateTime? get latestStart {
    DateTime? max;
    for (final t in titles) {
      final s = t.scheduledStart;
      if (s == null) continue;
      if (max == null || s.isAfter(max)) max = s;
    }
    return max;
  }
}

final RegExp _aribBracketTagPattern = RegExp(
  r'\[(?:HV|SD|P|W|MV|手|字|双|デ|S|二|多|解|SS|B|N|天|交|映|無|料|前|後|再|新|初|終|生|販|声|吹|PPV|ほか)\]'
  r'|【(?:新|終|再|生|初|字|多|二)】'
  r'|\((?:新|終|再)\)'
  r'|㊙',
);

final RegExp _episodeCutPattern = RegExp(
  r'\s*[#＃]\s*[0-9０-９]+'
  r'|\s*第\s*[0-9０-９一二三四五六七八九十百千]+\s*[話回弾章夜幕節]'
  r'|(?:\s|^)(?:Vol|VOL|Ep|EP|Episode|EPISODE|Part|PART)\.?\s*[0-9０-９]+'
  r'|\s*[(\[（［]\s*[#＃]?\s*[0-9０-９]{1,4}\s*[話回]?\s*[)\]）］]'
  r'|\s*[▽▼「『【]'
  r'|\s+[〜～]',
);

final RegExp _multiSpacePattern = RegExp(r'[\s\u3000]+');
final RegExp _trailingSepPattern = RegExp(r'[\s:：\-−―‐/／・]+$');

String _trimTrailingSeparators(String value) =>
    value.replaceFirst(_trailingSepPattern, '').trim();

/// Extracts a normalized series base title from [rawTitle] for auto-grouping.
///
/// Pass 1 only strips ARIB attribute tags and explicit episode/subtitle
/// markers (`#N`, `第N話`, `Vol.N`, `▽▼「『【`, ` 〜`). Singletons with plain
/// suffixes remain untouched until Pass 2 boundary checks run.
String extractSeriesBaseTitle(String rawTitle) {
  var s = rawTitle.replaceAll(_aribBracketTagPattern, '');
  s = s.replaceAll(_multiSpacePattern, ' ').trim();
  if (s.isEmpty) return '';

  // Remove cut markers matching strictly after index 0 so titles starting with
  // brackets/quotes (e.g. `【特番】...`) do not collapse to empty strings.
  for (final m in _episodeCutPattern.allMatches(s)) {
    final prefix = _trimTrailingSeparators(s.substring(0, m.start));
    if (prefix.isNotEmpty) {
      s = prefix;
      break;
    }
  }
  return _trimTrailingSeparators(s);
}

bool _isBoundarySeparator(int codeUnit) =>
    codeUnit == 0x20 || // space
    codeUnit == 0x28 || // (
    codeUnit == 0xFF08 || // （
    codeUnit == 0x5B || // [
    codeUnit == 0xFF3B; // ［

bool _isDigit(int codeUnit) =>
    (codeUnit >= 0x30 && codeUnit <= 0x39) ||
    (codeUnit >= 0xFF10 && codeUnit <= 0xFF19);

String? _safeCommonPrefix(
  String a,
  String b, {
  bool allowExactPrefixDigit = false,
}) {
  final minLen = a.length < b.length ? a.length : b.length;
  var lcp = 0;
  while (lcp < minLen && a.codeUnitAt(lcp) == b.codeUnitAt(lcp)) {
    lcp++;
  }
  if (lcp < 3) return null;

  for (var i = lcp; i >= 3; i--) {
    // Do not split inside a UTF-16 surrogate pair.
    if (i < a.length && (a.codeUnitAt(i) & 0xFC00) == 0xDC00) continue;

    final aEnds = i == a.length || _isBoundarySeparator(a.codeUnitAt(i));
    final bEnds = i == b.length || _isBoundarySeparator(b.codeUnitAt(i));
    if (aEnds && bEnds) {
      final candidate = _trimTrailingSeparators(a.substring(0, i));
      final exactMatch =
          candidate.length == a.length || candidate.length == b.length;
      if (candidate.length >= (exactMatch ? 3 : 4)) {
        return candidate;
      }
    }

    // Merge consecutive numbered installments (e.g. `... バクアゲ36` / `37` / `38`)
    // only on a strict non-digit -> digit transition with >= 6 chars prefix.
    final bCurrDigit = i < b.length && _isDigit(b.codeUnitAt(i));
    final aDigitMatch = i < a.length
        ? _isDigit(a.codeUnitAt(i))
        : allowExactPrefixDigit;
    if (i >= 6 &&
        i <= a.length &&
        i < b.length &&
        bCurrDigit &&
        aDigitMatch &&
        !_isDigit(a.codeUnitAt(i - 1))) {
      final raw = a.substring(0, i);
      if (raw.endsWith(' 第')) {
        final candidate = _trimTrailingSeparators(
          raw.substring(0, raw.length - 1),
        );
        if (candidate.length >= 4) return candidate;
      } else {
        final candidate = _trimTrailingSeparators(raw);
        if (candidate.length >= 6) return candidate;
      }
    }
  }
  return null;
}

int _compareTitlesBySort(
  RecordedTitle a,
  RecordedTitle b,
  TitleSortOrder sort,
) {
  switch (sort) {
    case TitleSortOrder.recordedNewest:
      final sa = a.scheduledStart;
      final sb = b.scheduledStart;
      if (sa == null && sb == null) return a.title.compareTo(b.title);
      if (sa == null) return 1;
      if (sb == null) return -1;
      final c = sb.compareTo(sa);
      return c != 0 ? c : a.title.compareTo(b.title);
    case TitleSortOrder.recordedOldest:
      final sa = a.scheduledStart;
      final sb = b.scheduledStart;
      if (sa == null && sb == null) return a.title.compareTo(b.title);
      if (sa == null) return 1;
      if (sb == null) return -1;
      final c = sa.compareTo(sb);
      return c != 0 ? c : a.title.compareTo(b.title);
    case TitleSortOrder.titleAsc:
      final c = a.title.toLowerCase().compareTo(b.title.toLowerCase());
      return c != 0 ? c : a.title.compareTo(b.title);
  }
}

int _compareGroupsBySort(TitleGroup a, TitleGroup b, TitleSortOrder sort) {
  switch (sort) {
    case TitleSortOrder.recordedNewest:
      final sa = a.latestStart;
      final sb = b.latestStart;
      if (sa == null && sb == null) return a.label.compareTo(b.label);
      if (sa == null) return 1;
      if (sb == null) return -1;
      final c = sb.compareTo(sa);
      return c != 0 ? c : a.label.compareTo(b.label);
    case TitleSortOrder.recordedOldest:
      final sa = a.earliestStart;
      final sb = b.earliestStart;
      if (sa == null && sb == null) return a.label.compareTo(b.label);
      if (sa == null) return 1;
      if (sb == null) return -1;
      final c = sa.compareTo(sb);
      return c != 0 ? c : a.label.compareTo(b.label);
    case TitleSortOrder.titleAsc:
      final c = a.label.toLowerCase().compareTo(b.label.toLowerCase());
      return c != 0 ? c : a.label.compareTo(b.label);
  }
}

/// Groups [titles] that belong to the same programme series into [TitleGroup]
/// folders while leaving unique shows as singletons.
///
/// Both outer groups and inner episodes follow [sort].
List<TitleGroup> groupRecordedTitles(
  List<RecordedTitle> titles, {
  required TitleSortOrder sort,
}) {
  if (titles.isEmpty) return const [];

  // Pass 1: bucket by explicit normalized base title.
  final pass1Buckets = <String, List<RecordedTitle>>{};
  for (final t in titles) {
    final base = extractSeriesBaseTitle(t.title);
    final key = base.isNotEmpty ? base : 'id:${t.id}';
    (pass1Buckets[key] ??= []).add(t);
  }

  // Pass 2: merge distinct Pass-1 keys that share a safe series prefix
  // (e.g. `明治安田J2リーグ 秋田×山形` / `秋田×仙台` or `バクアゲ36` / `37`).
  final sortedKeys = pass1Buckets.keys
      .where((k) => !k.startsWith('id:'))
      .toList()
    ..sort();
  final mergedBuckets = <String, List<RecordedTitle>>{};
  for (final k in pass1Buckets.keys.where((k) => k.startsWith('id:'))) {
    mergedBuckets[k] = List<RecordedTitle>.from(pass1Buckets[k]!);
  }

  if (sortedKeys.isNotEmpty) {
    var clusterPrefix = sortedKeys.first;
    var clusterMembers = <String>[sortedKeys.first];

    void flushCluster() {
      final list = <RecordedTitle>[];
      for (final member in clusterMembers) {
        list.addAll(pass1Buckets[member]!);
      }
      final existing = mergedBuckets[clusterPrefix];
      if (existing != null) {
        existing.addAll(list);
      } else {
        mergedBuckets[clusterPrefix] = list;
      }
    }

    for (var idx = 1; idx < sortedKeys.length; idx++) {
      final nextKey = sortedKeys[idx];
      final common = _safeCommonPrefix(
        clusterPrefix,
        nextKey,
        allowExactPrefixDigit: clusterMembers.length >= 2,
      );
      if (common != null) {
        clusterPrefix = common;
        clusterMembers.add(nextKey);
      } else {
        flushCluster();
        clusterPrefix = nextKey;
        clusterMembers = [nextKey];
      }
    }
    flushCluster();
  }

  final groups = <TitleGroup>[];
  for (final entry in mergedBuckets.entries) {
    final items = entry.value..sort((a, b) => _compareTitlesBySort(a, b, sort));
    if (items.length >= 2) {
      final label = entry.key.startsWith('id:') ? items.first.title : entry.key;
      groups.add(
        TitleGroup(
          key: 'series:$label',
          label: label,
          titles: List.unmodifiable(items),
        ),
      );
    } else {
      final single = items.first;
      groups.add(
        TitleGroup(
          key: 'single:${single.id}',
          label: single.title,
          titles: List.unmodifiable(items),
        ),
      );
    }
  }

  groups.sort((a, b) => _compareGroupsBySort(a, b, sort));
  return groups;
}

final RegExp _rebroadcastMarkerPattern = RegExp(
  r'[\[［【(（]再[\]］】)）]',
);

bool isRebroadcastTitle(String rawTitle) =>
    _rebroadcastMarkerPattern.hasMatch(rawTitle);

String _asciiDigitsOnly(String input) {
  final sb = StringBuffer();
  for (final rune in input.runes) {
    if (rune >= 0xFF10 && rune <= 0xFF19) {
      sb.writeCharCode(rune - 0xFEE0);
    } else {
      sb.writeCharCode(rune);
    }
  }
  return sb.toString();
}

int? _parseKanjiNumber(String raw) {
  const digits = {
    '〇': 0,
    '零': 0,
    '一': 1,
    '二': 2,
    '三': 3,
    '四': 4,
    '五': 5,
    '六': 6,
    '七': 7,
    '八': 8,
    '九': 9,
  };
  var total = 0;
  var current = 0;
  var seen = false;
  for (final ch in raw.split('')) {
    if (digits.containsKey(ch)) {
      current = digits[ch]!;
      seen = true;
    } else if (ch == '十') {
      total += (current == 0 ? 1 : current) * 10;
      current = 0;
      seen = true;
    } else if (ch == '百') {
      total += (current == 0 ? 1 : current) * 100;
      current = 0;
      seen = true;
    } else {
      return null;
    }
  }
  if (!seen) return null;
  return total + current;
}

final RegExp _epHashPattern = RegExp(r'[#＃]\s*([0-9]+(?:\.[0-9]+)?)');
final RegExp _epDaiDigitPattern = RegExp(
  r'第\s*([0-9]+(?:\.[0-9]+)?)\s*[話回弾章夜幕節]?',
);
final RegExp _epDaiKanjiPattern = RegExp(
  r'第\s*([〇零一二三四五六七八九十百]{1,5})\s*[話回弾章夜幕節]',
);
final RegExp _epWordPattern = RegExp(
  r'(?:Vol|VOL|Ep|EP|Episode|EPISODE|Part|PART)\.?\s*([0-9]+(?:\.[0-9]+)?)',
);
final RegExp _epBracketPattern = RegExp(
  r'[\[(（［]\s*([0-9]{1,4})\s*[話回]?\s*[\])）］]',
);
final RegExp _epTrailingNumberPattern = RegExp(
  r'[^0-9./\-]([0-9]{1,4})(?:\s*(?:話|回)|$)',
);

/// Extracts the primary episode number from a broadcast title, or `null` when
/// the programme is unnumbered (e.g. variety shows / movies).
double? extractEpisodeNumber(String rawTitle) {
  final stripped = _asciiDigitsOnly(rawTitle.replaceAll(_aribBracketTagPattern, ''))
      .replaceAll(RegExp(r'\d{1,2}月\d{1,2}日'), ' ')
      .replaceAll(RegExp(r'\d{1,2}/\d{1,2}'), ' ');

  for (final pattern in [_epHashPattern, _epDaiDigitPattern, _epWordPattern]) {
    final m = pattern.firstMatch(stripped);
    if (m != null) {
      final v = double.tryParse(m.group(1)!);
      if (v != null) return v;
    }
  }

  final kanjiMatch = _epDaiKanjiPattern.firstMatch(stripped);
  if (kanjiMatch != null) {
    final kv = _parseKanjiNumber(kanjiMatch.group(1)!);
    if (kv != null) return kv.toDouble();
  }

  for (final m in _epBracketPattern.allMatches(stripped)) {
    final n = int.tryParse(m.group(1)!);
    if (n != null && (n < 1900 || n > 2100)) {
      return n.toDouble();
    }
  }

  final tail = _epTrailingNumberPattern.firstMatch(stripped);
  if (tail != null) {
    final n = int.tryParse(tail.group(1)!);
    if (n != null && (n < 1900 || n > 2100)) {
      return n.toDouble();
    }
  }
  return null;
}

int _compareDateAscThenId(RecordedTitle a, RecordedTitle b) {
  final sa = a.scheduledStart;
  final sb = b.scheduledStart;
  if (sa == null && sb == null) {
    final tc = a.title.compareTo(b.title);
    return tc != 0 ? tc : a.id.compareTo(b.id);
  }
  if (sa == null) return 1;
  if (sb == null) return -1;
  final dc = sa.compareTo(sb);
  if (dc != 0) return dc;
  final tc = a.title.compareTo(b.title);
  return tc != 0 ? tc : a.id.compareTo(b.id);
}

/// Resolves the next episode to auto-play after [current] within the same
/// series folder.
///
/// - Regular broadcasts stay in the regular lane; rebroadcasts (`[再]`) stay in
///   the rebroadcast lane.
/// - When episode numbers exist, advances to the smallest strictly greater
///   episode number (skipping duplicate recordings of the same episode).
/// - Otherwise falls back to chronological broadcast-date ascending order.
RecordedTitle? resolveNextEpisodeInSeries({
  required RecordedTitle current,
  required List<RecordedTitle> groupTitles,
}) {
  final currentRebroadcast = isRebroadcastTitle(current.title);
  final seenIds = <String>{};
  final lane = <RecordedTitle>[];
  for (final item in groupTitles) {
    if (item.res.isEmpty) continue;
    if (!seenIds.add(item.id)) continue;
    if (isRebroadcastTitle(item.title) == currentRebroadcast) {
      lane.add(item);
    }
  }
  if (lane.length < 2) return null;

  final currentEp = extractEpisodeNumber(current.title);
  if (currentEp != null) {
    final numberedCandidates = <({RecordedTitle title, double ep})>[];
    for (final item in lane) {
      if (item.id == current.id) continue;
      final ep = extractEpisodeNumber(item.title);
      if (ep != null && ep > currentEp) {
        numberedCandidates.add((title: item, ep: ep));
      }
    }
    if (numberedCandidates.isNotEmpty) {
      numberedCandidates.sort((a, b) {
        final epCmp = a.ep.compareTo(b.ep);
        if (epCmp != 0) return epCmp;
        return _compareDateAscThenId(a.title, b.title);
      });
      return numberedCandidates.first.title;
    }
  }

  lane.sort(_compareDateAscThenId);
  final idx = lane.indexWhere((t) => t.id == current.id);
  if (idx >= 0 && idx + 1 < lane.length) {
    return lane[idx + 1];
  }
  return null;
}
