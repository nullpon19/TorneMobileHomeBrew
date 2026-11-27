/// Single-canvas direct-video Niconico Jikkyo danmaku overlay rendered with a
/// Ticker + CustomPainter + bounded TextPainter LRU cache so Fire TV (1-2 GB RAM)
/// keeps silky frame times without spawning per-comment widgets (Phase 40).
library;

import 'dart:async';
import 'dart:collection';
import 'dart:math' as math;

import 'package:flutter/scheduler.dart';
import 'package:material_ui/material_ui.dart';

import '../core/jikkyo/jikkyo_models.dart';

/// Computes the base Niconico Jikkyo comment font size in logical pixels for
/// [viewportHeight], aligned with Fire TV 10-foot viewing & subtitle sizing.
double resolveJikkyoBaseFontSize(
  JikkyoTextSizePreset preset,
  double viewportHeight,
) {
  final safeHeight = viewportHeight.isFinite && viewportHeight > 0
      ? viewportHeight
      : 540.0;
  return (safeHeight * preset.viewportHeightFactor)
      .clamp(14.0, 84.0)
      .toDouble();
}

class JikkyoDanmakuController {
  final List<void Function(List<JikkyoComment>)> _commentListeners = [];
  final List<VoidCallback> _clearListeners = [];

  void enqueue(List<JikkyoComment> comments) {
    if (comments.isEmpty) return;
    for (final listener in List<void Function(List<JikkyoComment>)>.of(
      _commentListeners,
    )) {
      listener(comments);
    }
  }

  void clear() {
    for (final listener in List<VoidCallback>.of(_clearListeners)) {
      listener();
    }
  }

  void _addListeners(
    void Function(List<JikkyoComment>) onComments,
    VoidCallback onClear,
  ) {
    _commentListeners.add(onComments);
    _clearListeners.add(onClear);
  }

  void _removeListeners(
    void Function(List<JikkyoComment>) onComments,
    VoidCallback onClear,
  ) {
    _commentListeners.remove(onComments);
    _clearListeners.remove(onClear);
  }

  void dispose() {
    _commentListeners.clear();
    _clearListeners.clear();
  }
}

class _ActiveDanmakuItem {
  _ActiveDanmakuItem({
    required this.comment,
    required this.laneIndex,
    required this.elapsedSeconds,
    required this.durationSeconds,
    required this.textWidth,
  });

  final JikkyoComment comment;
  final int laneIndex;
  double elapsedSeconds;
  final double durationSeconds;
  final double textWidth;

  double get progress =>
      durationSeconds <= 0 ? 1.0 : (elapsedSeconds / durationSeconds);
}

class _CachedTextPair {
  const _CachedTextPair({
    required this.fill,
    required this.stroke,
    required this.width,
    required this.height,
  });

  final TextPainter fill;
  final TextPainter stroke;
  final double width;
  final double height;
}

class JikkyoDanmakuOverlay extends StatefulWidget {
  const JikkyoDanmakuOverlay({
    super.key,
    required this.settings,
    this.controller,
    this.isPlaying = true,
    this.playbackRate = 1.0,
    this.avoidBottomSubtitles = false,
    this.previewLoopComments,
  });

  final JikkyoSettings settings;
  final JikkyoDanmakuController? controller;
  final bool isPlaying;
  final double playbackRate;
  final bool avoidBottomSubtitles;
  final List<JikkyoComment>? previewLoopComments;

  @override
  State<JikkyoDanmakuOverlay> createState() => _JikkyoDanmakuOverlayState();
}

