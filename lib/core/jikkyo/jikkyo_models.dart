/// Pure-Dart models, NX-Jikkyo channel catalogue, chat/mail parser, and
/// persisted user settings for Niconico Jikkyo overlay (Phase 40).
library;

import 'dart:convert';

const String kJikkyoDisabledId = 'off';

enum JikkyoChannelCategory { terrestrial, bs, cs, special }

class JikkyoChannelDef {
  const JikkyoChannelDef({
    required this.id,
    required this.name,
    required this.category,
    this.serviceId,
  });

  final String id;
  final String name;
  final JikkyoChannelCategory category;
  final int? serviceId;

  String get displayLabel => '$id $name';
}

/// Complete channel list served by NX-Jikkyo (`/api/v1/channels`).
const List<JikkyoChannelDef> kJikkyoChannels = [
  // Terrestrial
  JikkyoChannelDef(
    id: 'jk1',
    name: 'NHK総合',
    category: JikkyoChannelCategory.terrestrial,
  ),
  JikkyoChannelDef(
    id: 'jk2',
    name: 'NHK Eテレ',
    category: JikkyoChannelCategory.terrestrial,
  ),
  JikkyoChannelDef(
    id: 'jk4',
    name: '日本テレビ',
    category: JikkyoChannelCategory.terrestrial,
  ),
  JikkyoChannelDef(
    id: 'jk5',
    name: 'テレビ朝日',
    category: JikkyoChannelCategory.terrestrial,
  ),
  JikkyoChannelDef(
    id: 'jk6',
    name: 'TBSテレビ',
    category: JikkyoChannelCategory.terrestrial,
  ),
  JikkyoChannelDef(
    id: 'jk7',
    name: 'テレビ東京',
    category: JikkyoChannelCategory.terrestrial,
  ),
  JikkyoChannelDef(
    id: 'jk8',
    name: 'フジテレビ',
    category: JikkyoChannelCategory.terrestrial,
  ),
  JikkyoChannelDef(
    id: 'jk9',
    name: 'TOKYO MX',
    category: JikkyoChannelCategory.terrestrial,
  ),
  JikkyoChannelDef(
    id: 'jk10',
    name: 'テレ玉',
    category: JikkyoChannelCategory.terrestrial,
  ),
  JikkyoChannelDef(
    id: 'jk11',
    name: 'tvk',
    category: JikkyoChannelCategory.terrestrial,
  ),
  JikkyoChannelDef(
    id: 'jk12',
    name: 'チバテレビ',
    category: JikkyoChannelCategory.terrestrial,
  ),
  JikkyoChannelDef(
    id: 'jk13',
    name: 'サンテレビ',
    category: JikkyoChannelCategory.terrestrial,
  ),
  JikkyoChannelDef(
    id: 'jk14',
    name: 'KBS京都',
    category: JikkyoChannelCategory.terrestrial,
  ),
  // BS
  JikkyoChannelDef(
    id: 'jk101',
    name: 'NHK BS',
    category: JikkyoChannelCategory.bs,
    serviceId: 101,
  ),
  JikkyoChannelDef(
    id: 'jk103',
    name: 'NHK BSプレミアム4K',
    category: JikkyoChannelCategory.bs,
    serviceId: 103,
  ),
  JikkyoChannelDef(
    id: 'jk141',
    name: 'BS日テレ',
    category: JikkyoChannelCategory.bs,
    serviceId: 141,
  ),
  JikkyoChannelDef(
    id: 'jk151',
    name: 'BS朝日',
    category: JikkyoChannelCategory.bs,
    serviceId: 151,
  ),
  JikkyoChannelDef(
    id: 'jk161',
    name: 'BS-TBS',
    category: JikkyoChannelCategory.bs,
    serviceId: 161,
  ),
  JikkyoChannelDef(
    id: 'jk171',
    name: 'BSテレ東',
    category: JikkyoChannelCategory.bs,
    serviceId: 171,
  ),
  JikkyoChannelDef(
    id: 'jk181',
    name: 'BSフジ',
    category: JikkyoChannelCategory.bs,
    serviceId: 181,
  ),
  JikkyoChannelDef(
    id: 'jk191',
    name: 'WOWOW PRIME',
    category: JikkyoChannelCategory.bs,
    serviceId: 191,
  ),
  JikkyoChannelDef(
    id: 'jk192',
    name: 'WOWOW LIVE',
    category: JikkyoChannelCategory.bs,
    serviceId: 192,
  ),
  JikkyoChannelDef(
    id: 'jk193',
    name: 'WOWOW CINEMA',
    category: JikkyoChannelCategory.bs,
    serviceId: 193,
  ),
  JikkyoChannelDef(
    id: 'jk200',
    name: 'BS10',
    category: JikkyoChannelCategory.bs,
    serviceId: 200,
  ),
  JikkyoChannelDef(
    id: 'jk201',
    name: 'BS10スターチャンネル',
    category: JikkyoChannelCategory.bs,
    serviceId: 201,
  ),
  JikkyoChannelDef(
    id: 'jk211',
    name: 'BS11',
    category: JikkyoChannelCategory.bs,
    serviceId: 211,
  ),
  JikkyoChannelDef(
    id: 'jk222',
    name: 'BS12',
    category: JikkyoChannelCategory.bs,
    serviceId: 222,
  ),
  JikkyoChannelDef(
    id: 'jk236',
    name: 'BSアニマックス',
    category: JikkyoChannelCategory.bs,
    serviceId: 236,
  ),
  JikkyoChannelDef(
    id: 'jk252',
    name: 'WOWOW PLUS',
    category: JikkyoChannelCategory.bs,
    serviceId: 252,
  ),
  JikkyoChannelDef(
    id: 'jk260',
    name: 'J:COM BS',
    category: JikkyoChannelCategory.bs,
    serviceId: 260,
  ),
  JikkyoChannelDef(
    id: 'jk263',
    name: 'BSJapanext',
    category: JikkyoChannelCategory.bs,
    serviceId: 263,
  ),
  JikkyoChannelDef(
    id: 'jk265',
    name: 'BSよしもと',
    category: JikkyoChannelCategory.bs,
    serviceId: 265,
  ),
  // CS
  JikkyoChannelDef(
    id: 'jk333',
    name: 'AT-X',
    category: JikkyoChannelCategory.cs,
    serviceId: 333,
  ),
  // Special
  JikkyoChannelDef(
    id: 'jk991',
    name: 'WBC特設',
    category: JikkyoChannelCategory.special,
    serviceId: 991,
  ),
  JikkyoChannelDef(
    id: 'jk992',
    name: 'W杯特設',
    category: JikkyoChannelCategory.special,
    serviceId: 992,
  ),
];

