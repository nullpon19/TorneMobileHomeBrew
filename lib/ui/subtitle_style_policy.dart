/// Subtitle styling presets, ARIB STD-B24 symbol normalization, ASS caption
/// parser, and overlapping-event window tracker for Fire TV playback.
library;

import 'dart:convert' show jsonDecode, jsonEncode;
import 'dart:math' as math;

import 'package:material_ui/material_ui.dart';

import '../core/dtcp/arib_ts_caption_tap.dart';

/// Three preset text-size steps tuned for Fire TV 10-foot viewing.
enum SubtitleSizePreset {
  small('小'),
  medium('中（標準）'),
  large('大');

  const SubtitleSizePreset(this.label);
  final String label;
}

/// Computes the subtitle font size in logical pixels for [viewportHeight].
double resolveSubtitleFontSize(
  SubtitleSizePreset preset,
  double viewportHeight, {
  double minSize = 14.0,
}) {
  final safeHeight = viewportHeight.isFinite && viewportHeight > 0
      ? viewportHeight
      : 540.0;
  final factor = switch (preset) {
    SubtitleSizePreset.small => 0.038,
    SubtitleSizePreset.medium => 0.048,
    SubtitleSizePreset.large => 0.060,
  };
  return (safeHeight * factor).clamp(minSize, 64.0).toDouble();
}

/// Five selectable font families combining Fire TV OS fonts and bundled fonts.
enum SubtitleFontFamily {
  gothic(
    label: 'ゴシック体',
    fontFamily: 'sans-serif',
    fontWeight: FontWeight.w400,
    fontFamilyFallback: ['NotoSansCJK', 'sans-serif'],
  ),
  gothicBold(
    label: '太字ゴシック',
    fontFamily: 'sans-serif',
    fontWeight: FontWeight.w700,
    fontFamilyFallback: ['NotoSansCJK', 'sans-serif'],
  ),
  lineSeedJp(
    label: 'LINE Seed JP',
    fontFamily: 'LINESeedJP',
    fontWeight: FontWeight.w400,
    fontFamilyFallback: ['NotoSansCJK', 'sans-serif'],
  ),
  kosugiMaru(
    label: '丸ゴシック (Kosugi Maru)',
    fontFamily: 'KosugiMaru',
    fontWeight: FontWeight.w400,
    fontFamilyFallback: ['NotoSansCJK', 'sans-serif'],
  ),
  mincho(
    label: '明朝体',
    fontFamily: 'serif',
    fontWeight: FontWeight.w400,
    fontFamilyFallback: ['NotoSerifCJK', 'serif', 'NotoSansCJK', 'sans-serif'],
  );

  const SubtitleFontFamily({
    required this.label,
    required this.fontFamily,
    required this.fontWeight,
    required this.fontFamilyFallback,
  });

  final String label;
  final String fontFamily;
  final FontWeight fontWeight;
  final List<String> fontFamilyFallback;
}

/// Text outline thickness choices for subtitles over video.
enum SubtitleEdgeStyle {
  none('なし'),
  thin('細め（標準）'),
  thick('太め');

  const SubtitleEdgeStyle(this.label);
  final String label;
}

/// Computes the stroke width in logical pixels for [edge] at [fontSize].
double resolveSubtitleEdgeWidth(SubtitleEdgeStyle edge, double fontSize) {
  switch (edge) {
    case SubtitleEdgeStyle.none:
      return 0.0;
    case SubtitleEdgeStyle.thin:
      return (fontSize * 0.11).clamp(2.0, 5.0).toDouble();
    case SubtitleEdgeStyle.thick:
      return (fontSize * 0.18).clamp(3.5, 8.5).toDouble();
  }
}

/// Preset subtitle background box base colors.
enum SubtitleBackgroundColorPreset {
  black('黒', Color(0xFF000000)),
  navy('濃紺', Color(0xFF0D1B2A)),
  darkGray('濃グレー', Color(0xFF262626));

  const SubtitleBackgroundColorPreset(this.label, this.color);
  final String label;
  final Color color;
}

/// Allowed subtitle background opacity percentages (`0` = no background box).
const List<int> subtitleBackgroundOpacityOptions = [0, 40, 65, 85, 100];

/// Human-readable Japanese label for [percent] background opacity.
String subtitleBackgroundOpacityLabel(int percent) {
  switch (percent) {
    case 0:
      return 'なし (0%)';
    case 40:
      return '薄め (40%)';
    case 65:
      return '標準 (65%)';
    case 85:
      return '濃いめ (85%)';
    case 100:
      return '不透明 (100%)';
    default:
      return '$percent%';
  }
}

