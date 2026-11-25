/// Comment momentum mountain graph rendered above the recorded playback seek
/// bar so viewers can spot highlight moments at a glance (Phase 40).
library;

import 'dart:math' as math;

import 'package:material_ui/material_ui.dart';

class JikkyoMomentumGraph extends StatelessWidget {
  const JikkyoMomentumGraph({
    super.key,
    required this.buckets,
    required this.posFraction,
    this.height = 24.0,
    this.loading = false,
  });

  final List<int> buckets;
  final double posFraction;
  final double height;
  final bool loading;

  @override
  Widget build(BuildContext context) {
    if (buckets.isEmpty) {
      return const SizedBox.shrink();
    }
    final maxCount = buckets.fold<int>(0, math.max);
    if (maxCount <= 0 && !loading) {
      return const SizedBox.shrink();
    }
    return SizedBox(
      height: height,
      child: CustomPaint(
        painter: _JikkyoMomentumPainter(
          buckets: buckets,
          maxCount: math.max(1, maxCount),
          posFraction: posFraction.clamp(0.0, 1.0),
        ),
      ),
    );
  }
}

class _JikkyoMomentumPainter extends CustomPainter {
  const _JikkyoMomentumPainter({
    required this.buckets,
    required this.maxCount,
    required this.posFraction,
  });

  final List<int> buckets;
  final int maxCount;
  final double posFraction;

  @override
  void paint(Canvas canvas, Size size) {
    if (buckets.isEmpty || size.width <= 0 || size.height <= 0) return;

    final n = buckets.length;
    final topPad = 2.0;
    final usableH = math.max(2.0, size.height - topPad);

    final path = Path()..moveTo(0, size.height);
    final linePath = Path();
    for (var i = 0; i < n; i++) {
      final x = n == 1 ? size.width : (i / (n - 1)) * size.width;
      final norm = (buckets[i] / maxCount).clamp(0.0, 1.0);
      final y = size.height - norm * usableH;
      if (i == 0) {
        path.lineTo(0, y);
        linePath.moveTo(0, y);
      } else {
        path.lineTo(x, y);
        linePath.lineTo(x, y);
      }
    }
    path.lineTo(size.width, size.height);
    path.close();

    final splitX = (size.width * posFraction).clamp(0.0, size.width);

    // Played portion (left of thumb) in lightBlueAccent.
    canvas.save();
    canvas.clipRect(Rect.fromLTWH(0, 0, splitX, size.height));
    canvas.drawPath(
      path,
      Paint()
        ..color = Colors.lightBlueAccent.withValues(alpha: 0.36)
        ..style = PaintingStyle.fill,
    );
    canvas.drawPath(
      linePath,
      Paint()
        ..color = Colors.lightBlueAccent.withValues(alpha: 0.85)
        ..style = PaintingStyle.stroke
        ..strokeWidth = 1.4,
    );
    canvas.restore();

    // Unplayed portion (right of thumb) in soft amber-white.
    canvas.save();
    canvas.clipRect(
      Rect.fromLTWH(splitX, 0, math.max(0.0, size.width - splitX), size.height),
    );
    canvas.drawPath(
      path,
      Paint()
        ..color = Colors.amberAccent.withValues(alpha: 0.24)
        ..style = PaintingStyle.fill,
    );
    canvas.drawPath(
      linePath,
      Paint()
        ..color = Colors.amberAccent.withValues(alpha: 0.65)
        ..style = PaintingStyle.stroke
        ..strokeWidth = 1.2,
    );
    canvas.restore();
  }

  @override
  bool shouldRepaint(covariant _JikkyoMomentumPainter oldDelegate) {
    return oldDelegate.posFraction != posFraction ||
        oldDelegate.maxCount != maxCount ||
        oldDelegate.buckets != buckets;
  }
}