final Map<String, JikkyoChannelDef> _channelByIdMap = {
  for (final ch in kJikkyoChannels) ch.id: ch,
};

JikkyoChannelDef? jikkyoChannelById(String? id) {
  if (id == null || id.isEmpty) return null;
  return _channelByIdMap[id];
}

enum JikkyoCommentPosition { naka, ue, shita }

enum JikkyoCommentSize { small, medium, big }

const Map<String, int> _nicoNamedColors = {
  'white': 0xFFFFFFFF,
  'red': 0xFFFF0000,
  'pink': 0xFFFF8080,
  'orange': 0xFFFFCC00,
  'yellow': 0xFFFFFF00,
  'green': 0xFF00FF00,
  'cyan': 0xFF00FFFF,
  'blue': 0xFF0000FF,
  'purple': 0xFFC000FF,
  'black': 0xFF000000,
  'white2': 0xFFCCCC99,
  'niconicowhite': 0xFFCCCC99,
  'red2': 0xFFCC0033,
  'truered': 0xFFCC0033,
  'pink2': 0xFFFF33CC,
  'orange2': 0xFFFF6600,
  'passionorange': 0xFFFF6600,
  'yellow2': 0xFF999900,
  'madyellow': 0xFF999900,
  'green2': 0xFF00CC66,
  'elementalgreen': 0xFF00CC66,
  'cyan2': 0xFF00CCCC,
  'blue2': 0xFF3399FF,
  'marineblue': 0xFF3399FF,
  'purple2': 0xFF6633CC,
  'nobleviolet': 0xFF6633CC,
  'black2': 0xFF666666,
};

