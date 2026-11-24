/// Custom Fire TV subtitle renderer supporting station-specified ARIB positions
/// and speaker colors alongside user-configurable font, size, edge outline, and
/// per-line snug step-free background pills with Japanese TV left alignment.
library;

import 'dart:math' as math;

import 'package:flutter/rendering.dart';
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
    height: 1.20,
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
              height: 1.20,
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

    final vPad = fontSize * 0.12;
    Widget buildLineWidget(int index, SubtitleCue cue) {
      final textWidget = _buildCueText(
        cue: cue,
        fontSize: fontSize,
        edgeWidth: edgeWidth,
        strut: strut,
      );
      if (!hasBackground) return textWidget;
      return Padding(
        padding: EdgeInsets.fromLTRB(
          hPad,
          index == 0 ? vPad : 0.0,
          hPad,
          index == visualLines.length - 1 ? vPad : 0.0,
        ),
        child: textWidget,
      );
    }

    final Widget content;
    if (hasBackground) {
      content = SubtitleUnifiedBackgroundBox(
        backgroundColor: settings.effectiveBackgroundColor,
        cornerRadius: 5.0,
        children: [
          for (var i = 0; i < visualLines.length; i++)
            buildLineWidget(i, visualLines[i]),
        ],
      );
    } else {
      content = Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          for (var i = 0; i < visualLines.length; i++) ...[
            if (i > 0) SizedBox(height: math.max(1.0, fontSize * 0.04)),
            buildLineWidget(i, visualLines[i]),
          ],
        ],
      );
    }

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

/// Builds a single clockwise polygon [Path] wrapping vertically contiguous,
/// left-aligned [lineRects] with smooth rounded outer and concave inner corners
/// so semi-transparent subtitle backgrounds never show gaps or double-painted seams.
Path buildUnifiedSubtitlePolygonPath(
  List<Rect> lineRects, {
  double radius = 5.0,
}) {
  if (lineRects.isEmpty) return Path();
  if (lineRects.length == 1) {
    final rect = lineRects.first;
    final r = radius
        .clamp(0.0, math.min(rect.width * 0.48, rect.height * 0.48))
        .toDouble();
    return Path()..addRRect(RRect.fromRectAndRadius(rect, Radius.circular(r)));
  }

  final xLeft = lineRects.map((r) => r.left).reduce(math.min);
  final rights = [for (final r in lineRects) r.right];
  final minStepDelta = radius * 2.0;

  var changed = true;
  while (changed) {
    changed = false;
    for (var i = 0; i < rights.length - 1; i++) {
      final diff = (rights[i] - rights[i + 1]).abs();
      if (diff > 0.001 && diff < minStepDelta) {
        final merged = math.max(rights[i], rights[i + 1]);
        if (rights[i] != merged || rights[i + 1] != merged) {
          rights[i] = merged;
          rights[i + 1] = merged;
          changed = true;
        }
      }
    }
  }

  final runs = <({double top, double bottom, double right})>[];
  for (var i = 0; i < lineRects.length; i++) {
    final rect = lineRects[i];
    final right = rights[i];
    if (runs.isNotEmpty && (runs.last.right - right).abs() <= 0.001) {
      final prev = runs.removeLast();
      runs.add((
        top: prev.top,
        bottom: rect.bottom,
        right: math.max(prev.right, right),
      ));
    } else {
      runs.add((top: rect.top, bottom: rect.bottom, right: right));
    }
  }

  final yTop = runs.first.top;
  final yBottom = runs.last.bottom;
  if (runs.length == 1) {
    final rect = Rect.fromLTRB(xLeft, yTop, runs.first.right, yBottom);
    final r = radius
        .clamp(0.0, math.min(rect.width * 0.48, rect.height * 0.48))
        .toDouble();
    return Path()..addRRect(RRect.fromRectAndRadius(rect, Radius.circular(r)));
  }

  double cornerClamp(double a, double b) =>
      radius.clamp(0.0, math.min(a, b) * 0.48);

  final first = runs.first;
  final last = runs.last;
  final topL = cornerClamp(yBottom - yTop, first.right - xLeft);
  final topR = cornerClamp(first.bottom - first.top, first.right - xLeft);
  final botR = cornerClamp(last.bottom - last.top, last.right - xLeft);
  final botL = cornerClamp(yBottom - yTop, last.right - xLeft);

  final path = Path()..moveTo(xLeft + topL, yTop);
  path.lineTo(first.right - topR, yTop);
  path.quadraticBezierTo(first.right, yTop, first.right, yTop + topR);

  for (var i = 0; i < runs.length - 1; i++) {
    final curr = runs[i];
    final next = runs[i + 1];
    final dx = next.right - curr.right;
    final sign = dx >= 0 ? 1.0 : -1.0;
    final stepR = [
      radius,
      dx.abs() * 0.48,
      (curr.bottom - curr.top) * 0.48,
      (next.bottom - next.top) * 0.48,
    ].reduce(math.min);
    final seamY = curr.bottom;
    path.lineTo(curr.right, seamY - stepR);
    path.quadraticBezierTo(
      curr.right,
      seamY,
      curr.right + sign * stepR,
      seamY,
    );
    path.lineTo(next.right - sign * stepR, seamY);
    path.quadraticBezierTo(next.right, seamY, next.right, seamY + stepR);
  }

  path.lineTo(last.right, yBottom - botR);
  path.quadraticBezierTo(last.right, yBottom, last.right - botR, yBottom);
  path.lineTo(xLeft + botL, yBottom);
  path.quadraticBezierTo(xLeft, yBottom, xLeft, yBottom - botL);
  path.lineTo(xLeft, yTop + topL);
  path.quadraticBezierTo(xLeft, yTop, xLeft + topL, yTop);
  path.close();
  return path;
}