/// Fallback timeout when a broadcast caption stream misses its clear packet.
const Duration subtitleStaleTimeout = Duration(seconds: 12);

/// Immutable subtitle visual preferences persisted on Fire TV.
class SubtitleSettings {
  const SubtitleSettings({
    this.size = SubtitleSizePreset.medium,
    this.font = SubtitleFontFamily.gothicBold,
    this.edge = SubtitleEdgeStyle.thin,
    this.backgroundColor = SubtitleBackgroundColorPreset.black,
    this.backgroundOpacityPercent = 65,
  });

  static const SubtitleSettings defaults = SubtitleSettings();

  final SubtitleSizePreset size;
  final SubtitleFontFamily font;
  final SubtitleEdgeStyle edge;
  final SubtitleBackgroundColorPreset backgroundColor;
  final int backgroundOpacityPercent;

  Color get effectiveBackgroundColor {
    if (backgroundOpacityPercent <= 0) return Colors.transparent;
    final alpha = backgroundOpacityPercent.clamp(0, 100) / 100.0;
    return backgroundColor.color.withValues(alpha: alpha);
  }

  String get summaryLabel =>
      '${size.label}・${font.label}・縁取り${edge.label}・'
      '背景${backgroundColor.label}(${subtitleBackgroundOpacityLabel(backgroundOpacityPercent)})';

  SubtitleSettings copyWith({
    SubtitleSizePreset? size,
    SubtitleFontFamily? font,
    SubtitleEdgeStyle? edge,
    SubtitleBackgroundColorPreset? backgroundColor,
    int? backgroundOpacityPercent,
  }) => SubtitleSettings(
    size: size ?? this.size,
    font: font ?? this.font,
    edge: edge ?? this.edge,
    backgroundColor: backgroundColor ?? this.backgroundColor,
    backgroundOpacityPercent:
        backgroundOpacityPercent ?? this.backgroundOpacityPercent,
  );

  String toJsonString() => jsonEncode({
    'size': size.name,
    'font': font.name,
    'edge': edge.name,
    'bgColor': backgroundColor.name,
    'bgOpacity': backgroundOpacityPercent,
  });

  static SubtitleSettings fromJsonString(String? raw) {
    if (raw == null || raw.isEmpty) return defaults;
    try {
      final decoded = jsonDecode(raw);
      if (decoded is! Map) return defaults;
      final size = _enumByName(
        SubtitleSizePreset.values,
        decoded['size'] as String?,
        defaults.size,
      );
      final font = _enumByName(
        SubtitleFontFamily.values,
        decoded['font'] as String?,
        defaults.font,
      );
      final edge = _enumByName(
        SubtitleEdgeStyle.values,
        decoded['edge'] as String?,
        defaults.edge,
      );
      final bgColor = _enumByName(
        SubtitleBackgroundColorPreset.values,
        decoded['bgColor'] as String?,
        defaults.backgroundColor,
      );
      final rawOpacity = decoded['bgOpacity'];
      final bgOpacity =
          rawOpacity is int &&
              subtitleBackgroundOpacityOptions.contains(rawOpacity)
          ? rawOpacity
          : defaults.backgroundOpacityPercent;
      return SubtitleSettings(
        size: size,
        font: font,
        edge: edge,
        backgroundColor: bgColor,
        backgroundOpacityPercent: bgOpacity,
      );
    } catch (_) {
      return defaults;
    }
  }

  @override
  bool operator ==(Object other) =>
      identical(this, other) ||
      other is SubtitleSettings &&
          size == other.size &&
          font == other.font &&
          edge == other.edge &&
          backgroundColor == other.backgroundColor &&
          backgroundOpacityPercent == other.backgroundOpacityPercent;

  @override
  int get hashCode => Object.hash(
    size,
    font,
    edge,
    backgroundColor,
    backgroundOpacityPercent,
  );
}

T _enumByName<T extends Enum>(List<T> values, String? name, T fallback) {
  if (name == null) return fallback;
  for (final value in values) {
    if (value.name == name) return value;
  }
  return fallback;
}