({JikkyoCommentPosition position, JikkyoCommentSize size, int colorValue})
parseJikkyoMailCommand(String? mail) {
  var pos = JikkyoCommentPosition.naka;
  var size = JikkyoCommentSize.medium;
  var color = 0xFFFFFFFF;
  if (mail == null || mail.trim().isEmpty) {
    return (position: pos, size: size, colorValue: color);
  }
  for (final rawToken in mail.trim().split(RegExp(r'\s+'))) {
    final token = rawToken.toLowerCase();
    switch (token) {
      case 'ue':
        pos = JikkyoCommentPosition.ue;
      case 'shita':
        pos = JikkyoCommentPosition.shita;
      case 'naka':
        pos = JikkyoCommentPosition.naka;
      case 'big':
        size = JikkyoCommentSize.big;
      case 'small':
        size = JikkyoCommentSize.small;
      case 'medium':
        size = JikkyoCommentSize.medium;
      default:
        final named = _nicoNamedColors[token];
        if (named != null) {
          color = named;
        } else if (token.startsWith('#') && token.length == 7) {
          final parsed = int.tryParse(token.substring(1), radix: 16);
          if (parsed != null) {
            color = 0xFF000000 | parsed;
          }
        }
    }
  }
  return (position: pos, size: size, colorValue: color);
}

int? _parseFlexInt(Object? raw) {
  if (raw == null) return null;
  if (raw is int) return raw;
  if (raw is num) return raw.toInt();
  return int.tryParse(raw.toString().trim());
}

DateTime? _parseIsoDateTime(Object? raw) {
  if (raw == null) return null;
  final text = raw.toString().trim();
  if (text.isEmpty) return null;
  return DateTime.tryParse(text);
}

class JikkyoComment {
  const JikkyoComment({
    this.no,
    required this.timestampMs,
    required this.text,
    this.colorValue = 0xFFFFFFFF,
    this.position = JikkyoCommentPosition.naka,
    this.size = JikkyoCommentSize.medium,
  });

  final int? no;
  final int timestampMs;
  final String text;
  final int colorValue;
  final JikkyoCommentPosition position;
  final JikkyoCommentSize size;

  static JikkyoComment? fromChatJson(Map<String, dynamic> chat) {
    final rawContent = chat['content']?.toString() ?? '';
    final cleaned = rawContent.replaceAll('\r', '').trim();
    if (cleaned.isEmpty) return null;
    if (cleaned.startsWith('/')) {
      // Filter Niconico system/operator commands (/nicoad, /info, /gift, etc.).
      return null;
    }
    final dateSec = _parseFlexInt(chat['date']);
    if (dateSec == null || dateSec <= 0) return null;
    final dateUsec = _parseFlexInt(chat['date_usec']) ?? 0;
    final timestampMs = dateSec * 1000 + (dateUsec ~/ 1000);
    final no = _parseFlexInt(chat['no']);
    final mail = parseJikkyoMailCommand(chat['mail']?.toString());
    return JikkyoComment(
      no: no,
      timestampMs: timestampMs,
      text: cleaned,
      colorValue: mail.colorValue,
      position: mail.position,
      size: mail.size,
    );
  }
}

class JikkyoProgramInfo {
  const JikkyoProgramInfo({
    required this.title,
    this.startAt,
    this.endAt,
    this.durationSeconds,
    this.genre,
  });

  final String title;
  final DateTime? startAt;
  final DateTime? endAt;
  final int? durationSeconds;
  final String? genre;

  static JikkyoProgramInfo? fromJson(Map<String, dynamic>? json) {
    if (json == null) return null;
    final title = (json['title']?.toString() ?? '').trim();
    if (title.isEmpty) return null;
    return JikkyoProgramInfo(
      title: title,
      startAt: _parseIsoDateTime(json['start_at']),
      endAt: _parseIsoDateTime(json['end_at']),
      durationSeconds: _parseFlexInt(json['duration']),
      genre: json['genre']?.toString(),
    );
  }
}

class JikkyoChannelLiveInfo {
  const JikkyoChannelLiveInfo({
    required this.id,
    required this.name,
    this.programPresent,
    this.programFollowing,
    this.jikkyoForce = 0,
  });

  final String id;
  final String name;
  final JikkyoProgramInfo? programPresent;
  final JikkyoProgramInfo? programFollowing;
  final int jikkyoForce;

