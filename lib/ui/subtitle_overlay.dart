/// Custom Fire TV subtitle renderer supporting station-specified ARIB positions
/// and speaker colors alongside user-configurable font, size, edge outline, and
/// per-line snug step-free background pills with Japanese TV left alignment.
library;

import 'dart:math' as math;

import 'package:material_ui/material_ui.dart';

import 'subtitle_style_policy.dart';

/// Renders active [cues] over video or inside the settings preview box.
class PlayerSubtitleOverlay extends StatelessWidget {
  const PlayerSubtitleOverlay({
    super.key,
    required this.settings,
    required this.cues,
    this.bottomSafePadding = 24.0,
    this.minFontSize = 14.0,
  });

  final SubtitleSettings settings;
  final List<SubtitleCue> cues;
  final double bottomSafePadding;
  final double minFontSize;

  @override
  Widget build(BuildContext context) {
    if (cues.isEmpty) return const SizedBox.shrink();
    final lineCues = [for (final cue in cues) ...splitSubtitleCueLines(cue)];
    if (lineCues.isEmpty) return const SizedBox.shrink();

    return IgnorePointer(
      child: LayoutBuilder(
        builder: (context, constraints) {
          final viewW =
              constraints.maxWidth.isFinite && constraints.maxWidth > 0
              ? constraints.maxWidth
              : 1280.0;
          final viewH =
              constraints.maxHeight.isFinite && constraints.maxHeight > 0
              ? constraints.maxHeight
              : 720.0;
          final fontSize = resolveSubtitleFontSize(
            settings.size,
            viewH,
            minSize: minFontSize,
          );
          final edgeWidth = resolveSubtitleEdgeWidth(settings.edge, fontSize);
          final textScaler = MediaQuery.textScalerOf(context);
          final blocks = _clusterSubtitleBlocks(lineCues);
          return Stack(
            fit: StackFit.expand,
            children: [
              for (final block in blocks)
                _buildBlock(
                  block: block,
                  viewW: viewW,
                  viewH: viewH,
                  fontSize: fontSize,
                  edgeWidth: edgeWidth,
                  textScaler: textScaler,
                ),
            ],
          );
        },
      ),
    );
  }

  List<List<SubtitleCue>> _clusterSubtitleBlocks(List<SubtitleCue> input) {
    final positioned = <SubtitleCue>[];
    final unpositioned = <SubtitleCue>[];
    for (final cue in input) {
      if (cue.normalizedY != null) {
        positioned.add(cue);
      } else {
        unpositioned.add(cue);
      }
    }
    if (positioned.isEmpty) {
      return [unpositioned];
    }
    positioned.sort((a, b) {
      final yCmp = a.normalizedY!.compareTo(b.normalizedY!);
      if (yCmp != 0) return yCmp;
      return (a.normalizedX ?? 0.5).compareTo(b.normalizedX ?? 0.5);
    });
    final threshold = resolveSubtitleBlockGapThreshold();
    const xThreshold = 0.14;
    final blocks = <List<SubtitleCue>>[];
    for (final cue in positioned) {
      var targetIdx = -1;
      for (var b = blocks.length - 1; b >= 0; b--) {
        final prev = blocks[b].last;
        final yClose = (cue.normalizedY! - prev.normalizedY!).abs() <= threshold;
        final xClose =
            cue.normalizedX == null ||
            prev.normalizedX == null ||
            (cue.normalizedX! - prev.normalizedX!).abs() <= xThreshold;
        if (yClose && xClose) {
          targetIdx = b;
          break;
        }
      }
      if (targetIdx < 0) {
        blocks.add([cue]);
      } else {
        blocks[targetIdx].add(cue);
      }
    }
    if (unpositioned.isNotEmpty) {
      blocks.add(unpositioned);
    }
    return blocks;
  }

  static const TextHeightBehavior _textHeightBehavior = TextHeightBehavior(
    applyHeightToFirstAscent: true,
    applyHeightToLastDescent: true,
  );

  StrutStyle _strutStyle(double fontSize) => StrutStyle(
    fontSize: fontSize,
    height: 1.28,
    forceStrutHeight: true,
  );

  TextSpan _buildCueSpan({
    required SubtitleCue cue,
    required double fontSize,
    required double edgeWidth,
    required List<Shadow> textShadows,
    required bool isStroke,
  }) {
    return TextSpan(
      children: [
        for (final run in cue.spans)
          TextSpan(
            text: run.text,
            style: TextStyle(
              fontFamily: settings.font.fontFamily,
              fontFamilyFallback: settings.font.fontFamilyFallback,
              fontWeight: settings.font.fontWeight,
              fontSize: fontSize * run.scale,
              height: 1.28,
              locale: const Locale('ja', 'JP'),
              color: isStroke ? null : run.color,
              foreground: isStroke
                  ? (Paint()
                      ..style = PaintingStyle.stroke
                      ..strokeWidth = edgeWidth
                      ..strokeJoin = StrokeJoin.round
                      ..color = Colors.black)
                  : null,
              shadows: isStroke
                  ? const [
                      Shadow(
                        color: Colors.black87,
                        blurRadius: 3.0,
                        offset: Offset(0, 1),
                      ),
                    ]
                  : (textShadows.isEmpty ? null : textShadows),
            ),
          ),
      ],
    );
  }