class _JikkyoDanmakuOverlayState extends State<JikkyoDanmakuOverlay>
    with SingleTickerProviderStateMixin {
  static const int _maxPainterCacheEntries = 128;

  late final Ticker _ticker;
  final ValueNotifier<int> _repaintTick = ValueNotifier<int>(0);
  final List<_ActiveDanmakuItem> _active = [];
  final LinkedHashMap<String, _CachedTextPair> _painterCache =
      LinkedHashMap<String, _CachedTextPair>();

  Duration? _lastTickElapsed;
  Size _viewportSize = const Size(1280, 720);
  Timer? _previewTimer;
  int _previewCursor = 0;

  @override
  void initState() {
    super.initState();
    widget.controller?._addListeners(_handleIncomingComments, _handleClear);
    _ticker = createTicker(_onTick);
    _syncPreviewTimer();
    _syncTicker();
  }

  void _clearPainterCache() {
    for (final pair in _painterCache.values) {
      pair.fill.dispose();
      pair.stroke.dispose();
    }
    _painterCache.clear();
  }

  void _syncTicker() {
    final shouldRun = widget.isPlaying && _active.isNotEmpty;
    if (shouldRun && !_ticker.isActive) {
      _lastTickElapsed = null;
      _ticker.start();
    } else if (!shouldRun && _ticker.isActive) {
      _ticker.stop();
      _lastTickElapsed = null;
    }
  }

  @override
  void didUpdateWidget(covariant JikkyoDanmakuOverlay oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.controller != widget.controller) {
      oldWidget.controller?._removeListeners(
        _handleIncomingComments,
        _handleClear,
      );
      widget.controller?._addListeners(_handleIncomingComments, _handleClear);
    }
    if (oldWidget.settings.opacityPercent != widget.settings.opacityPercent ||
        oldWidget.settings.textSize != widget.settings.textSize ||
        oldWidget.settings.forceWhiteText != widget.settings.forceWhiteText) {
      _clearPainterCache();
      _repaintTick.value++;
    }
    if (oldWidget.settings.hideFixedComments !=
            widget.settings.hideFixedComments ||
        oldWidget.settings.ngWords != widget.settings.ngWords) {
      _active.removeWhere((item) => !widget.settings.matchesFilter(item.comment));
      _repaintTick.value++;
    }
    if (oldWidget.previewLoopComments != widget.previewLoopComments ||
        oldWidget.isPlaying != widget.isPlaying) {
      _syncPreviewTimer();
    }
    _syncTicker();
  }

  void _syncPreviewTimer() {
    _previewTimer?.cancel();
    _previewTimer = null;
    final samples = widget.previewLoopComments;
    if (samples == null || samples.isEmpty || !widget.isPlaying) return;
    _handleIncomingComments([samples[_previewCursor % samples.length]]);
    _previewCursor++;
    _previewTimer = Timer.periodic(const Duration(milliseconds: 900), (_) {
      if (!mounted || !widget.isPlaying) return;
      final list = widget.previewLoopComments;
      if (list == null || list.isEmpty) return;
      _handleIncomingComments([list[_previewCursor % list.length]]);
      _previewCursor++;
    });
  }

  void _handleClear() {
    _active.clear();
    _syncTicker();
    _repaintTick.value++;
  }

  double _resolvedBaseFontSize(double viewHeight) =>
      resolveJikkyoBaseFontSize(widget.settings.textSize, viewHeight);

  double _commentFontSize(JikkyoComment comment, double baseFontSize) {
    switch (comment.size) {
      case JikkyoCommentSize.small:
        return baseFontSize * 0.80;
      case JikkyoCommentSize.big:
        return baseFontSize * 1.24;
      case JikkyoCommentSize.medium:
        return baseFontSize;
    }
  }

  _CachedTextPair _painterFor(JikkyoComment comment, double baseFontSize) {
    final fontSize = _commentFontSize(comment, baseFontSize);
    final opacity = (widget.settings.opacityPercent / 100.0).clamp(0.1, 1.0);
    final effectiveColorValue =
        widget.settings.forceWhiteText ? 0xFFFFFFFF : comment.colorValue;
    final key =
        '${comment.text}|$effectiveColorValue|${fontSize.toStringAsFixed(1)}|${widget.settings.opacityPercent}';
    final cached = _painterCache.remove(key);
    if (cached != null) {
      _painterCache[key] = cached;
      return cached;
    }

    final fillColor = Color(effectiveColorValue).withValues(alpha: opacity);
    final strokeAlpha = (opacity * 0.92).clamp(0.1, 1.0);
    final strokeWidth = (fontSize * 0.14).clamp(1.8, 6.8);

    final strokePainter = TextPainter(
      text: TextSpan(
        text: comment.text,
        style: TextStyle(
          fontFamily: 'LINESeedJP',
          fontFamilyFallback: const ['GoogleSans', 'Hiragino Sans', 'sans-serif'],
          fontWeight: FontWeight.w700,
          fontSize: fontSize,
          height: 1.15,
          locale: const Locale('ja', 'JP'),
          foreground: Paint()
            ..style = PaintingStyle.stroke
            ..strokeWidth = strokeWidth
            ..strokeJoin = StrokeJoin.round
            ..color = Colors.black.withValues(alpha: strokeAlpha),
        ),
      ),
      textDirection: TextDirection.ltr,
      maxLines: 1,
    )..layout();

    final fillPainter = TextPainter(
      text: TextSpan(
        text: comment.text,
        style: TextStyle(
          fontFamily: 'LINESeedJP',
          fontFamilyFallback: const ['GoogleSans', 'Hiragino Sans', 'sans-serif'],
          fontWeight: FontWeight.w700,
          fontSize: fontSize,
          height: 1.15,
          locale: const Locale('ja', 'JP'),
          color: fillColor,
        ),
      ),
      textDirection: TextDirection.ltr,
      maxLines: 1,
    )..layout();

    final entry = _CachedTextPair(
      fill: fillPainter,
      stroke: strokePainter,
      width: fillPainter.width,
      height: fillPainter.height,
    );
    _painterCache[key] = entry;
    while (_painterCache.length > _maxPainterCacheEntries) {
      final evicted = _painterCache.remove(_painterCache.keys.first);
      if (evicted != null) {
        evicted.fill.dispose();
        evicted.stroke.dispose();
      }
    }
    return entry;
  }

  int _usableLaneCount(double viewHeight, double baseFontSize) {
    final laneHeight = math.max(18.0, baseFontSize * 1.22);
    final usableRatio =
        (widget.avoidBottomSubtitles && widget.settings.avoidSubtitleArea)
        ? 0.72
        : 0.94;
    final usableHeight = math.max(laneHeight, (viewHeight - 16.0) * usableRatio);
    return math.max(2, (usableHeight / laneHeight).floor());
  }

  int _pickLane({
    required JikkyoCommentPosition position,
    required int laneCount,
    required double textWidth,
    required double viewWidth,
    required double durationSeconds,
  }) {
    if (position == JikkyoCommentPosition.ue ||
        position == JikkyoCommentPosition.shita) {
      final used = <int>{
        for (final item in _active)
          if (item.comment.position == position) item.laneIndex,
      };
      for (var lane = 0; lane < laneCount; lane++) {
        if (!used.contains(lane)) return lane;
      }
      return _active.length % laneCount;
    }

    // Naka (scrolling): find first lane with zero right-edge overlap and
    // sufficient lead time so faster comments don't overtake slower ones.
    for (var lane = 0; lane < laneCount; lane++) {
      var laneClear = true;
      for (final item in _active) {
        if (item.comment.position != JikkyoCommentPosition.naka ||
            item.laneIndex != lane) {
          continue;
        }
        final itemTotalTravel = viewWidth + item.textWidth;
        final itemX = viewWidth - itemTotalTravel * item.progress;
        final itemRightEdge = itemX + item.textWidth;
        if (itemRightEdge > viewWidth - 18.0) {
          laneClear = false;
          break;
        }
        // Check left-edge catchup before exiting screen.
        final remainingTime = math.max(0.0, item.durationSeconds - item.elapsedSeconds);
        final newSpeed = (viewWidth + textWidth) / durationSeconds;
        final reachLeftEdgeSec = viewWidth / newSpeed;
        if (reachLeftEdgeSec < remainingTime - 0.15) {
          laneClear = false;
          break;
        }
      }
      if (laneClear) return lane;
    }

    // Fallback: pick lane whose rightmost active comment is furthest left.
    var bestLane = 0;
    var smallestRightEdge = double.infinity;
    for (var lane = 0; lane < laneCount; lane++) {
      var maxRight = -double.infinity;
      for (final item in _active) {
        if (item.comment.position == JikkyoCommentPosition.naka &&
            item.laneIndex == lane) {
          final x =
              viewWidth - (viewWidth + item.textWidth) * item.progress;
          final r = x + item.textWidth;
          if (r > maxRight) maxRight = r;
        }
      }
      if (maxRight < smallestRightEdge) {
        smallestRightEdge = maxRight;
        bestLane = lane;
      }
    }
    return bestLane;
  }

  void _handleIncomingComments(List<JikkyoComment> comments) {
    if (!mounted) return;
    final viewW = _viewportSize.width > 0 ? _viewportSize.width : 1280.0;
    final viewH = _viewportSize.height > 0 ? _viewportSize.height : 720.0;
    final baseFont = _resolvedBaseFontSize(viewH);
    final laneCount = _usableLaneCount(viewH, baseFont);
    final maxCap = widget.settings.maxConcurrentComments;

    for (final comment in comments) {
      if (!widget.settings.matchesFilter(comment)) continue;
      while (_active.length >= maxCap && _active.isNotEmpty) {
        _active.removeAt(0);
      }
      final pair = _painterFor(comment, baseFont);
      final duration = comment.position == JikkyoCommentPosition.naka
          ? widget.settings.speed.durationSeconds
          : 3.5;
      final lane = _pickLane(
        position: comment.position,
        laneCount: laneCount,
        textWidth: pair.width,
        viewWidth: viewW,
        durationSeconds: duration,
      );
      _active.add(
        _ActiveDanmakuItem(
          comment: comment,
          laneIndex: lane,
          elapsedSeconds: 0.0,
          durationSeconds: duration,
          textWidth: pair.width,
        ),
      );
    }
    _syncTicker();
    _repaintTick.value++;
  }

  void _onTick(Duration elapsed) {
    final prev = _lastTickElapsed;
    _lastTickElapsed = elapsed;
    if (prev == null || _active.isEmpty) {
      _syncTicker();
      return;
    }
    final rawDt = (elapsed - prev).inMicroseconds / 1000000.0;
    if (rawDt <= 0 || rawDt > 0.5) return;
    final rate = widget.playbackRate.clamp(0.5, 2.5);
    final dt = rawDt * rate;

    var removed = false;
    for (var i = _active.length - 1; i >= 0; i--) {
      final item = _active[i];
      item.elapsedSeconds += dt;
      if (item.elapsedSeconds >= item.durationSeconds) {
        _active.removeAt(i);
        removed = true;
      }
    }
    if (_active.isEmpty) {
      _syncTicker();
    }
    if (_active.isNotEmpty || removed) {
      _repaintTick.value++;
    }
  }

  @override
  void dispose() {
    _previewTimer?.cancel();
    widget.controller?._removeListeners(_handleIncomingComments, _handleClear);
    _ticker.dispose();
    _repaintTick.dispose();
    _clearPainterCache();
    _active.clear();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return IgnorePointer(
      child: RepaintBoundary(
        child: LayoutBuilder(
          builder: (context, constraints) {
            final w =
                constraints.maxWidth.isFinite && constraints.maxWidth > 0
                ? constraints.maxWidth
                : 1280.0;
            final h =
                constraints.maxHeight.isFinite && constraints.maxHeight > 0
                ? constraints.maxHeight
                : 720.0;
            _viewportSize = Size(w, h);
            final baseFont = _resolvedBaseFontSize(h);
            return CustomPaint(
              size: Size(w, h),
              painter: _JikkyoDanmakuPainter(
                repaint: _repaintTick,
                activeItems: _active,
                painterLookup: (comment) => _painterFor(comment, baseFont),
                baseFontSize: baseFont,
                avoidSubtitleArea:
                    widget.avoidBottomSubtitles &&
                    widget.settings.avoidSubtitleArea,
              ),
            );
          },
        ),
      ),
    );
  }
}