  static JikkyoChannelLiveInfo? fromJson(Map<String, dynamic> json) {
    final id = (json['id']?.toString() ?? '').trim();
    if (id.isEmpty) return null;
    final name = (json['name']?.toString() ?? id).trim();
    var force = 0;
    final threads = json['threads'];
    if (threads is List) {
      for (final item in threads) {
        if (item is Map<String, dynamic>) {
          final status = item['status']?.toString();
          final f = _parseFlexInt(item['jikkyo_force']) ?? 0;
          if (status == 'ACTIVE' || force == 0) {
            force = f;
            if (status == 'ACTIVE') break;
          }
        }
      }
    }
    final presentRaw = json['program_present'];
    final followingRaw = json['program_following'];
    return JikkyoChannelLiveInfo(
      id: id,
      name: name,
      programPresent: presentRaw is Map
          ? JikkyoProgramInfo.fromJson(presentRaw.cast<String, dynamic>())
          : null,
      programFollowing: followingRaw is Map
          ? JikkyoProgramInfo.fromJson(followingRaw.cast<String, dynamic>())
          : null,
      jikkyoForce: force,
    );
  }
}

enum JikkyoTextSizePreset {
  small('小', 0.052),
  normal('標準', 0.066),
  large('大', 0.082);

  const JikkyoTextSizePreset(this.label, this.viewportHeightFactor);
  final String label;
  final double viewportHeightFactor;
}

enum JikkyoSpeedPreset {
  slow('遅い', 6.5),
  normal('標準', 5.0),
  fast('速い', 3.8);

  const JikkyoSpeedPreset(this.label, this.durationSeconds);
  final String label;
  final double durationSeconds;
}

const List<int> jikkyoOpacityOptions = [30, 50, 70, 80, 90, 100];
const List<int> jikkyoMaxConcurrentOptions = [20, 40, 60];
const List<int> jikkyoLiveDelayOptions = [0, 3, 5, 8, 10, 12, 15];

class JikkyoSettings {
  const JikkyoSettings({
    this.opacityPercent = 80,
    this.textSize = JikkyoTextSizePreset.normal,
    this.speed = JikkyoSpeedPreset.normal,
    this.maxConcurrentComments = 40,
    this.avoidSubtitleArea = false,
    this.liveDelaySeconds = 5,
    this.forceWhiteText = false,
    this.hideFixedComments = false,
    this.ngWords = const [],
    this.channelOverrides = const {},
    this.channelOverrideLabels = const {},
  });

  static const defaults = JikkyoSettings();

  final int opacityPercent;
  final JikkyoTextSizePreset textSize;
  final JikkyoSpeedPreset speed;
  final int maxConcurrentComments;
  final bool avoidSubtitleArea;
  final int liveDelaySeconds;
  final bool forceWhiteText;
  final bool hideFixedComments;
  final List<String> ngWords;
  final Map<String, String> channelOverrides;
  final Map<String, String> channelOverrideLabels;

  bool get hasActiveFilters =>
      forceWhiteText || hideFixedComments || ngWords.isNotEmpty;

  String get summaryLabel {
    final base =
        '文字${textSize.label}・透過$opacityPercent%・速度${speed.label}・遅延+$liveDelaySeconds秒';
    return hasActiveFilters ? '$base・フィルタ' : base;
  }

  static String _foldForFilter(String raw) {
    final sb = StringBuffer();
    for (final rune in raw.runes) {
      if (rune == 0x3000) {
        sb.writeCharCode(0x20);
      } else if (rune >= 0xFF01 && rune <= 0xFF5E) {
        sb.writeCharCode(rune - 0xFEE0);
      } else {
        sb.writeCharCode(rune);
      }
    }
    return sb.toString().toLowerCase();
  }

  bool matchesFilter(JikkyoComment comment) {
    if (hideFixedComments && comment.position != JikkyoCommentPosition.naka) {
      return false;
    }
    if (ngWords.isNotEmpty) {
      final foldedText = _foldForFilter(comment.text);
      for (final rawWord in ngWords) {
        final w = _foldForFilter(rawWord).trim();
        if (w.isNotEmpty && foldedText.contains(w)) {
          return false;
        }
      }
    }
    return true;
  }