const Map<int, String> _aribSymbolReplacements = {
  // Broadcast/media enclosed codes
  0x1F14A: '[HV]',
  0x1F14B: '[MV]',
  0x1F14C: '[SD]',
  0x1F14D: '[SS]',
  0x1F14E: '[PPV]',
  0x1F14F: '[WC]',
  // ARIB enclosed kanji blocks (U+1F210 - U+1F23A)
  0x1F210: '[手]',
  0x1F211: '[字]',
  0x1F212: '[双]',
  0x1F213: '[デ]',
  0x1F214: '[二]',
  0x1F215: '[多]',
  0x1F216: '[解]',
  0x1F217: '[天]',
  0x1F218: '[交]',
  0x1F219: '[映]',
  0x1F21A: '[無]',
  0x1F21B: '[料]',
  0x1F21C: '[前]',
  0x1F21D: '[後]',
  0x1F21E: '[再]',
  0x1F21F: '[新]',
  0x1F220: '[初]',
  0x1F221: '[終]',
  0x1F222: '[生]',
  0x1F223: '[販]',
  0x1F224: '[声]',
  0x1F225: '[吹]',
  0x1F226: '[演]',
  0x1F227: '[投]',
  0x1F228: '[捕]',
  0x1F229: '[一]',
  0x1F22A: '[三]',
  0x1F22B: '[遊]',
  0x1F22C: '[左]',
  0x1F22D: '[中]',
  0x1F22E: '[右]',
  0x1F22F: '[指]',
  0x1F230: '[走]',
  0x1F231: '[打]',
  0x1F232: '[禁]',
  0x1F233: '[空]',
  0x1F234: '[合]',
  0x1F235: '[満]',
  0x1F236: '[有]',
  0x1F237: '[月]',
  0x1F238: '[申]',
  0x1F239: '[割]',
  0x1F23A: '[営]',
  // ARIB baseball symbols (U+1F240 - U+1F248)
  0x1F240: '〔本〕',
  0x1F241: '〔三〕',
  0x1F242: '〔二〕',
  0x1F243: '〔安〕',
  0x1F244: '〔点〕',
  0x1F245: '〔打〕',
  0x1F246: '〔盗〕',
  0x1F247: '〔勝〕',
  0x1F248: '〔敗〕',
  // Heavy emoji-style arrows -> flat crisp typographic arrows in JP fonts
  0x27A1: '→',
  0x2B05: '←',
  0x2B06: '↑',
  0x2B07: '↓',
};

/// Normalizes ARIB STD-B24 caption symbols, heavy arrows, replacement chars,
/// and Private Use Area DRCS remnants so captions avoid tofu/garbled metrics.
String normalizeAribSubtitleSymbols(String input) {
  if (input.isEmpty) return input;
  final out = StringBuffer();
  for (final rune in input.runes) {
    final mapped = _aribSymbolReplacements[rune];
    if (mapped != null) {
      out.write(mapped);
      continue;
    }
    // Strip variation selectors, zero-width formatting chars, and U+FFFD.
    if (rune == 0xFE0E ||
        rune == 0xFE0F ||
        rune == 0x200B ||
        rune == 0x200C ||
        rune == 0x200D ||
        rune == 0xFEFF ||
        rune == 0xFFFD) {
      continue;
    }
    // Private Use Area (Android libaribb24 lacks libpng DRCS rendering).
    if (rune >= 0xE000 && rune <= 0xF8FF) {
      out.write('〓');
      continue;
    }
    // Drop non-whitespace C0/C1 control characters.
    if ((rune < 0x20 && rune != 0x0A && rune != 0x09) ||
        (rune >= 0x7F && rune <= 0x9F)) {
      continue;
    }
    out.writeCharCode(rune);
  }
  return out.toString();
}

/// Extracts `PlayResX` and `PlayResY` from mpv's `sub-ass-extradata` header.
({double width, double height}) parseAssPlayRes(String? extradata) {
  var width = 960.0;
  var height = 540.0;
  if (extradata == null || extradata.isEmpty) {
    return (width: width, height: height);
  }
  final matchX = RegExp(r'PlayResX:\s*(\d+)').firstMatch(extradata);
  final matchY = RegExp(r'PlayResY:\s*(\d+)').firstMatch(extradata);
  final parsedX = matchX == null ? null : double.tryParse(matchX.group(1)!);
  final parsedY = matchY == null ? null : double.tryParse(matchY.group(1)!);
  if (parsedX != null && parsedX > 0) width = parsedX;
  if (parsedY != null && parsedY > 0) height = parsedY;
  return (width: width, height: height);
}

/// One color/scale run inside a parsed [SubtitleCue].
class SubtitleStyledSpan {
  const SubtitleStyledSpan({
    required this.text,
    this.color = Colors.white,
    this.scale = 1.0,
  });

