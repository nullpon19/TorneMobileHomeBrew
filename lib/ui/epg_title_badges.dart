/// ARIB programme mark parsing & miniature EPG tile badges (Phase 41).
///
/// Separates broadcast attribute tags (`[字]`, `[二]`, `[多]`, `[解]`, `[デ]`,
/// `[再]`, `[生]`, etc.) into compact bordered badges placed beside the start
/// time, while turning premier/final markers (`[新]`, `[終]`, `[初]`) into
/// colored inline badges at the start of the cleaned title.
library;

import 'package:material_ui/material_ui.dart';

enum EpgInlineBadgeKind {
  shin('新'),
  shu('終'),
  hatsu('初');

  const EpgInlineBadgeKind(this.label);
  final String label;
}

class ParsedBroadcastTitle {
  const ParsedBroadcastTitle({
    required this.cleanTitle,
    this.inlineBadges = const [],
    this.attributeBadges = const [],
  });

  final String cleanTitle;
  final List<EpgInlineBadgeKind> inlineBadges;
  final List<String> attributeBadges;
}

const Map<String, EpgInlineBadgeKind> _inlineMarkerMap = {
  '新': EpgInlineBadgeKind.shin,
  '終': EpgInlineBadgeKind.shu,
  '初': EpgInlineBadgeKind.hatsu,
};

const Set<String> _knownAttributeMarks = {
  '字',
  '二',
  '多',
  '解',
  'デ',
  '再',
  '生',
  '無',
  '料',
  '手',
  '双',
  '吹',
  '声',
  '映',
  '前',
  '後',
  '天',
  '交',
  '販',
  'HV',
  'SD',
  'P',
  'W',
  'MV',
  'S',
  'SS',
  'B',
  'N',
  'PPV',
  'ほか',
};

final RegExp _markTokenPattern = RegExp(
  r'[\[［【(（]([^\]］】)）]{1,6})[\]］】)）]',
);

ParsedBroadcastTitle parseBroadcastTitleBadges(String rawTitle) {
  final inlineBadges = <EpgInlineBadgeKind>[];
  final attributeBadges = <String>[];
  final inlineSeen = <EpgInlineBadgeKind>{};
  final attrSeen = <String>{};

  final stripped = rawTitle.replaceAllMapped(_markTokenPattern, (match) {
    final full = match.group(0) ?? '';
    final inner = (match.group(1) ?? '').trim();
    final inlineKind = _inlineMarkerMap[inner];
    if (inlineKind != null) {
      if (inlineSeen.add(inlineKind)) {
        inlineBadges.add(inlineKind);
      }
      return '';
    }
    if (_knownAttributeMarks.contains(inner)) {
      if (attrSeen.add(inner)) {
        attributeBadges.add(inner);
      }
      return '';
    }
    return full;
  });

  final collapsed = stripped.replaceAll(RegExp(r'[\s\u3000]+'), ' ').trim();
  final cleanTitle = collapsed.isEmpty ? rawTitle.trim() : collapsed;
  return ParsedBroadcastTitle(
    cleanTitle: cleanTitle,
    inlineBadges: List.unmodifiable(inlineBadges),
    attributeBadges: List.unmodifiable(attributeBadges),
  );
}

class EpgAttributeMiniBadge extends StatelessWidget {
  const EpgAttributeMiniBadge({
    super.key,
    required this.label,
    this.inverted = false,
    this.isDark = false,
  });

  final String label;
  final bool inverted;
  final bool isDark;

  @override
  Widget build(BuildContext context) {
    final Color fgColor;
    final Color borderColor;
    final Color bgColor;
    if (inverted) {
      fgColor = Colors.white;
      borderColor = Colors.white70;
      bgColor = Colors.white.withValues(alpha: 0.14);
    } else if (label == '生') {
      fgColor = isDark ? const Color(0xFFFF8A80) : const Color(0xFFC62828);
      borderColor = fgColor.withValues(alpha: 0.75);
      bgColor = fgColor.withValues(alpha: 0.12);
    } else if (label == '再') {
      fgColor = isDark ? const Color(0xFF81D4FA) : const Color(0xFF0277BD);
      borderColor = fgColor.withValues(alpha: 0.70);
      bgColor = fgColor.withValues(alpha: 0.10);
    } else {
      fgColor = isDark ? Colors.white70 : Colors.black87;
      borderColor = isDark ? Colors.white38 : Colors.black38;
      bgColor = isDark
          ? Colors.white.withValues(alpha: 0.08)
          : Colors.black.withValues(alpha: 0.05);
    }

    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 3, vertical: 0.5),
      decoration: BoxDecoration(
        color: bgColor,
        borderRadius: BorderRadius.circular(2.5),
        border: Border.all(color: borderColor, width: 0.8),
      ),
      child: Text(
        label,
        maxLines: 1,
        style: TextStyle(
          color: fgColor,
          fontSize: 8.5,
          fontWeight: FontWeight.w700,
          height: 1.05,
        ),
      ),
    );
  }
}

class EpgInlineTitleBadge extends StatelessWidget {
  const EpgInlineTitleBadge({
    super.key,
    required this.kind,
    this.inverted = false,
    this.compact = false,
  });

  final EpgInlineBadgeKind kind;
  final bool inverted;
  final bool compact;

  @override
  Widget build(BuildContext context) {
    final Color accent = switch (kind) {
      EpgInlineBadgeKind.shin => const Color(0xFFE65100),
      EpgInlineBadgeKind.shu => const Color(0xFF1565C0),
      EpgInlineBadgeKind.hatsu => const Color(0xFF00695C),
    };
    final bgColor = inverted ? Colors.white : accent;
    final fgColor = inverted ? accent : Colors.white;
    return Container(
      padding: EdgeInsets.symmetric(
        horizontal: compact ? 3 : 4,
        vertical: compact ? 0.5 : 1,
      ),
      decoration: BoxDecoration(
        color: bgColor,
        borderRadius: BorderRadius.circular(3),
      ),
      child: Text(
        kind.label,
        maxLines: 1,
        style: TextStyle(
          color: fgColor,
          fontSize: compact ? 8.0 : 9.5,
          fontWeight: FontWeight.w800,
          height: 1.05,
        ),
      ),
    );
  }
}

class EpgFormattedTitleText extends StatelessWidget {
  const EpgFormattedTitleText({
    super.key,
    required this.parsed,
    this.style,
    this.maxLines = 1,
    this.inverted = false,
    this.compact = false,
  });

  final ParsedBroadcastTitle parsed;
  final TextStyle? style;
  final int maxLines;
  final bool inverted;
  final bool compact;

  @override
  Widget build(BuildContext context) {
    if (parsed.inlineBadges.isEmpty) {
      return Text(
        parsed.cleanTitle,
        style: style,
        maxLines: maxLines,
        overflow: TextOverflow.ellipsis,
      );
    }
    return Text.rich(
      TextSpan(
        style: style,
        children: [
          for (final kind in parsed.inlineBadges)
            WidgetSpan(
              alignment: PlaceholderAlignment.middle,
              child: Padding(
                padding: const EdgeInsets.only(right: 3),
                child: EpgInlineTitleBadge(
                  kind: kind,
                  inverted: inverted,
                  compact: compact,
                ),
              ),
            ),
          TextSpan(text: parsed.cleanTitle),
        ],
      ),
      maxLines: maxLines,
      overflow: TextOverflow.ellipsis,
    );
  }
}