  JikkyoSettings copyWith({
    int? opacityPercent,
    JikkyoTextSizePreset? textSize,
    JikkyoSpeedPreset? speed,
    int? maxConcurrentComments,
    bool? avoidSubtitleArea,
    int? liveDelaySeconds,
    bool? forceWhiteText,
    bool? hideFixedComments,
    List<String>? ngWords,
    Map<String, String>? channelOverrides,
    Map<String, String>? channelOverrideLabels,
  }) {
    return JikkyoSettings(
      opacityPercent: opacityPercent ?? this.opacityPercent,
      textSize: textSize ?? this.textSize,
      speed: speed ?? this.speed,
      maxConcurrentComments:
          maxConcurrentComments ?? this.maxConcurrentComments,
      avoidSubtitleArea: avoidSubtitleArea ?? this.avoidSubtitleArea,
      liveDelaySeconds: liveDelaySeconds ?? this.liveDelaySeconds,
      forceWhiteText: forceWhiteText ?? this.forceWhiteText,
      hideFixedComments: hideFixedComments ?? this.hideFixedComments,
      ngWords: ngWords ?? this.ngWords,
      channelOverrides: channelOverrides ?? this.channelOverrides,
      channelOverrideLabels:
          channelOverrideLabels ?? this.channelOverrideLabels,
    );
  }

  JikkyoSettings withAddedNgWord(String raw) {
    final trimmed = raw.trim();
    if (trimmed.isEmpty) return this;
    final foldedNew = _foldForFilter(trimmed);
    for (final existing in ngWords) {
      if (_foldForFilter(existing) == foldedNew) return this;
    }
    final next = <String>[...ngWords, trimmed];
    if (next.length > 50) {
      next.removeRange(0, next.length - 50);
    }
    return copyWith(ngWords: List.unmodifiable(next));
  }

  JikkyoSettings withoutNgWord(String word) {
    final next = [
      for (final existing in ngWords)
        if (existing != word) existing,
    ];
    if (next.length == ngWords.length) return this;
    return copyWith(ngWords: List.unmodifiable(next));
  }

  JikkyoSettings withoutAllNgWords() =>
      ngWords.isEmpty ? this : copyWith(ngWords: const []);

  JikkyoSettings withChannelOverride(
    String key,
    String jkIdOrOff, {
    String? label,
  }) {
    final nextOverrides = Map<String, String>.from(channelOverrides);
    nextOverrides[key] = jkIdOrOff;
    final nextLabels = Map<String, String>.from(channelOverrideLabels);
    if (label != null && label.trim().isNotEmpty) {
      nextLabels[key] = label.trim();
    }
    return copyWith(
      channelOverrides: Map.unmodifiable(nextOverrides),
      channelOverrideLabels: Map.unmodifiable(nextLabels),
    );
  }

  JikkyoSettings withoutChannelOverride(String key) {
    final nextOverrides = Map<String, String>.from(channelOverrides)
      ..remove(key);
    final nextLabels = Map<String, String>.from(channelOverrideLabels)
      ..remove(key);
    return copyWith(
      channelOverrides: Map.unmodifiable(nextOverrides),
      channelOverrideLabels: Map.unmodifiable(nextLabels),
    );
  }

  JikkyoSettings withoutAllChannelOverrides() => copyWith(
    channelOverrides: const {},
    channelOverrideLabels: const {},
  );

  String toJsonString() => jsonEncode({
    'opacityPercent': opacityPercent,
    'textSize': textSize.name,
    'speed': speed.name,
    'maxConcurrentComments': maxConcurrentComments,
    'avoidSubtitleArea': avoidSubtitleArea,
    'liveDelaySeconds': liveDelaySeconds,
    'forceWhiteText': forceWhiteText,
    'hideFixedComments': hideFixedComments,
    'ngWords': ngWords,
    'channelOverrides': channelOverrides,
    'channelOverrideLabels': channelOverrideLabels,
  });