  List<SubtitleStyledSpan> _sliceCueSpans(
    List<SubtitleStyledSpan> spans,
    int start,
    int end,
  ) {
    if (end <= start) return const [];
    final out = <SubtitleStyledSpan>[];
    var cursor = 0;
    for (final span in spans) {
      final spanEnd = cursor + span.text.length;
      if (spanEnd > start && cursor < end) {
        final localStart = math.max(0, start - cursor);
        final localEnd = math.min(span.text.length, end - cursor);
        if (localEnd > localStart) {
          final chunk = span.text.substring(localStart, localEnd);
          if (chunk.isNotEmpty) {
            out.add(
              SubtitleStyledSpan(
                text: chunk,
                color: span.color,
                scale: span.scale,
              ),
            );
          }
        }
      }
      cursor = spanEnd;
      if (cursor >= end) break;
    }
    while (out.isNotEmpty) {
      final last = out.last;
      final trimmed = last.text.replaceFirst(RegExp(r'[\r\n]+$'), '');
      if (trimmed == last.text) break;
      out.removeLast();
      if (trimmed.isNotEmpty) {
        out.add(
          SubtitleStyledSpan(
            text: trimmed,
            color: last.color,
            scale: last.scale,
          ),
        );
        break;
      }
    }
    return out;
  }

  ({List<SubtitleCue> lines, double maxLineWidth}) _splitCueIntoVisualLines({
    required SubtitleCue cue,
    required double maxTextWidth,
    required double fontSize,
    required StrutStyle strut,
    required TextScaler textScaler,
  }) {
    final fullText = cue.plainText;
    if (fullText.isEmpty) {
      return (lines: [cue], maxLineWidth: 0.0);
    }
    final painter = TextPainter(
      text: _buildCueSpan(
        cue: cue,
        fontSize: fontSize,
        edgeWidth: 0.0,
        textShadows: const [],
        isStroke: false,
      ),
      textDirection: TextDirection.ltr,
      textAlign: TextAlign.left,
      textScaler: textScaler,
      strutStyle: strut,
      textHeightBehavior: _textHeightBehavior,
    )..layout(maxWidth: maxTextWidth);

    try {
      final lineMetrics = painter.computeLineMetrics();
      final maxLineW = lineMetrics.isEmpty
          ? painter.width
          : lineMetrics.map((m) => m.width).reduce(math.max);
      if (lineMetrics.length <= 1) {
        return (lines: [cue], maxLineWidth: maxLineW);
      }

      final visualLines = <SubtitleCue>[];
      var offset = 0;
      while (offset < fullText.length) {
        final range = painter.getLineBoundary(TextPosition(offset: offset));
        final nextEnd = math.min(fullText.length, range.end);
        if (nextEnd <= offset) break;
        final sliceStart = math.max(offset, range.start);
        final sliced = _sliceCueSpans(cue.spans, sliceStart, nextEnd);
        final slicedText = [for (final s in sliced) s.text].join().trim();
        if (slicedText.isNotEmpty) {
          visualLines.add(
            SubtitleCue(
              spans: sliced,
              normalizedX: cue.normalizedX,
              endNormalizedX: cue.endNormalizedX,
              normalizedY: cue.normalizedY,
              alignment: cue.alignment,
            ),
          );
        }
        offset = nextEnd;
      }
      return (
        lines: visualLines.isEmpty ? [cue] : visualLines,
        maxLineWidth: maxLineW,
      );
    } finally {
      painter.dispose();
    }
  }

