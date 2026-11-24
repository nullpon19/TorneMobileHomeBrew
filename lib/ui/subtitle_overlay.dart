/// Custom Fire TV subtitle renderer supporting station-specified ARIB positions
/// and speaker colors alongside user-configurable font, size, edge outline, and
/// step-free uniform background boxes.
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
    this.minFontSize = 16.0,
  });

  final SubtitleSettings settings;
  final List<SubtitleCue> cues;
  final double bottomSafePadding;
  final double minFontSize;

  @override
  Widget build(BuildContext context) {
    if (cues.isEmpty) return const SizedBox.shrink();
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
          final blocks = _clusterSubtitleBlocks(cues);
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
    positioned.sort((a, b) => a.normalizedY!.compareTo(b.normalizedY!));
    final threshold = resolveSubtitleBlockGapThreshold();
    final blocks = <List<SubtitleCue>>[];
    for (final cue in positioned) {
      if (blocks.isEmpty) {
        blocks.add([cue]);
        continue;
      }
      final prevY = blocks.last.last.normalizedY!;
      if ((cue.normalizedY! - prevY).abs() <= threshold) {
        blocks.last.add(cue);
      } else {
        blocks.add([cue]);
      }
    }
    if (unpositioned.isNotEmpty) {
      blocks.add(unpositioned);
    }
    return blocks;
  }

  Widget _buildBlock({
    required List<SubtitleCue> block,
    required double viewW,
    required double viewH,
    required double fontSize,
    required double edgeWidth,
  }) {
    final positionedCues = [
      for (final cue in block)
        if (cue.normalizedY != null) cue,
    ];
    final double? avgY = positionedCues.isEmpty
        ? null
        : positionedCues.fold<double>(0.0, (s, c) => s + c.normalizedY!) /
              positionedCues.length;
    final avgX = block.first.normalizedX ?? 0.5;
    final alignment = block.first.alignment;

    final isRight = (alignment % 3 == 0) || avgX > 0.67;
    final isLeft = !isRight && avgX < 0.33;

    final TextAlign textAlign;
    final CrossAxisAlignment crossAlign;
    final double xAlign;
    final double leftPad;
    final double rightPad;
    if (isRight) {
      textAlign = TextAlign.right;
      crossAlign = CrossAxisAlignment.end;
      xAlign = 1.0;
      leftPad = 24.0;
      rightPad = alignment % 3 == 0
          ? math.max(24.0, math.min((1.0 - avgX) * viewW, viewW * 0.25))
          : 24.0;
    } else if (isLeft) {
      textAlign = TextAlign.left;
      crossAlign = CrossAxisAlignment.start;
      xAlign = -1.0;
      leftPad = math.max(24.0, math.min(avgX * viewW, viewW * 0.25));
      rightPad = 24.0;
    } else {
      textAlign = TextAlign.center;
      crossAlign = CrossAxisAlignment.center;
      xAlign = 0.0;
      leftPad = 24.0;
      rightPad = 24.0;
    }

    final double yAlign;
    final double topPad;
    final double bottomPad;
    if (avgY == null || avgY > 0.65) {
      yAlign = 1.0;
      topPad = 16.0;
      bottomPad = avgY == null
          ? bottomSafePadding
          : math.max(bottomSafePadding, ((1.0 - avgY) * viewH * 0.55));
    } else if (avgY < 0.35) {
      yAlign = -1.0;
      topPad = math.max(16.0, avgY * viewH * 0.6);
      bottomPad = bottomSafePadding;
    } else {
      yAlign = ((avgY * 2.0) - 1.0).clamp(-0.6, 0.6).toDouble();
      topPad = 16.0;
      bottomPad = bottomSafePadding;
    }

    final hasBackground = settings.backgroundOpacityPercent > 0;
    final content = Column(
      mainAxisSize: MainAxisSize.min,
      crossAxisAlignment: crossAlign,
      children: [
        for (var i = 0; i < block.length; i++) ...[
          if (i > 0) SizedBox(height: math.max(2.0, fontSize * 0.08)),
          _buildCueText(
            cue: block[i],
            fontSize: fontSize,
            edgeWidth: edgeWidth,
            textAlign: textAlign,
          ),
        ],
      ],
    );

    final box = hasBackground
        ? Container(
            padding: EdgeInsets.symmetric(
              horizontal: fontSize * 0.48,
              vertical: fontSize * 0.24,
            ),
            decoration: BoxDecoration(
              color: settings.effectiveBackgroundColor,
              borderRadius: BorderRadius.circular(6),
            ),
            child: content,
          )
        : content;

    return Positioned.fill(
      child: Padding(
        padding: EdgeInsets.fromLTRB(leftPad, topPad, rightPad, bottomPad),
        child: Align(alignment: Alignment(xAlign, yAlign), child: box),
      ),
    );
  }

  Widget _buildCueText({
    required SubtitleCue cue,
    required double fontSize,
    required double edgeWidth,
    required TextAlign textAlign,
  }) {
    final strut = StrutStyle(
      fontSize: fontSize,
      height: 1.32,
      forceStrutHeight: true,
    );
    const heightBehavior = TextHeightBehavior(
      applyHeightToFirstAscent: true,
      applyHeightToLastDescent: true,
    );

    InlineSpan buildSpan({required bool isStroke}) {
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
                height: 1.32,
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
                    : null,
              ),
            ),
        ],
      );
    }

    final fillText = Text.rich(
      buildSpan(isStroke: false),
      textAlign: textAlign,
      strutStyle: strut,
      textHeightBehavior: heightBehavior,
    );
    if (edgeWidth <= 0) return fillText;

    return Stack(
      alignment: switch (textAlign) {
        TextAlign.left => Alignment.centerLeft,
        TextAlign.right => Alignment.centerRight,
        _ => Alignment.center,
      },
      children: [
        Text.rich(
          buildSpan(isStroke: true),
          textAlign: textAlign,
          strutStyle: strut,
          textHeightBehavior: heightBehavior,
        ),
        fillText,
      ],
    );
  }
}