class _JikkyoDanmakuPainter extends CustomPainter {
  _JikkyoDanmakuPainter({
    required Listenable repaint,
    required this.activeItems,
    required this.painterLookup,
    required this.baseFontSize,
    required this.avoidSubtitleArea,
  }) : super(repaint: repaint);

  final List<_ActiveDanmakuItem> activeItems;
  final _CachedTextPair Function(JikkyoComment comment) painterLookup;
  final double baseFontSize;
  final bool avoidSubtitleArea;

  @override
  void paint(Canvas canvas, Size size) {
    if (activeItems.isEmpty || size.width <= 0 || size.height <= 0) return;

    final laneHeight = math.max(18.0, baseFontSize * 1.22);
    final usableRatio = avoidSubtitleArea ? 0.72 : 0.94;
    final usableHeight = math.max(laneHeight, (size.height - 16.0) * usableRatio);
    final laneCount = math.max(2, (usableHeight / laneHeight).floor());

    for (final item in activeItems) {
      final pair = painterLookup(item.comment);
      final lane = item.laneIndex % laneCount;
      final double x;
      final double y;
      switch (item.comment.position) {
        case JikkyoCommentPosition.ue:
          x = (size.width - pair.width) / 2.0;
          y = 8.0 + lane * laneHeight;
        case JikkyoCommentPosition.shita:
          x = (size.width - pair.width) / 2.0;
          y = math.max(8.0, usableHeight - (lane + 1) * laneHeight + 8.0);
        case JikkyoCommentPosition.naka:
          x = size.width - (size.width + pair.width) * item.progress;
          y = 8.0 + lane * laneHeight;
      }
      final offset = Offset(x, y);
      pair.stroke.paint(canvas, offset);
      pair.fill.paint(canvas, offset);
    }
  }

  @override
  bool shouldRepaint(covariant _JikkyoDanmakuPainter oldDelegate) {
    return oldDelegate.baseFontSize != baseFontSize ||
        oldDelegate.avoidSubtitleArea != avoidSubtitleArea;
  }
}