  Widget _buildBlock({
    required List<SubtitleCue> block,
    required double viewW,
    required double viewH,
    required double fontSize,
    required double edgeWidth,
    required TextScaler textScaler,
  }) {
    final positionedY = [
      for (final cue in block)
        if (cue.normalizedY != null) cue.normalizedY!,
    ];
    final positionedX = [
      for (final cue in block)
        if (cue.normalizedX != null) cue.normalizedX!,
    ];
    final positionedEndX = [
      for (final cue in block)
        if (cue.endNormalizedX != null) cue.endNormalizedX!,
    ];

    final double? avgY = positionedY.isEmpty
        ? null
        : positionedY.reduce((a, b) => a + b) / positionedY.length;
    final double? minY = positionedY.isEmpty
        ? null
        : positionedY.reduce(math.min);
    final double? maxY = positionedY.isEmpty
        ? null
        : positionedY.reduce(math.max);
    final double? minX = positionedX.isEmpty
        ? null
        : positionedX.reduce(math.min);
    final double? maxEndX = positionedEndX.isEmpty
        ? null
        : positionedEndX.reduce(math.max);

    final hasBackground = settings.backgroundOpacityPercent > 0;
    final hPad = hasBackground ? fontSize * 0.34 : 0.0;
    final baseLeft = minX != null
        ? (minX * viewW).clamp(16.0, viewW * 0.58).toDouble()
        : 24.0;
    final maxBlockW = minX != null
        ? math.max(120.0, viewW - baseLeft - 16.0)
        : math.max(120.0, viewW - 48.0);
    final maxTextWidth = math.max(40.0, maxBlockW - hPad * 2);
    final strut = _strutStyle(fontSize);

    final visualLines = <SubtitleCue>[];
    var maxLineWidth = 0.0;
    for (final cue in block) {
      final split = _splitCueIntoVisualLines(
        cue: cue,
        maxTextWidth: maxTextWidth,
        fontSize: fontSize,
        strut: strut,
        textScaler: textScaler,
      );
      visualLines.addAll(split.lines);
      if (split.maxLineWidth > maxLineWidth) {
        maxLineWidth = split.maxLineWidth;
      }
    }
    final maxRenderedPillW = math.min(
      maxBlockW,
      maxLineWidth.ceilToDouble() + hPad * 2 + 2.0,
    );

    final double xAlign;
    final double leftPad;
    final double rightPad;
    if (minX != null) {
      xAlign = -1.0;
      rightPad = 16.0;
      if (maxEndX != null && maxEndX > minX) {
        final broadcastW = (maxEndX - minX) * viewW;
        final broadcastCenterX = ((minX + maxEndX) * 0.5) * viewW;
        final maxAllowedLeft = math.max(16.0, viewW - maxRenderedPillW - 16.0);
        if (maxRenderedPillW < broadcastW) {
          leftPad = (broadcastCenterX - maxRenderedPillW * 0.5)
              .clamp(16.0, maxAllowedLeft)
              .toDouble();
        } else {
          leftPad = baseLeft.clamp(16.0, maxAllowedLeft).toDouble();
        }
      } else {
        leftPad = baseLeft;
      }
    } else {
      // Unpositioned fallback centers the left-aligned column as a block.
      xAlign = 0.0;
      leftPad = 24.0;
      rightPad = 24.0;
    }

    final double yAlign;
    final double topPad;
    final double bottomPad;
    if (avgY == null) {
      yAlign = 1.0;
      topPad = 16.0;
      bottomPad = bottomSafePadding;
    } else if (avgY <= 0.38) {
      yAlign = -1.0;
      topPad = math.max(16.0, (minY! * viewH) - fontSize * 0.8);
      bottomPad = bottomSafePadding;
    } else if (avgY >= 0.65) {
      yAlign = 1.0;
      topPad = 16.0;
      bottomPad = math.max(
        bottomSafePadding,
        ((1.0 - maxY!) * viewH - fontSize * 0.6).clamp(0.0, viewH * 0.38),
      );
    } else {
      yAlign = ((avgY * 2.0) - 1.0).clamp(-0.65, 0.65).toDouble();
      topPad = 16.0;
      bottomPad = bottomSafePadding;
    }

    Widget buildLinePill(SubtitleCue cue) {
      final textWidget = _buildCueText(
        cue: cue,
        fontSize: fontSize,
        edgeWidth: edgeWidth,
        strut: strut,
      );
      if (!hasBackground) return textWidget;
      return Container(
        padding: EdgeInsets.symmetric(
          horizontal: fontSize * 0.34,
          vertical: fontSize * 0.14,
        ),
        decoration: BoxDecoration(
          color: settings.effectiveBackgroundColor,
          borderRadius: BorderRadius.circular(4),
        ),
        child: textWidget,
      );
    }

    final content = Column(
      mainAxisSize: MainAxisSize.min,
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        for (var i = 0; i < visualLines.length; i++) ...[
          if (i > 0) SizedBox(height: math.max(2.0, fontSize * 0.12)),
          buildLinePill(visualLines[i]),
        ],
      ],
    );

    return Positioned.fill(
      child: Padding(
        padding: EdgeInsets.fromLTRB(leftPad, topPad, rightPad, bottomPad),
        child: Align(alignment: Alignment(xAlign, yAlign), child: content),
      ),
    );
  }

  Widget _buildCueText({
    required SubtitleCue cue,
    required double fontSize,
    required double edgeWidth,
    required StrutStyle strut,
  }) {
    final textShadows = resolveSubtitleTextShadows(settings.edge, fontSize);

    final fillText = Text.rich(
      _buildCueSpan(
        cue: cue,
        fontSize: fontSize,
        edgeWidth: edgeWidth,
        textShadows: textShadows,
        isStroke: false,
      ),
      textAlign: TextAlign.left,
      strutStyle: strut,
      textHeightBehavior: _textHeightBehavior,
    );
    if (edgeWidth <= 0) return fillText;

    return Stack(
      alignment: Alignment.centerLeft,
      children: [
        Text.rich(
          _buildCueSpan(
            cue: cue,
            fontSize: fontSize,
            edgeWidth: edgeWidth,
            textShadows: textShadows,
            isStroke: true,
          ),
          textAlign: TextAlign.left,
          strutStyle: strut,
          textHeightBehavior: _textHeightBehavior,
        ),
        fillText,
      ],
    );
  }
}