  final String text;
  final Color color;
  final double scale;
}

/// Positioned, color-annotated subtitle cue decoded from ARIB ASS or plain text.
class SubtitleCue {
  const SubtitleCue({
    required this.spans,
    this.normalizedX,
    this.normalizedY,
    this.alignment = 2,
  });

  final List<SubtitleStyledSpan> spans;
  final double? normalizedX;
  final double? normalizedY;
  final int alignment;

  String get plainText => [for (final s in spans) s.text].join();

  String get dedupeKey {
    final posKey =
        '${normalizedX?.toStringAsFixed(2) ?? '-'},${normalizedY?.toStringAsFixed(2) ?? '-'},$alignment';
    return '$posKey|${plainText.trim()}';
  }
}

final RegExp _assPosPattern = RegExp(
  r'\\pos\(\s*([+-]?\d+(?:\.\d+)?)\s*,\s*([+-]?\d+(?:\.\d+)?)\s*\)',
);
final RegExp _assAnPattern = RegExp(r'\\an([1-9])');
final RegExp _assColorPattern = RegExp(r'\\(?:1)?c&H([0-9A-Fa-f]{1,6})&?');
final RegExp _assFontSizePattern = RegExp(r'\\fs(\d+(?:\.\d+)?)?');
final RegExp _assDrawPattern = RegExp(r'\\p(\d+)');
final RegExp _assResetPattern = RegExp(r'\\r(?![A-Za-z0-9])');

Color? _parseAssColorHex(String rawHex) {
  final padded = rawHex.padLeft(6, '0');
  if (padded.length < 6) return null;
  final b = int.tryParse(padded.substring(0, 2), radix: 16);
  final g = int.tryParse(padded.substring(2, 4), radix: 16);
  final r = int.tryParse(padded.substring(4, 6), radix: 16);
  if (b == null || g == null || r == null) return null;
  return Color.fromARGB(255, r, g, b);
}

String _stripDialogueHeaderIfPresent(String line) {
  if (!line.startsWith('Dialogue:')) return line;
  var commaCount = 0;
  for (var i = 0; i < line.length; i++) {
    if (line.codeUnitAt(i) == 44) {
      commaCount++;
      if (commaCount == 9) {
        return line.substring(i + 1);
      }
    }
  }
  return line;
}