  static JikkyoSettings fromJsonString(String raw) {
    try {
      final decoded = jsonDecode(raw);
      if (decoded is! Map) return defaults;
      final opacity = _parseFlexInt(decoded['opacityPercent']);
      final maxConc = _parseFlexInt(decoded['maxConcurrentComments']);
      final delay = _parseFlexInt(decoded['liveDelaySeconds']);
      final sizeName = decoded['textSize']?.toString();
      final speedName = decoded['speed']?.toString();
      final avoidSub = decoded['avoidSubtitleArea'];
      final forceWhite = decoded['forceWhiteText'];
      final hideFixed = decoded['hideFixedComments'];

      final rawNgWords = decoded['ngWords'];
      final ngWords = <String>[];
      if (rawNgWords is List) {
        final seen = <String>{};
        for (final entry in rawNgWords) {
          final w = entry.toString().trim();
          if (w.isNotEmpty && seen.add(_foldForFilter(w))) {
            ngWords.add(w);
          }
        }
      }

      final rawOverrides = decoded['channelOverrides'];
      final overrides = <String, String>{};
      if (rawOverrides is Map) {
        for (final entry in rawOverrides.entries) {
          final k = entry.key.toString();
          final v = entry.value.toString();
          if (k.isNotEmpty &&
              (v == kJikkyoDisabledId || jikkyoChannelById(v) != null)) {
            overrides[k] = v;
          }
        }
      }

      final rawLabels = decoded['channelOverrideLabels'];
      final labels = <String, String>{};
      if (rawLabels is Map) {
        for (final entry in rawLabels.entries) {
          final k = entry.key.toString();
          final v = entry.value.toString().trim();
          if (k.isNotEmpty && v.isNotEmpty && overrides.containsKey(k)) {
            labels[k] = v;
          }
        }
      }

      return JikkyoSettings(
        opacityPercent: (opacity != null && jikkyoOpacityOptions.contains(opacity))
            ? opacity
            : defaults.opacityPercent,
        textSize: JikkyoTextSizePreset.values.firstWhere(
          (e) => e.name == sizeName,
          orElse: () => defaults.textSize,
        ),
        speed: JikkyoSpeedPreset.values.firstWhere(
          (e) => e.name == speedName,
          orElse: () => defaults.speed,
        ),
        maxConcurrentComments:
            (maxConc != null && jikkyoMaxConcurrentOptions.contains(maxConc))
            ? maxConc
            : defaults.maxConcurrentComments,
        avoidSubtitleArea: avoidSub is bool ? avoidSub : defaults.avoidSubtitleArea,
        liveDelaySeconds:
            (delay != null && jikkyoLiveDelayOptions.contains(delay))
            ? delay
            : defaults.liveDelaySeconds,
        forceWhiteText: forceWhite is bool ? forceWhite : defaults.forceWhiteText,
        hideFixedComments:
            hideFixed is bool ? hideFixed : defaults.hideFixedComments,
        ngWords: List.unmodifiable(ngWords),
        channelOverrides: Map.unmodifiable(overrides),
        channelOverrideLabels: Map.unmodifiable(labels),
      );
    } catch (_) {
      return defaults;
    }
  }

  static bool _mapEquals(Map<String, String> a, Map<String, String> b) {
    if (identical(a, b)) return true;
    if (a.length != b.length) return false;
    for (final entry in a.entries) {
      if (b[entry.key] != entry.value) return false;
    }
    return true;
  }

  static bool _listEquals(List<String> a, List<String> b) {
    if (identical(a, b)) return true;
    if (a.length != b.length) return false;
    for (var i = 0; i < a.length; i++) {
      if (a[i] != b[i]) return false;
    }
    return true;
  }

  @override
  bool operator ==(Object other) {
    return identical(this, other) ||
        (other is JikkyoSettings &&
            other.opacityPercent == opacityPercent &&
            other.textSize == textSize &&
            other.speed == speed &&
            other.maxConcurrentComments == maxConcurrentComments &&
            other.avoidSubtitleArea == avoidSubtitleArea &&
            other.liveDelaySeconds == liveDelaySeconds &&
            other.forceWhiteText == forceWhiteText &&
            other.hideFixedComments == hideFixedComments &&
            _listEquals(other.ngWords, ngWords) &&
            _mapEquals(other.channelOverrides, channelOverrides) &&
            _mapEquals(other.channelOverrideLabels, channelOverrideLabels));
  }

  @override
  int get hashCode => Object.hash(
    opacityPercent,
    textSize,
    speed,
    maxConcurrentComments,
    avoidSubtitleArea,
    liveDelaySeconds,
    forceWhiteText,
    hideFixedComments,
    Object.hashAll(ngWords),
    Object.hashAllUnordered(
      channelOverrides.entries.map((e) => '${e.key}=${e.value}'),
    ),
  );
}