class _SubtitleLineParentData extends ContainerBoxParentData<RenderBox> {}

/// Stacks subtitle line widgets vertically and paints one unified stepped
/// polygon backdrop behind all lines.
class SubtitleUnifiedBackgroundBox extends MultiChildRenderObjectWidget {
  const SubtitleUnifiedBackgroundBox({
    super.key,
    required this.backgroundColor,
    this.cornerRadius = 5.0,
    required super.children,
  });

  final Color backgroundColor;
  final double cornerRadius;

  @override
  RenderSubtitleUnifiedBackgroundBox createRenderObject(BuildContext context) {
    return RenderSubtitleUnifiedBackgroundBox(
      backgroundColor: backgroundColor,
      cornerRadius: cornerRadius,
    );
  }

  @override
  void updateRenderObject(
    BuildContext context,
    RenderSubtitleUnifiedBackgroundBox renderObject,
  ) {
    renderObject
      ..backgroundColor = backgroundColor
      ..cornerRadius = cornerRadius;
  }
}

/// RenderObject backing [SubtitleUnifiedBackgroundBox].
class RenderSubtitleUnifiedBackgroundBox extends RenderBox
    with
        ContainerRenderObjectMixin<RenderBox, _SubtitleLineParentData>,
        RenderBoxContainerDefaultsMixin<RenderBox, _SubtitleLineParentData> {
  RenderSubtitleUnifiedBackgroundBox({
    required Color backgroundColor,
    double cornerRadius = 5.0,
  }) {
    _backgroundColor = backgroundColor;
    _cornerRadius = cornerRadius;
  }

  late Color _backgroundColor;
  Color get backgroundColor => _backgroundColor;
  set backgroundColor(Color value) {
    if (_backgroundColor == value) return;
    _backgroundColor = value;
    markNeedsPaint();
  }

  late double _cornerRadius;
  double get cornerRadius => _cornerRadius;
  set cornerRadius(double value) {
    if (_cornerRadius == value) return;
    _cornerRadius = value;
    markNeedsPaint();
  }

  List<Rect> _lineRects = const [];
  List<Rect> get lineRects => List<Rect>.unmodifiable(_lineRects);

  @override
  void setupParentData(RenderBox child) {
    if (child.parentData is! _SubtitleLineParentData) {
      child.parentData = _SubtitleLineParentData();
    }
  }

  @override
  Size computeDryLayout(BoxConstraints constraints) {
    final childConstraints = BoxConstraints(
      minWidth: 0,
      maxWidth: constraints.maxWidth,
      minHeight: 0,
      maxHeight: double.infinity,
    );
    var y = 0.0;
    var maxW = 0.0;
    var child = firstChild;
    while (child != null) {
      final childSize = child.getDryLayout(childConstraints);
      if (childSize.width > maxW) maxW = childSize.width;
      y += childSize.height;
      child = childAfter(child);
    }
    return constraints.constrain(Size(maxW, y));
  }

  @override
  void performLayout() {
    final childConstraints = BoxConstraints(
      minWidth: 0,
      maxWidth: constraints.maxWidth,
      minHeight: 0,
      maxHeight: double.infinity,
    );
    var y = 0.0;
    var maxW = 0.0;
    final rects = <Rect>[];
    var child = firstChild;
    while (child != null) {
      child.layout(childConstraints, parentUsesSize: true);
      final childParentData = child.parentData! as _SubtitleLineParentData;
      childParentData.offset = Offset(0.0, y);
      final w = child.size.width;
      final h = child.size.height;
      rects.add(Rect.fromLTWH(0.0, y, w, h));
      if (w > maxW) maxW = w;
      y += h;
      child = childParentData.nextSibling;
    }
    _lineRects = rects;
    size = constraints.constrain(Size(maxW, y));
  }

  @override
  void paint(PaintingContext context, Offset offset) {
    if (_backgroundColor.a > 0 && _lineRects.isNotEmpty) {
      final path = buildUnifiedSubtitlePolygonPath(
        _lineRects,
        radius: _cornerRadius,
      ).shift(offset);
      context.canvas.drawPath(
        path,
        Paint()
          ..color = _backgroundColor
          ..style = PaintingStyle.fill
          ..isAntiAlias = true,
      );
    }
    defaultPaint(context, offset);
  }

  @override
  bool hitTestChildren(BoxHitTestResult result, {required Offset position}) {
    return defaultHitTestChildren(result, position: position);
  }
}