/// Parses ARIB ASS markup (`sub-text-ass`) into positioned, speaker-colored cues.
List<SubtitleCue> parseAribAssSubtitle(
  String rawAss, {
  double playResWidth = 960.0,
  double playResHeight = 540.0,
}) {
  if (rawAss.trim().isEmpty) return const [];
  final resW = playResWidth > 0 ? playResWidth : 960.0;
  final resH = playResHeight > 0 ? playResHeight : 540.0;

  final parsedCues = <SubtitleCue>[];
  final lines = rawAss.split(RegExp(r'\r?\n'));
  for (final rawLine in lines) {
    final trimmedLine = rawLine.trim();
    if (trimmedLine.isEmpty) continue;
    final payload = _stripDialogueHeaderIfPresent(trimmedLine);

    final spans = <SubtitleStyledSpan>[];
    var currentColor = Colors.white;
    var currentScale = 1.0;
    double? normX;
    double? normY;
    var alignment = 2;
    var drawingMode = false;

    void appendText(String rawSegment) {
      if (drawingMode || rawSegment.isEmpty) return;
      final withBreaks = rawSegment
          .replaceAll(r'\N', '\n')
          .replaceAll(r'\n', '\n')
          .replaceAll(r'\h', '\u00A0');
      final normalized = normalizeAribSubtitleSymbols(withBreaks);
      if (normalized.isEmpty) return;
      if (spans.isNotEmpty &&
          spans.last.color == currentColor &&
          spans.last.scale == currentScale) {
        final prev = spans.removeLast();
        spans.add(
          SubtitleStyledSpan(
            text: prev.text + normalized,
            color: prev.color,
            scale: prev.scale,
          ),
        );
      } else {
        spans.add(
          SubtitleStyledSpan(
            text: normalized,
            color: currentColor,
            scale: currentScale,
          ),
        );
      }
    }

    var cursor = 0;
    while (cursor < payload.length) {
      final openBrace = payload.indexOf('{', cursor);
      if (openBrace < 0) {
        appendText(payload.substring(cursor));
        break;
      }
      if (openBrace > cursor) {
        appendText(payload.substring(cursor, openBrace));
      }
      final closeBrace = payload.indexOf('}', openBrace + 1);
      if (closeBrace < 0) {
        final tail = payload.substring(openBrace);
        // Drop truncated ASS override tails at mpv's 500-byte text buffer cut.
        if (!tail.startsWith(r'{\')) {
          appendText(tail);
        }
        break;
      }
      final tagBlock = payload.substring(openBrace + 1, closeBrace);

      final drawMatch = _assDrawPattern.firstMatch(tagBlock);
      if (drawMatch != null) {
        final level = int.tryParse(drawMatch.group(1)!) ?? 0;
        drawingMode = level > 0;
      }

      if (_assResetPattern.hasMatch(tagBlock)) {
        currentColor = Colors.white;
        currentScale = 1.0;
      }

      final posMatch = _assPosPattern.firstMatch(tagBlock);
      if (posMatch != null) {
        final x = double.tryParse(posMatch.group(1)!);
        final y = double.tryParse(posMatch.group(2)!);
        if (x != null && y != null && x.isFinite && y.isFinite) {
          normX = (x / resW).clamp(0.02, 0.98).toDouble();
          normY = (y / resH).clamp(0.05, 0.96).toDouble();
        }
      }

      final anMatch = _assAnPattern.firstMatch(tagBlock);
      if (anMatch != null) {
        alignment = int.tryParse(anMatch.group(1)!) ?? alignment;
      }

      for (final colorMatch in _assColorPattern.allMatches(tagBlock)) {
        final parsedColor = _parseAssColorHex(colorMatch.group(1)!);
        if (parsedColor != null) {
          currentColor = parsedColor;
        }
      }

      final fsMatch = _assFontSizePattern.firstMatch(tagBlock);
      if (fsMatch != null) {
        final rawSize = fsMatch.group(1);
        if (rawSize == null) {
          currentScale = 1.0;
        } else {
          final parsedSize = double.tryParse(rawSize);
          if (parsedSize != null && parsedSize <= 22.0) {
            currentScale = 0.65;
          } else {
            currentScale = 1.0;
          }
        }
      }

      cursor = closeBrace + 1;
    }

    final text = [for (final s in spans) s.text].join().trim();
    if (text.isEmpty) continue;
    parsedCues.add(
      SubtitleCue(
        spans: spans,
        normalizedX: normX,
        normalizedY: normY,
        alignment: alignment,
      ),
    );
  }

  if (parsedCues.length <= 1) return parsedCues;

  // Merge segments placed on the exact same vertical line so color switches
  // across X never collide when scaled up.
  final merged = <SubtitleCue>[];
  for (final cue in parsedCues) {
    if (cue.normalizedY == null) {
      merged.add(cue);
      continue;
    }
    final matchIndex = merged.indexWhere(
      (existing) =>
          existing.normalizedY != null &&
          (existing.normalizedY! - cue.normalizedY!).abs() <= 0.03,
    );
    if (matchIndex < 0) {
      merged.add(cue);
      continue;
    }
    final existing = merged[matchIndex];
    final existingBefore =
        (existing.normalizedX ?? 0.5) <= (cue.normalizedX ?? 0.5);
    final orderedSpans = existingBefore
        ? [...existing.spans, ...cue.spans]
        : [...cue.spans, ...existing.spans];
    final combinedX = existingBefore
        ? (existing.normalizedX ?? cue.normalizedX)
        : (cue.normalizedX ?? existing.normalizedX);
    merged[matchIndex] = SubtitleCue(
      spans: orderedSpans,
      normalizedX: combinedX,
      normalizedY: existing.normalizedY,
      alignment: existingBefore ? existing.alignment : cue.alignment,
    );
  }
  return merged;
}

String _compactCompareText(String text) =>
    text.replaceAll(RegExp(r'[\s\u00A0]+'), '');

/// Splits any [cue] containing explicit `\n` breaks into individual single-line
/// cues while preserving span colors/scales and coordinates.
List<SubtitleCue> splitSubtitleCueLines(SubtitleCue cue) {
  final hasBreak = cue.spans.any((s) => s.text.contains('\n'));
  if (!hasBreak) return [cue];

  final lines = <List<SubtitleStyledSpan>>[];
  var currentLine = <SubtitleStyledSpan>[];

  void flushLine() {
    final text = [for (final s in currentLine) s.text].join().trim();
    if (text.isNotEmpty) {
      lines.add(currentLine);
    }
    currentLine = <SubtitleStyledSpan>[];
  }

  for (final span in cue.spans) {
    final parts = span.text.split('\n');
    for (var i = 0; i < parts.length; i++) {
      if (i > 0) flushLine();
      if (parts[i].isNotEmpty) {
        currentLine.add(
          SubtitleStyledSpan(
            text: parts[i],
            color: span.color,
            scale: span.scale,
          ),
        );
      }
    }
  }
  flushLine();

  if (lines.isEmpty) return const [];
  if (lines.length == 1) {
    return [
      SubtitleCue(
        spans: lines.single,
        normalizedX: cue.normalizedX,
        normalizedY: cue.normalizedY,
        alignment: cue.alignment,
      ),
    ];
  }

  return [
    for (var idx = 0; idx < lines.length; idx++)
      SubtitleCue(
        spans: lines[idx],
        normalizedX: cue.normalizedX,
        normalizedY: cue.normalizedY == null
            ? null
            : (cue.normalizedY! + idx * 0.055).clamp(0.02, 0.98).toDouble(),
        alignment: cue.alignment,
      ),
  ];
}

/// Resolves raw active cues from [rawAss] and [plainLines] without applying the
/// rolling deduplication window yet.
List<SubtitleCue> resolveRawSubtitleCues({
  required String rawAss,
  required List<String> plainLines,
  double playResWidth = 960.0,
  double playResHeight = 540.0,
}) {
  final cleanedPlain = [
    for (final raw in plainLines)
      if (normalizeAribSubtitleSymbols(raw).trim().isNotEmpty)
        normalizeAribSubtitleSymbols(raw).trim(),
  ];
  if (cleanedPlain.isEmpty) return const [];

  if (rawAss.trim().isNotEmpty) {
    final parsedAss = parseAribAssSubtitle(
      rawAss,
      playResWidth: playResWidth,
      playResHeight: playResHeight,
    );
    if (parsedAss.isNotEmpty) {
      final assCompact = _compactCompareText(
        [for (final c in parsedAss) c.plainText].join(),
      );
      final plainCompact = _compactCompareText(cleanedPlain.join());
      if (assCompact.isNotEmpty &&
          plainCompact.isNotEmpty &&
          (assCompact == plainCompact ||
              assCompact.contains(plainCompact) ||
              plainCompact.contains(assCompact))) {
        return [
          for (final cue in parsedAss) ...splitSubtitleCueLines(cue),
        ];
      }
    }
  }

  return [
    for (final line in cleanedPlain)
      SubtitleCue(spans: [SubtitleStyledSpan(text: line)]),
  ];
}

/// Computes a natural auto-clear timeout based on caption character count so
/// streams with missing clear packets never linger indefinitely.
Duration computeSubtitleAutoClearDuration(List<SubtitleCue> cues) {
  var totalChars = 0;
  for (final cue in cues) {
    totalChars += _compactCompareText(cue.plainText).length;
  }
  final seconds = (3.5 + totalChars * 0.14).clamp(5.5, 9.5);
  return Duration(milliseconds: (seconds * 1000).round());
}

/// Filters overlapping ARIB events out of mpv's active subtitle buffer so old
/// dialogue lines do not stack up on screen across scene transitions.
class SubtitleActiveWindowTracker {
  Map<String, int> _previousIncomingCounts = const {};
  List<SubtitleCue> _activeCues = const [];
  Duration _lastArrivalPlaybackTime = Duration.zero;
  double? _lastSubStartSeconds;
  Duration _activeExpiryDuration = const Duration(seconds: 6);
  bool _initialized = false;

  void reset() {
    _previousIncomingCounts = const {};
    _activeCues = const [];
    _lastArrivalPlaybackTime = Duration.zero;
    _lastSubStartSeconds = null;
    _activeExpiryDuration = const Duration(seconds: 6);
    _initialized = false;
  }

  List<SubtitleCue> update(
    List<SubtitleCue> incomingCues,
    Duration playbackElapsed, {
    double? mpvSubStartSeconds,
  }) {
    if (incomingCues.isEmpty) {
      reset();
      return const [];
    }

    final incomingCounts = <String, int>{};
    for (final cue in incomingCues) {
      incomingCounts[cue.dedupeKey] = (incomingCounts[cue.dedupeKey] ?? 0) + 1;
    }

    if (!_initialized) {
      _initialized = true;
      _activeCues = incomingCues.length > 2
          ? incomingCues.sublist(incomingCues.length - 2)
          : List<SubtitleCue>.of(incomingCues);
      _previousIncomingCounts = incomingCounts;
      _lastArrivalPlaybackTime = playbackElapsed;
      _lastSubStartSeconds = mpvSubStartSeconds;
      _activeExpiryDuration = computeSubtitleAutoClearDuration(_activeCues);
      return List<SubtitleCue>.unmodifiable(_activeCues);
    }

    final seenCounts = <String, int>{};
    final newCues = <SubtitleCue>[];
    for (final cue in incomingCues) {
      final key = cue.dedupeKey;
      final seen = (seenCounts[key] ?? 0) + 1;
      seenCounts[key] = seen;
      if (seen > (_previousIncomingCounts[key] ?? 0)) {
        newCues.add(cue);
      }
    }

    if (newCues.isNotEmpty) {
      final delta = playbackElapsed - _lastArrivalPlaybackTime;
      final ptsAdvanced =
          mpvSubStartSeconds != null &&
          _lastSubStartSeconds != null &&
          wrapAwareAribPtsDelta(mpvSubStartSeconds, _lastSubStartSeconds!) >
              0.9;
      if (_activeCues.isEmpty ||
          delta > const Duration(milliseconds: 900) ||
          ptsAdvanced) {
        _activeCues = List<SubtitleCue>.of(newCues);
      } else {
        // Combine multi-cue burst packets from the same utterance while
        // replacing any progressive prefix lines superseded by [newCues].
        final merged = <SubtitleCue>[];
        for (final existing in _activeCues) {
          if ((incomingCounts[existing.dedupeKey] ?? 0) <= 0) continue;
          final existingText = existing.plainText.trim();
          final superseded = newCues.any((n) {
            final newText = n.plainText.trim();
            return (newText.length > existingText.length &&
                    newText.startsWith(existingText)) ||
                (newText == existingText &&
                    existing.normalizedY == null &&
                    n.normalizedY != null);
          });
          if (!superseded) {
            merged.add(existing);
          }
        }
        merged.addAll(newCues);
        if (merged.length > 3) {
          _activeCues = merged.sublist(merged.length - 3);
        } else {
          _activeCues = merged;
        }
      }
      _lastArrivalPlaybackTime = playbackElapsed;
      if (mpvSubStartSeconds != null) {
        _lastSubStartSeconds = mpvSubStartSeconds;
      }
      _activeExpiryDuration = computeSubtitleAutoClearDuration(_activeCues);
    } else if (_activeCues.isNotEmpty) {
      final remainingCounts = Map<String, int>.of(incomingCounts);
      final kept = <SubtitleCue>[];
      for (final existing in _activeCues) {
        final key = existing.dedupeKey;
        final available = remainingCounts[key] ?? 0;
        if (available > 0) {
          remainingCounts[key] = available - 1;
          kept.add(existing);
        }
      }
      _activeCues = kept;
      if (_activeCues.isNotEmpty &&
          playbackElapsed - _lastArrivalPlaybackTime >= _activeExpiryDuration) {
        _activeCues = const [];
      }
    }

    _previousIncomingCounts = incomingCounts;
    return List<SubtitleCue>.unmodifiable(_activeCues);
  }
}

/// Computes `a - b` across the 33-bit 90 kHz MPEG-TS PTS wrap boundary.
double wrapAwareAribPtsDelta(double a, double b) {
  const period = AribTsCaptionTap.ptsWrapSeconds;
  var d = a - b;
  if (d > period / 2) d -= period;
  if (d < -period / 2) d += period;
  return d;
}

/// Detects FFmpeg/libaribb24's accumulated `i_control_time` duration leak or
/// impending overflow of mpv's fixed 500-byte `last_text` buffer so the
/// subtitle decoder alone can be safely reset before desync occurs.
bool shouldResetAribSubtitleDecoder({
  double? subStartSeconds,
  double? subEndSeconds,
  double? playbackTimeSeconds,
  required int plainUtf8Bytes,
  required int assUtf8Bytes,
}) {
  if (plainUtf8Bytes >= 320 || assUtf8Bytes >= 420) {
    return true;
  }
  if (subStartSeconds != null && subEndSeconds != null) {
    final duration = subEndSeconds - subStartSeconds;
    // Ignore mpv UNKNOWN_DURATION (~24.8 days); target leaked aribb24 times.
    if (duration > 12.0 && duration < 86400.0) {
      return true;
    }
  }
  if (subStartSeconds != null &&
      playbackTimeSeconds != null &&
      (playbackTimeSeconds - subStartSeconds) > 14.0) {
    return true;
  }
  return false;
}

/// Resolves the constant PTS offset (`mpvTime - tsPts`) mapping MPEG-TS PTS
/// values to mpv's playback clock (`sub-start` / `playback-time`).
double? resolveAribPtsOffset({
  required List<AribCaptionLayoutEvent> events,
  required double mpvSubStartSeconds,
  double? firstStreamPtsSeconds,
  double? currentOffset,
}) {
  if (events.isEmpty) return currentOffset;

  bool hasMatchAt(double candidate, double tolerance) {
    for (final e in events) {
      if (e.isClearOnly) continue;
      if (wrapAwareAribPtsDelta(e.ptsSeconds + candidate, mpvSubStartSeconds)
              .abs() <=
          tolerance) {
        return true;
      }
    }
    return false;
  }

  if (currentOffset != null && hasMatchAt(currentOffset, 1.8)) {
    return currentOffset;
  }
  if (hasMatchAt(0.0, 1.5)) {
    return 0.0;
  }
  if (firstStreamPtsSeconds != null) {
    final zeroAnchored = -firstStreamPtsSeconds;
    if (hasMatchAt(zeroAnchored, 2.5)) {
      return zeroAnchored;
    }
  }
  for (var i = events.length - 1; i >= 0; i--) {
    final e = events[i];
    if (!e.isClearOnly) {
      return mpvSubStartSeconds - e.ptsSeconds;
    }
  }
  return currentOffset;
}

/// Finds the non-clear ARIB TS layout event closest to [mpvSubStartSeconds].
AribCaptionLayoutEvent? findMatchingAribLayoutEvent({
  required List<AribCaptionLayoutEvent> events,
  required double mpvSubStartSeconds,
  required double ptsOffset,
}) {
  AribCaptionLayoutEvent? best;
  var bestAbs = 1.5;
  for (final e in events) {
    if (e.isClearOnly) continue;
    final diff = wrapAwareAribPtsDelta(
      e.ptsSeconds + ptsOffset,
      mpvSubStartSeconds,
    ).abs();
    if (diff <= bestAbs) {
      bestAbs = diff;
      best = e;
    }
  }
  return best;
}

/// Returns `true` when broadcast `TIME+CS` or a standalone ARIB clear (`CS`)
/// packet indicates the active caption has expired on playback clock.
bool hasAribClearSinceCaption({
  required List<AribCaptionLayoutEvent> events,
  required double activeCaptionMpvPts,
  required double currentPlaybackMpvPts,
  required double ptsOffset,
  double? activeClearAfterSeconds,
}) {
  if (activeClearAfterSeconds != null &&
      activeClearAfterSeconds > 0 &&
      currentPlaybackMpvPts >= activeCaptionMpvPts + activeClearAfterSeconds) {
    return true;
  }
  for (final e in events) {
    if (!e.isClearOnly) continue;
    final mappedPts =
        activeCaptionMpvPts +
        wrapAwareAribPtsDelta(e.ptsSeconds + ptsOffset, activeCaptionMpvPts);
    if (mappedPts > activeCaptionMpvPts + 0.15 &&
        mappedPts <= currentPlaybackMpvPts + 0.10) {
      return true;
    }
  }
  return false;
}

/// Applies broadcast ARIB coordinates extracted from MPEG-TS onto decoded
/// [cues], splitting multiline cues into per-line positioned items.
List<SubtitleCue> applyAribLayoutToCues({
  required List<SubtitleCue> cues,
  required AribCaptionLayoutEvent layout,
}) {
  if (cues.isEmpty || layout.lines.isEmpty) return cues;
  final flatCues = [for (final c in cues) ...splitSubtitleCueLines(c)];
  if (flatCues.isEmpty) return cues;

  return [
    for (var i = 0; i < flatCues.length; i++)
      () {
        final lineIndex = flatCues.length == layout.lines.length
            ? i
            : ((i * layout.lines.length) ~/ flatCues.length).clamp(
                0,
                layout.lines.length - 1,
              );
        final line = layout.lines[lineIndex];
        return SubtitleCue(
          spans: flatCues[i].spans,
          normalizedX: line.normalizedX,
          normalizedY: line.normalizedY,
          alignment: 1,
        );
      }(),
  ];
}

/// Vertical tolerance when clustering nearby positioned cues so enlarged lines
/// stack inside a [Column] rather than overlapping vertically.
double resolveSubtitleBlockGapThreshold() => 0.14;

/// Keeps non-negative math dependency visible if needed by layout callers.
double clampNormalizedCoordinate(double value, double minValue, double maxValue) =>
    math.max(minValue, math.min(maxValue, value));
