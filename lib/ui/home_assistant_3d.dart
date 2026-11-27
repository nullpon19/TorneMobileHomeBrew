/// Smooth clay-shaded 3D renderer for the Home Easter egg assistant "ナスカ"
/// (white dolphin-bird hybrid with rainbow crest/flipper/tail feathers,
/// classic arched three-quarter angle, 3D lifebuoy splash entry, and
/// wistful bubble-ring exit).
library;

import 'dart:math' as math;

import 'package:material_ui/material_ui.dart';

import '../app/providers.dart';

/// Playful motions performed by Nasuka while hovering on Home.
enum NasukaAction { float, wink, flap, spin, swim }

/// Immutable pose snapshot consumed by [Nasuka3dPainter].
class Nasuka3dPose {
  const Nasuka3dPose({
    required this.stage,
    required this.stageProgress,
    required this.idleTime,
    required this.action,
    required this.actionProgress,
    this.speaking = false,
    this.sad = false,
  });

  final HomeAssistantStage stage;
  final double stageProgress;
  final double idleTime;
  final NasukaAction action;
  final double actionProgress;
  final bool speaking;
  final bool sad;

  @override
  bool operator ==(Object other) =>
      identical(this, other) ||
      other is Nasuka3dPose &&
          runtimeType == other.runtimeType &&
          stage == other.stage &&
          stageProgress == other.stageProgress &&
          idleTime == other.idleTime &&
          action == other.action &&
          actionProgress == other.actionProgress &&
          speaking == other.speaking &&
          sad == other.sad;

  @override
  int get hashCode => Object.hash(
    stage,
    stageProgress,
    idleTime,
    action,
    actionProgress,
    speaking,
    sad,
  );
}

class _Vec3 {
  const _Vec3(this.x, this.y, this.z);

  final double x;
  final double y;
  final double z;

  _Vec3 operator +(_Vec3 o) => _Vec3(x + o.x, y + o.y, z + o.z);
  _Vec3 operator -(_Vec3 o) => _Vec3(x - o.x, y - o.y, z - o.z);
  _Vec3 operator *(double s) => _Vec3(x * s, y * s, z * s);

  double dot(_Vec3 o) => x * o.x + y * o.y + z * o.z;

  _Vec3 normalized() {
    final len = math.sqrt(x * x + y * y + z * z);
    if (len < 1e-6) return const _Vec3(0, 1, 0);
    return _Vec3(x / len, y / len, z / len);
  }

  _Vec3 rotateX(double a) {
    final c = math.cos(a);
    final s = math.sin(a);
    return _Vec3(x, y * c - z * s, y * s + z * c);
  }

  _Vec3 rotateY(double a) {
    final c = math.cos(a);
    final s = math.sin(a);
    return _Vec3(x * c + z * s, y, -x * s + z * c);
  }

  _Vec3 rotateZ(double a) {
    final c = math.cos(a);
    final s = math.sin(a);
    return _Vec3(x * c - y * s, x * s + y * c, z);
  }
}

class _SpineNode {
  const _SpineNode({
    required this.center,
    required this.radius,
    required this.screen,
    required this.screenRadius,
    required this.viewZ,
  });

  final _Vec3 center;
  final double radius;
  final Offset screen;
  final double screenRadius;
  final double viewZ;
}

class _PartDraw {
  const _PartDraw({required this.depth, required this.draw});

  final double depth;
  final void Function(Canvas canvas) draw;
}

/// CustomPainter rendering Nasuka using smooth 3D-projected curved silhouettes,
/// clay-like gradients, and depth-split 3D rings so entering/exiting passes
/// cleanly through the lifebuoy and bubble ring.
class Nasuka3dPainter extends CustomPainter {
  const Nasuka3dPainter({required this.pose});

  final Nasuka3dPose pose;

  static const Color _bodyLight = Color(0xFF935EC4);
  static const Color _bodyMid = Color(0xFF5D2A82);
  static const Color _bodyShadow = Color(0xFF2D0F45);
  static const Color _bodyRim = Color(0x78C49AF0);
  static const Color _beakHighlight = Color(0xFFA2AA6E);
  static const Color _beakLight = Color(0xFF7B844C);
  static const Color _beakDark = Color(0xFF4B522D);
  static const Color _mouthPink = Color(0xFFE6979C);
  static const Color _eyeBlack = Color(0xFF0B0D14);
  static const Color _eyeSclera = Color(0xFFF7F4FC);
  static const Color _winkHighlight = Color(0xFFF5ECFF);
  static const Color _sadLidEdge = Color(0xFFCDA8F2);
  static const Color _lifebuoyRed = Color(0xFFE53935);
  static const Color _lifebuoyWhite = Color(0xFFF9FAFB);

  // Shuffled distinct feather palettes per body part (crest, wings, tail).
  static const List<Color> _crestPalette = [
    Color(0xFF22C3D8),
    Color(0xFFF04E8A),
    Color(0xFFF8D836),
    Color(0xFF3A6FE8),
    Color(0xFF92DC34),
  ];

  static const List<Color> _wingTipPalette = [
    Color(0xFFF462A8),
    Color(0xFFFCE238),
    Color(0xFF78D64B),
    Color(0xFF3E78F0),
    Color(0xFFFF7A45),
  ];

  static const List<Color> _tailTipPalette = [
    Color(0xFF3B7BF2),
    Color(0xFFFF8C2B),
    Color(0xFFEF4D56),
    Color(0xFF8BE03A),
    Color(0xFFC85CE6),
  ];

  static const double _cameraDist = 4.9;

  /// Default three-quarter left-facing dolphin angle matching the classic
  /// assistant silhouette (head upper-left, curved back, tail down-right).
  static const double _baseYaw = -1.04;
  static const double _basePitch = -0.06;

  @override
  bool shouldRepaint(covariant Nasuka3dPainter oldDelegate) =>
      oldDelegate.pose != pose;

  @override
  void paint(Canvas canvas, Size size) {
    if (size.isEmpty || pose.stage == HomeAssistantStage.hidden) return;

    final t = pose.idleTime;
    final st = pose.stageProgress.clamp(0.0, 1.0);
    final act = pose.actionProgress.clamp(0.0, 1.0);
    final isSad = pose.sad || pose.stage == HomeAssistantStage.exiting;

    var bodyPos = _Vec3(0.02, 0.045 * math.sin(t * 2.2), 0.0);
    var bodyYaw = _baseYaw + 0.06 * math.sin(t * 1.15);
    var bodyPitch = _basePitch + 0.04 * math.cos(t * 1.8);
    var bodyRoll = 0.03 * math.sin(t * 1.6);
    var bodyScale = 1.0;
    var bodyOpacity = 1.0;
    var swimAmp = 0.045;
    var swimPhase = t * 2.8;
    var flapAngle = 0.08 * math.sin(t * 2.4);
    var mouthOpen = pose.speaking
        ? (0.14 + 0.36 * math.sin(t * 14.0).abs())
        : 0.14;
    var winking = false;

    double? ringCenterZ;
    var hasRing = false;
    var isLifebuoy = false;
    var ringCenter = const _Vec3(0, 0, 0);
    var ringMajor = 0.0;
    var ringMinor = 0.0;
    var ringYaw = -0.25;
    var ringPitch = 0.18;
    var ringOpacity = 0.0;
    var splashT = -1.0;
    var exitBubblesT = -1.0;

    if (pose.stage == HomeAssistantStage.entering) {
      final swimThru = ((st - 0.18) / 0.62).clamp(0.0, 1.0);
      final eased = Curves.easeOutCubic.transform(swimThru);
      bodyPos = _Vec3(
        -0.08 * (1.0 - eased) + 0.02,
        0.16 * math.sin(swimThru * math.pi),
        -2.25 + 2.25 * eased,
      );
      bodyScale = 0.45 + 0.55 * eased;
      bodyOpacity = (swimThru * 3.2).clamp(0.0, 1.0);
      bodyYaw = -0.45 + (_baseYaw + 0.45) * eased;
      bodyPitch = -0.18 * math.cos(swimThru * math.pi);
      flapAngle = 0.55 * math.sin(st * math.pi * 6.0);
      swimAmp = 0.11;
      swimPhase = st * 14.0;
      mouthOpen = 0.38;

      final ringScale = st < 0.36
          ? Curves.easeOutBack.transform((st / 0.36).clamp(0.0, 1.0))
          : (st > 0.74
                ? 1.0 -
                      Curves.easeInCubic.transform(
                        ((st - 0.74) / 0.26).clamp(0.0, 1.0),
                      )
                : 1.0);
      if (ringScale > 0.02) {
        hasRing = true;
        isLifebuoy = true;
        ringCenter = const _Vec3(-0.08, 0.04, 0.16);
        ringCenterZ = ringCenter.z;
        ringMajor = 0.86 * ringScale;
        ringMinor = 0.19 * ringScale;
        ringYaw = -0.42;
        ringPitch = 0.24;
        ringOpacity = ringScale.clamp(0.0, 1.0);
      }
      if (st >= 0.38 && st <= 0.92) {
        splashT = ((st - 0.38) / 0.54).clamp(0.0, 1.0);
      }
    } else if (pose.stage == HomeAssistantStage.exiting) {
      bodyYaw = _baseYaw;
      bodyPitch = 0.16;
      if (st < 0.28) {
        final p = st / 0.28;
        mouthOpen = 0.10 + 0.58 * math.sin(p * math.pi * 0.5);
        bodyPitch = 0.10 + 0.14 * p;
      } else if (st < 0.54) {
        final p = (st - 0.28) / 0.26;
        mouthOpen = 0.68 * (1.0 - p) + 0.08;
        bodyYaw = _baseYaw + 0.48 * p;
      } else {
        final dive = ((st - 0.48) / 0.48).clamp(0.0, 1.0);
        final eased = Curves.easeInCubic.transform(dive);
        bodyPos = _Vec3(
          0.06 * eased,
          -0.06 * math.sin(dive * math.pi),
          -2.45 * eased,
        );
        bodyScale = (1.0 - 0.92 * eased).clamp(0.06, 1.0);
        bodyOpacity = (1.0 - math.pow(dive, 2.2)).clamp(0.0, 1.0);
        bodyYaw = _baseYaw + 0.48 + 0.45 * eased;
        bodyPitch = 0.22;
        mouthOpen = 0.08;
        flapAngle = 0.26 * math.sin(dive * math.pi * 4.0);
      }

      if (st >= 0.18) {
        final birth = ((st - 0.18) / 0.36).clamp(0.0, 1.0);
        final ringScale = Curves.easeOutCubic.transform(birth);
        final ringFade = st > 0.80
            ? (1.0 - (st - 0.80) / 0.20).clamp(0.0, 1.0)
            : 1.0;
        final ringGrow = st > 0.80 ? (st - 0.80) * 1.2 : 0.0;
        if (ringFade > 0.02) {
          hasRing = true;
          isLifebuoy = false;
          ringCenter = _Vec3(
            -0.36 + 0.24 * birth,
            0.04 + 0.04 * birth,
            0.55 - 0.22 * birth,
          );
          ringCenterZ = ringCenter.z;
          ringMajor = 0.16 + 0.68 * ringScale + ringGrow;
          ringMinor = (0.04 + 0.11 * ringScale) * (1.0 - 0.3 * ringGrow);
          ringYaw = -0.32;
          ringPitch = 0.16;
          ringOpacity = 0.82 * ringFade;
          exitBubblesT = ((st - 0.18) / 0.82).clamp(0.0, 1.0);
        }
      }
    } else {
      switch (pose.action) {
        case NasukaAction.float:
          break;
        case NasukaAction.wink:
          winking = act > 0.12 && act < 0.88;
          final tilt = math.sin(act * math.pi);
          bodyRoll += 0.22 * tilt;
          bodyYaw += 0.18 * tilt;
        case NasukaAction.flap:
          flapAngle = 0.78 * math.sin(act * math.pi * 6.0);
          bodyPos = _Vec3(
            bodyPos.x,
            bodyPos.y + 0.12 * math.sin(act * math.pi),
            bodyPos.z,
          );
        case NasukaAction.spin:
          final spun = Curves.easeInOutCubic.transform(act);
          bodyYaw += spun * math.pi * 2.0;
          bodyRoll += 0.12 * math.sin(act * math.pi * 2.0);
        case NasukaAction.swim:
          swimAmp = 0.16;
          swimPhase = t * 2.8 + act * math.pi * 6.0;
          flapAngle = 0.38 * math.sin(act * math.pi * 4.0);
          bodyPos = _Vec3(
            0.14 * math.sin(act * math.pi * 2.0),
            bodyPos.y + 0.08 * math.cos(act * math.pi * 2.0),
            bodyPos.z,
          );
          bodyRoll += 0.16 * math.sin(act * math.pi * 2.0);
      }
    }

    if (isSad && pose.stage != HomeAssistantStage.exiting) {
      mouthOpen = 0.08;
    }

    _Vec3 xform(_Vec3 local) => _transformPoint(
      local,
      worldPos: bodyPos,
      yaw: bodyYaw,
      pitch: bodyPitch,
      roll: bodyRoll,
      scale: bodyScale,
      swimAmp: swimAmp,
      swimPhase: swimPhase,
    );

    // Draw back half of ring -> full seamless Nasuka -> front half of ring -> front head/flipper pass.
    if (hasRing) {
      _drawRingHalf(
        canvas,
        size: size,
        center: ringCenter,
        majorRadius: ringMajor,
        minorRadius: ringMinor,
        yaw: ringYaw,
        pitch: ringPitch,
        isLifebuoy: isLifebuoy,
        opacity: ringOpacity,
        drawBackHalf: true,
      );
    }

    if (bodyOpacity > 0.01) {
      _drawNasukaSlice(
        canvas,
        size: size,
        xform: xform,
        bodyScale: bodyScale,
        opacity: bodyOpacity,
        flapAngle: flapAngle,
        mouthOpen: mouthOpen,
        swimAmp: swimAmp,
        swimPhase: swimPhase,
        winking: winking,
        sad: isSad,
        drawRim: true,
      );
    }

    if (hasRing) {
      _drawRingHalf(
        canvas,
        size: size,
        center: ringCenter,
        majorRadius: ringMajor,
        minorRadius: ringMinor,
        yaw: ringYaw,
        pitch: ringPitch,
        isLifebuoy: isLifebuoy,
        opacity: ringOpacity,
        drawBackHalf: false,
      );
      if (bodyOpacity > 0.01 && ringCenterZ != null) {
        _drawNasukaSlice(
          canvas,
          size: size,
          xform: xform,
          bodyScale: bodyScale,
          opacity: bodyOpacity,
          flapAngle: flapAngle,
          mouthOpen: mouthOpen,
          swimAmp: swimAmp,
          swimPhase: swimPhase,
          winking: winking,
          sad: isSad,
          ringCutoffWorldZ: ringCenterZ,
          drawBehindRing: false,
          drawRim: false,
        );
      }
    }

    if (splashT >= 0.0) {
      _drawWaterSplash(canvas, size: size, splashT: splashT);
    }
    if (exitBubblesT >= 0.0) {
      _drawExitBubbles(canvas, size: size, progress: exitBubblesT);
    }
  }

  _Vec3 _transformPoint(
    _Vec3 local, {
    required _Vec3 worldPos,
    required double yaw,
    required double pitch,
    required double roll,
    required double scale,
    required double swimAmp,
    required double swimPhase,
  }) {
    final tailWeight = ((-local.z + 0.55).clamp(0.0, 2.0)) / 2.0;
    final swayX = swimAmp * tailWeight * math.sin(swimPhase + local.z * 2.1);
    var p = _Vec3((local.x + swayX) * scale, local.y * scale, local.z * scale);
    p = p.rotateZ(roll).rotateX(pitch).rotateY(yaw);
    return p + worldPos;
  }

  ({Offset screen, double viewZ, double pxPerUnit}) _project(
    _Vec3 world,
    Size size,
  ) {
    final zFromCam = _cameraDist - world.z;
    final safeZ = zFromCam < 0.65 ? 0.65 : zFromCam;
    final focal = math.min(size.width, size.height) * 1.42;
    final sx = size.width * 0.5 + (world.x / safeZ) * focal;
    final sy = size.height * 0.54 - (world.y / safeZ) * focal;
    return (screen: Offset(sx, sy), viewZ: safeZ, pxPerUnit: focal / safeZ);
  }

  List<_SpineNode> _buildSpineNodes(
    Size size,
    _Vec3 Function(_Vec3) xform,
    double bodyScale,
  ) {
    // 26 smooth arched spine spheres: plump forehead, sleek waist, curved-down tail.
    const steps = 26;
    final nodes = <_SpineNode>[];
    for (var i = 0; i < steps; i++) {
      final u = i / (steps - 1); // 0 = front forehead, 1 = tail tip
      final z = 0.84 - u * 2.00; // +0.84 .. -1.16
      // Smooth dolphin-bird arch: rises gently across brow, then sweeps gracefully down.
      final archY = 0.22 + 0.08 * math.sin(u * math.pi * 0.85) - 0.48 * math.pow(u, 2.15);
      // Chubby round head peaking near u=0.18, sleek taper to tail u=1.0.
      final radius = u < 0.18
          ? 0.34 + 0.21 * math.sin((u / 0.18) * math.pi * 0.5)
          : 0.55 - 0.43 * math.pow((u - 0.18) / 0.82, 1.35);
      final w = xform(_Vec3(0, archY, z));
      final p = _project(w, size);
      nodes.add(
        _SpineNode(
          center: w,
          radius: radius * bodyScale,
          screen: p.screen,
          screenRadius: radius * bodyScale * p.pxPerUnit,
          viewZ: p.viewZ,
        ),
      );
    }
    return nodes;
  }

  Path _buildSmoothCapsuleEnvelopePath(List<_SpineNode> nodes) {
    final path = Path()..fillType = PathFillType.nonZero;
    for (var i = 0; i < nodes.length; i++) {
      final n = nodes[i];
      path.addOval(Rect.fromCircle(center: n.screen, radius: n.screenRadius));
      if (i + 1 < nodes.length) {
        final next = nodes[i + 1];
        final d = next.screen - n.screen;
        final dist = d.distance;
        final rDiff = (n.screenRadius - next.screenRadius).abs();
        if (dist > 0.5 && dist > rDiff + 0.2) {
          final dir = Offset(d.dx / dist, d.dy / dist);
          final perp = Offset(-dir.dy, dir.dx);
          final cosA = ((n.screenRadius - next.screenRadius) / dist).clamp(-0.96, 0.96);
          final sinA = math.sqrt(math.max(0.0, 1.0 - cosA * cosA));
          final uTop = Offset(dir.dx * cosA + perp.dx * sinA, dir.dy * cosA + perp.dy * sinA);
          final uBot = Offset(dir.dx * cosA - perp.dx * sinA, dir.dy * cosA - perp.dy * sinA);
          final p1 = n.screen + uTop * n.screenRadius;
          final p2 = next.screen + uTop * next.screenRadius;
          final p3 = next.screen + uBot * next.screenRadius;
          final p4 = n.screen + uBot * n.screenRadius;
          path
            ..moveTo(p1.dx, p1.dy)
            ..lineTo(p4.dx, p4.dy)
            ..lineTo(p3.dx, p3.dy)
            ..lineTo(p2.dx, p2.dy)
            ..close();
        }
      }
    }
    return path;
  }

  void _drawClayBody(
    Canvas canvas,
    List<_SpineNode> nodes,
    double opacity, {
    List<_SpineNode>? shaderBoundsNodes,
    bool drawRim = true,
  }) {
    if (nodes.isEmpty) return;
    final bodyPath = _buildSmoothCapsuleEnvelopePath(nodes);
    final boundsSource = shaderBoundsNodes ?? nodes;
    final bounds = _buildSmoothCapsuleEnvelopePath(boundsSource).getBounds();
    if (bounds.isEmpty) return;

    final alpha = (opacity * 255.0).round().clamp(0, 255);
    // 1) Luminous lavender rim pass separating the dark eggplant body from dark backgrounds.
    if (drawRim) {
      canvas.drawPath(
        bodyPath,
        Paint()
          ..color = _bodyRim.withAlpha((_bodyRim.a * opacity * 255).round())
          ..style = PaintingStyle.stroke
          ..strokeWidth = 2.3
          ..strokeJoin = StrokeJoin.round,
      );
    }

    // 2) Smooth glossy eggplant shading fill across the entire silhouette.
    final centerHint = Offset(
      bounds.left + bounds.width * 0.34,
      bounds.top + bounds.height * 0.28,
    );
    final gradRadius = math.max(bounds.width, bounds.height) * 0.85;
    final bodyShader = RadialGradient(
      center: Alignment(
        ((centerHint.dx - bounds.center.dx) / (bounds.width * 0.5)).clamp(-1.0, 1.0),
        ((centerHint.dy - bounds.center.dy) / (bounds.height * 0.5)).clamp(-1.0, 1.0),
      ),
      radius: 1.15,
      colors: [
        _bodyLight.withAlpha(alpha),
        _bodyMid.withAlpha(alpha),
        _bodyShadow.withAlpha(alpha),
      ],
      stops: const [0.0, 0.52, 1.0],
    ).createShader(Rect.fromCircle(center: bounds.center, radius: gradRadius));

    canvas.drawPath(
      bodyPath,
      Paint()
        ..shader = bodyShader
        ..style = PaintingStyle.fill
        ..isAntiAlias = true,
    );

    // 3) Waxy upper-back eggplant sheen & soft purple ambient bounce clipped to silhouette.
    canvas.save();
    canvas.clipPath(bodyPath);
    canvas.drawOval(
      Rect.fromCenter(
        center: Offset(
          bounds.left + bounds.width * 0.42,
          bounds.top + bounds.height * 0.28,
        ),
        width: bounds.width * 0.56,
        height: bounds.height * 0.18,
      ),
      Paint()
        ..color = const Color(0xFFF5E8FF).withAlpha((0.30 * alpha).round())
        ..maskFilter = const MaskFilter.blur(BlurStyle.normal, 4.5),
    );
    canvas.drawOval(
      Rect.fromCenter(
        center: Offset(
          bounds.left + bounds.width * 0.44,
          bounds.bottom - bounds.height * 0.14,
        ),
        width: bounds.width * 0.80,
        height: bounds.height * 0.30,
      ),
      Paint()
        ..color = const Color(0xFF8A54BD).withAlpha((0.22 * alpha).round())
        ..maskFilter = const MaskFilter.blur(BlurStyle.normal, 4),
    );
    canvas.restore();
  }

  void _drawNasukaSlice(
    Canvas canvas, {
    required Size size,
    required _Vec3 Function(_Vec3) xform,
    required double bodyScale,
    required double opacity,
    required double flapAngle,
    required double mouthOpen,
    required double swimAmp,
    required double swimPhase,
    required bool winking,
    required bool sad,
    double? ringCutoffWorldZ,
    bool? drawBehindRing,
    bool drawRim = true,
  }) {
    final allNodes = _buildSpineNodes(size, xform, bodyScale);
    final nodes = ringCutoffWorldZ == null || drawBehindRing == null
        ? allNodes
        : [
            for (final n in allNodes)
              if (drawBehindRing
                  ? n.center.z < ringCutoffWorldZ
                  : n.center.z >= ringCutoffWorldZ)
                n,
          ];
    final bodyAvgDepth = allNodes.fold<double>(0, (s, n) => s + n.viewZ) / allNodes.length;

    final backParts = <_PartDraw>[];
    final frontParts = <_PartDraw>[];

    bool passesSlice(_Vec3 worldPos) {
      if (ringCutoffWorldZ == null || drawBehindRing == null) return true;
      return drawBehindRing
          ? worldPos.z < ringCutoffWorldZ
          : worldPos.z >= ringCutoffWorldZ;
    }

    void addPart(_Vec3 anchorWorld, double depth, void Function(Canvas) draw) {
      if (!passesSlice(anchorWorld)) return;
      final item = _PartDraw(depth: depth, draw: draw);
      if (depth >= bodyAvgDepth) {
        backParts.add(item);
      } else {
        frontParts.add(item);
      }
    }

    // 1) Dorsal rainbow crest (5 lush curved feathers fanning from a tight crown plume).
    _collectDorsalCrest(size: size, xform: xform, opacity: opacity, addPart: addPart);

    // 2) Tail fluke (bi-lobed white tail tilted cleanly + rainbow feather tips).
    _collectTailFluke(
      size: size,
      xform: xform,
      swimPhase: swimPhase,
      swimAmp: swimAmp,
      opacity: opacity,
      addPart: addPart,
    );

    // 3) Pectoral flippers (left & right).
    for (final side in const [-1.0, 1.0]) {
      _collectPectoralFlipper(
        size: size,
        side: side,
        flapAngle: flapAngle,
        xform: xform,
        opacity: opacity,
        addPart: addPart,
      );
    }

    // 4) Beak (plump rounded grey upper/lower beak + pink mouth).
    _collectBeak(
      size: size,
      xform: xform,
      bodyScale: bodyScale,
      mouthOpen: mouthOpen,
      opacity: opacity,
      addPart: addPart,
    );

    // 5) Large glossy black eyes (determine which visible eye winks).
    var winkSide = 1.0;
    var bestFacing = -1.0;
    for (final side in const [-1.0, 1.0]) {
      final c = xform(_Vec3(side * 0.40, 0.22, 0.62));
      final o = xform(_Vec3(side * 0.68, 0.25, 0.78));
      final facing = (o - c).normalized().dot(
        _Vec3(-c.x, -c.y, _cameraDist - c.z).normalized(),
      );
      if (facing > bestFacing) {
        bestFacing = facing;
        winkSide = side;
      }
    }
    for (final side in const [-1.0, 1.0]) {
      _collectEye(
        size: size,
        side: side,
        xform: xform,
        bodyScale: bodyScale,
        opacity: opacity,
        winking: winking && side == winkSide,
        sad: sad,
        addPart: addPart,
      );
    }

    backParts.sort((a, b) => b.depth.compareTo(a.depth));
    frontParts.sort((a, b) => b.depth.compareTo(a.depth));

    for (final p in backParts) {
      p.draw(canvas);
    }
    _drawClayBody(
      canvas,
      nodes,
      opacity,
      shaderBoundsNodes: allNodes,
      drawRim: drawRim,
    );
    for (final p in frontParts) {
      p.draw(canvas);
    }
  }

  void _drawCurvedFeather(
    Canvas canvas, {
    required Offset base,
    required Offset tip,
    required Color color,
    required double widthPx,
    required double opacity,
  }) {
    final vec = tip - base;
    final len = vec.distance;
    if (len < 1.5) return;
    final dir = Offset(vec.dx / len, vec.dy / len);
    final perp = Offset(-dir.dy, dir.dx);
    final midA = base + dir * (len * 0.42) + perp * (widthPx * 0.58);
    final midB = base + dir * (len * 0.42) - perp * (widthPx * 0.58);

    final path = Path()
      ..moveTo(base.dx, base.dy)
      ..quadraticBezierTo(midA.dx, midA.dy, tip.dx, tip.dy)
      ..quadraticBezierTo(midB.dx, midB.dy, base.dx, base.dy)
      ..close();

    final alpha = (opacity * 255.0).round().clamp(0, 255);
    final lighter = Color.lerp(color, Colors.white, 0.28)!.withAlpha(alpha);
    final deeper = Color.lerp(color, const Color(0xFF1A1E28), 0.16)!.withAlpha(alpha);

    canvas.drawPath(
      path,
      Paint()
        ..shader = LinearGradient(
          begin: Alignment.topLeft,
          end: Alignment.bottomRight,
          colors: [lighter, color.withAlpha(alpha), deeper],
          stops: const [0.0, 0.55, 1.0],
        ).createShader(path.getBounds())
        ..style = PaintingStyle.fill
        ..isAntiAlias = true,
    );
    canvas.drawPath(
      path,
      Paint()
        ..color = Color.fromARGB((0.22 * alpha).round(), 30, 35, 45)
        ..style = PaintingStyle.stroke
        ..strokeWidth = 0.7,
    );
  }

  void _collectDorsalCrest({
    required Size size,
    required _Vec3 Function(_Vec3) xform,
    required double opacity,
    required void Function(_Vec3 anchorWorld, double depth, void Function(Canvas) draw)
    addPart,
  }) {
    // Cluster all 5 crest feathers tightly behind the forehead like a cockatoo plume.
    const featherAngles = <double>[-0.18, 0.08, 0.34, 0.58, 0.80];
    const featherLengths = <double>[0.58, 0.56, 0.52, 0.46, 0.39];
    for (var i = 0; i < _crestPalette.length; i++) {
      final frac = i / (_crestPalette.length - 1);
      final zRoot = 0.22 - frac * 0.18;
      final yRoot = 0.66 - frac * 0.06;
      final a = featherAngles[i];
      final l = featherLengths[i];
      final fanX = (i == 0 ? 0.0 : (i.isEven ? -0.04 : 0.04)) * (0.6 + frac);
      final rootW = xform(_Vec3(0, yRoot, zRoot));
      final tipW = xform(
        _Vec3(
          fanX * 2.1,
          yRoot + l * math.cos(a),
          zRoot - l * math.sin(a) - 0.08,
        ),
      );
      final pRoot = _project(rootW, size);
      final pTip = _project(tipW, size);
      final widthPx = (pTip.screen - pRoot.screen).distance * 0.38;
      final color = _crestPalette[i];
      final depth = (pRoot.viewZ + pTip.viewZ) * 0.5 + 0.05;
      addPart(rootW, depth, (canvas) {
        _drawCurvedFeather(
          canvas,
          base: pRoot.screen,
          tip: pTip.screen,
          color: color,
          widthPx: math.max(5.5, widthPx),
          opacity: opacity,
        );
      });
    }
  }

  void _collectPectoralFlipper({
    required Size size,
    required double side,
    required double flapAngle,
    required _Vec3 Function(_Vec3) xform,
    required double opacity,
    required void Function(_Vec3 anchorWorld, double depth, void Function(Canvas) draw)
    addPart,
  }) {
    _Vec3 wingXform(_Vec3 p) {
      final anchor = _Vec3(side * 0.28, -0.02, 0.16);
      final rel = p - anchor;
      final rot = rel.rotateZ(side * flapAngle);
      return xform(rot + anchor);
    }

    final rootFW = wingXform(_Vec3(side * 0.28, 0.00, 0.28));
    final rootBW = wingXform(_Vec3(side * 0.26, -0.06, -0.02));
    final tipW = wingXform(_Vec3(side * 0.90, -0.46, 0.04));
    final outerMidW = wingXform(_Vec3(side * 0.72, -0.21, 0.24));
    final innerMidW = wingXform(_Vec3(side * 0.58, -0.32, -0.08));

    final pRF = _project(rootFW, size);
    final pRB = _project(rootBW, size);
    final pTip = _project(tipW, size);
    final pOM = _project(outerMidW, size);
    final pIM = _project(innerMidW, size);
    final avgDepth = (pRF.viewZ + pTip.viewZ + pRB.viewZ) / 3.0;

    final tipFeathers = <({Offset base, Offset tip, Color color})>[];
    for (var i = 0; i < _wingTipPalette.length; i++) {
      final frac = i / (_wingTipPalette.length - 1);
      final bW = wingXform(_Vec3(
        side * (0.85 - frac * 0.24),
        -0.41 + frac * 0.10,
        0.04 - frac * 0.14,
      ));
      final tW = wingXform(_Vec3(
        side * (1.12 - frac * 0.30),
        -0.58 + frac * 0.15,
        -0.02 - frac * 0.20,
      ));
      tipFeathers.add((
        base: _project(bW, size).screen,
        tip: _project(tW, size).screen,
        color: _wingTipPalette[i],
      ));
    }

    addPart(tipW, avgDepth, (canvas) {
      for (final f in tipFeathers) {
        final len = (f.tip - f.base).distance;
        _drawCurvedFeather(
          canvas,
          base: f.base,
          tip: f.tip,
          color: f.color,
          widthPx: math.max(5.0, len * 0.46),
          opacity: opacity,
        );
      }

      final wingPath = Path()
        ..moveTo(pRF.screen.dx, pRF.screen.dy)
        ..quadraticBezierTo(pOM.screen.dx, pOM.screen.dy, pTip.screen.dx, pTip.screen.dy)
        ..quadraticBezierTo(pIM.screen.dx, pIM.screen.dy, pRB.screen.dx, pRB.screen.dy)
        ..close();

      final alpha = (opacity * 255.0).round().clamp(0, 255);
      final bounds = wingPath.getBounds();
      canvas.drawPath(
        wingPath,
        Paint()
          ..shader = LinearGradient(
            begin: Alignment.topLeft,
            end: Alignment.bottomRight,
            colors: [
              _bodyLight.withAlpha(alpha),
              _bodyMid.withAlpha(alpha),
              _bodyShadow.withAlpha(alpha),
            ],
            stops: const [0.0, 0.48, 1.0],
          ).createShader(bounds)
          ..style = PaintingStyle.fill
          ..isAntiAlias = true,
      );
      // Stroke only from mid-wing outward so the shoulder merges seamlessly into the chest.
      final edgeStart = Offset.lerp(pRF.screen, pOM.screen, 0.45)!;
      final outerEdge = Path()
        ..moveTo(edgeStart.dx, edgeStart.dy)
        ..quadraticBezierTo(pOM.screen.dx, pOM.screen.dy, pTip.screen.dx, pTip.screen.dy)
        ..quadraticBezierTo(pIM.screen.dx, pIM.screen.dy, pRB.screen.dx, pRB.screen.dy);
      canvas.drawPath(
        outerEdge,
        Paint()
          ..color = _bodyRim.withAlpha((_bodyRim.a * opacity * 255).round())
          ..style = PaintingStyle.stroke
          ..strokeWidth = 0.9,
      );
    });
  }

  void _collectTailFluke({
    required Size size,
    required _Vec3 Function(_Vec3) xform,
    required double swimPhase,
    required double swimAmp,
    required double opacity,
    required void Function(_Vec3 anchorWorld, double depth, void Function(Canvas) draw)
    addPart,
  }) {
    final tailPitch = swimAmp * 1.8 * math.sin(swimPhase - 1.2);
    // Tilt the bi-lobed tail fluke slightly (roll + pitch) so both wings read cleanly in 3/4 view.
    _Vec3 tailXform(_Vec3 p) {
      const anchor = _Vec3(0.0, -0.24, -1.14);
      final rel = p - anchor;
      final rot = rel.rotateZ(0.42).rotateX(tailPitch - 0.28);
      return xform(rot + anchor);
    }

    final rootW = tailXform(const _Vec3(0, -0.24, -1.10));
    final centerNotchW = tailXform(const _Vec3(0, -0.26, -1.42));
    final lobeLW = tailXform(const _Vec3(-0.62, -0.30, -1.58));
    final lobeRW = tailXform(const _Vec3(0.62, -0.30, -1.58));
    final leadLW = tailXform(const _Vec3(-0.38, -0.25, -1.24));
    final leadRW = tailXform(const _Vec3(0.38, -0.25, -1.24));

    final pRoot = _project(rootW, size);
    final pNotch = _project(centerNotchW, size);
    final pLobeL = _project(lobeLW, size);
    final pLobeR = _project(lobeRW, size);
    final pLeadL = _project(leadLW, size);
    final pLeadR = _project(leadRW, size);

    final tailFeathers = <({Offset base, Offset tip, Color color})>[];
    for (final side in const [-1.0, 1.0]) {
      for (var i = 0; i < _tailTipPalette.length; i++) {
        final frac = i / (_tailTipPalette.length - 1);
        final bW = tailXform(_Vec3(
          side * (0.60 - frac * 0.44),
          -0.30 + frac * 0.03,
          -1.56 + frac * 0.14,
        ));
        final tW = tailXform(_Vec3(
          side * (0.84 - frac * 0.58),
          -0.33 + frac * 0.03,
          -1.78 + frac * 0.14,
        ));
        tailFeathers.add((
          base: _project(bW, size).screen,
          tip: _project(tW, size).screen,
          color: _tailTipPalette[i],
        ));
      }
    }

    final depth = pNotch.viewZ;
    addPart(centerNotchW, depth, (canvas) {
      for (final f in tailFeathers) {
        final len = (f.tip - f.base).distance;
        _drawCurvedFeather(
          canvas,
          base: f.base,
          tip: f.tip,
          color: f.color,
          widthPx: math.max(4.5, len * 0.46),
          opacity: opacity,
        );
      }

      final flukePath = Path()
        ..moveTo(pRoot.screen.dx, pRoot.screen.dy)
        ..quadraticBezierTo(pLeadL.screen.dx, pLeadL.screen.dy, pLobeL.screen.dx, pLobeL.screen.dy)
        ..quadraticBezierTo(
          (pLobeL.screen.dx + pNotch.screen.dx) * 0.5,
          (pLobeL.screen.dy + pNotch.screen.dy) * 0.5 + 3.0,
          pNotch.screen.dx,
          pNotch.screen.dy,
        )
        ..quadraticBezierTo(
          (pLobeR.screen.dx + pNotch.screen.dx) * 0.5,
          (pLobeR.screen.dy + pNotch.screen.dy) * 0.5 + 3.0,
          pLobeR.screen.dx,
          pLobeR.screen.dy,
        )
        ..quadraticBezierTo(pLeadR.screen.dx, pLeadR.screen.dy, pRoot.screen.dx, pRoot.screen.dy)
        ..close();

      final alpha = (opacity * 255.0).round().clamp(0, 255);
      canvas.drawPath(
        flukePath,
        Paint()
          ..shader = LinearGradient(
            begin: Alignment.topCenter,
            end: Alignment.bottomCenter,
            colors: [
              _bodyLight.withAlpha(alpha),
              _bodyMid.withAlpha(alpha),
              _bodyShadow.withAlpha(alpha),
            ],
            stops: const [0.0, 0.48, 1.0],
          ).createShader(flukePath.getBounds())
          ..style = PaintingStyle.fill
          ..isAntiAlias = true,
      );
      canvas.drawPath(
        flukePath,
        Paint()
          ..color = _bodyRim.withAlpha((_bodyRim.a * opacity * 255).round())
          ..style = PaintingStyle.stroke
          ..strokeWidth = 0.85,
      );
    });
  }

  void _collectBeak({
    required Size size,
    required _Vec3 Function(_Vec3) xform,
    required double bodyScale,
    required double mouthOpen,
    required double opacity,
    required void Function(_Vec3 anchorWorld, double depth, void Function(Canvas) draw)
    addPart,
  }) {
    // Anchor at front snout (z=1.04..1.42) using smooth 3D capsule envelopes so the
    // beak joins the head cleanly without intersecting lines or polygon seams.
    final anchorW = xform(const _Vec3(0, 0.13, 1.18));
    final tipProj = _project(xform(const _Vec3(0, 0.12, 1.38)), size);
    final depth = tipProj.viewZ;
    final alpha = (opacity * 255.0).round().clamp(0, 255);

    final jawAngle = mouthOpen.clamp(0.08, 0.85) * 0.62;
    _Vec3 jaw(_Vec3 p) {
      const hinge = _Vec3(0, 0.11, 1.04);
      final rot = (p - hinge).rotateX(jawAngle);
      return xform(rot + hinge);
    }

    _SpineNode nodeAt(_Vec3 w, double r) {
      final p = _project(w, size);
      return _SpineNode(
        center: w,
        radius: r * bodyScale,
        screen: p.screen,
        screenRadius: r * bodyScale * p.pxPerUnit,
        viewZ: p.viewZ,
      );
    }

    final upperNodes = <_SpineNode>[
      for (var i = 0; i < 10; i++)
        () {
          final t = i / 9.0;
          final y = 0.14 + 0.04 * math.sin(t * math.pi * 0.85) - 0.065 * math.pow(t, 2.2);
          final z = 0.98 + t * 0.41;
          final r = 0.135 * (1.0 - math.pow(t, 1.5) * 0.74);
          return nodeAt(xform(_Vec3(0, y, z)), r);
        }(),
    ];

    final lowerNodes = <_SpineNode>[
      for (var i = 0; i < 8; i++)
        () {
          final t = i / 7.0;
          final y = 0.095 - 0.045 * math.sin(t * math.pi * 0.75) + 0.02 * math.pow(t, 2.0);
          final z = 1.00 + t * 0.34;
          final r = 0.105 * (1.0 - math.pow(t, 1.55) * 0.68);
          return nodeAt(jaw(_Vec3(0, y, z)), r);
        }(),
    ];

    final pHinge = _project(xform(const _Vec3(0, 0.105, 1.00)), size).screen;
    final pUInner = _project(xform(const _Vec3(0, 0.125, 1.31)), size).screen;
    final pLInner = _project(jaw(const _Vec3(0, 0.075, 1.28)), size).screen;

    addPart(anchorW, depth, (canvas) {
      // 1) Lower plump grey capsule beak.
      final lowerPath = _buildSmoothCapsuleEnvelopePath(lowerNodes);
      final lowerBounds = lowerPath.getBounds();
      if (!lowerBounds.isEmpty) {
        canvas.drawPath(
          lowerPath,
          Paint()
            ..shader = LinearGradient(
              begin: Alignment.topCenter,
              end: Alignment.bottomCenter,
              colors: [_beakLight.withAlpha(alpha), _beakDark.withAlpha(alpha)],
            ).createShader(lowerBounds)
            ..style = PaintingStyle.fill
            ..isAntiAlias = true,
        );
      }

      // 2) Warm dark mouth recess + pink tongue inside open jaws.
      if (jawAngle > 0.06) {
        final midFront = Offset.lerp(pUInner, pLInner, 0.5)!;
        final mouthPath = Path()
          ..moveTo(pHinge.dx, pHinge.dy)
          ..lineTo(pUInner.dx, pUInner.dy)
          ..quadraticBezierTo(midFront.dx, midFront.dy, pLInner.dx, pLInner.dy)
          ..lineTo(pHinge.dx, pHinge.dy)
          ..close();
        canvas.drawPath(
          mouthPath,
          Paint()
            ..color = Color.fromARGB(alpha, 62, 45, 48)
            ..style = PaintingStyle.fill
            ..isAntiAlias = true,
        );
        final mouthSpan = (pLInner - pHinge).distance;
        if (mouthSpan > 2.0) {
          canvas.save();
          canvas.clipPath(mouthPath);
          final tongueCenter = Offset.lerp(
            Offset.lerp(pHinge, pLInner, 0.55)!,
            pUInner,
            0.22,
          )!;
          canvas.drawOval(
            Rect.fromCenter(
              center: tongueCenter,
              width: mouthSpan * 0.65,
              height: mouthSpan * 0.42,
            ),
            Paint()
              ..color = _mouthPink.withAlpha(alpha)
              ..style = PaintingStyle.fill
              ..isAntiAlias = true,
          );
          canvas.restore();
        }
      }

      // 3) Upper plump rounded grey capsule beak + soft top clay sheen.
      final upperPath = _buildSmoothCapsuleEnvelopePath(upperNodes);
      final upperBounds = upperPath.getBounds();
      if (!upperBounds.isEmpty) {
        canvas.drawPath(
          upperPath,
          Paint()
            ..shader = LinearGradient(
              begin: Alignment.topLeft,
              end: Alignment.bottomRight,
              colors: [
                _beakHighlight.withAlpha(alpha),
                _beakLight.withAlpha(alpha),
                _beakDark.withAlpha(alpha),
              ],
              stops: const [0.0, 0.52, 1.0],
            ).createShader(upperBounds)
            ..style = PaintingStyle.fill
            ..isAntiAlias = true,
        );
        final sheenCenter = Offset.lerp(
          upperNodes[1].screen,
          upperNodes[2].screen,
          0.35,
        )!;
        final sheenRadius = math.max(1.5, upperNodes[1].screenRadius * 0.36);
        canvas.drawCircle(
          Offset(sheenCenter.dx, sheenCenter.dy - sheenRadius * 0.45),
          sheenRadius,
          Paint()
            ..color = Colors.white.withAlpha((0.26 * alpha).round())
            ..maskFilter = const MaskFilter.blur(BlurStyle.normal, 1.5),
        );
      }
    });
  }

  void _collectEye({
    required Size size,
    required double side,
    required _Vec3 Function(_Vec3) xform,
    required double bodyScale,
    required double opacity,
    required bool winking,
    required bool sad,
    required void Function(_Vec3 anchorWorld, double depth, void Function(Canvas) draw)
    addPart,
  }) {
    final centerLocal = _Vec3(side * 0.39, 0.27, 0.62);
    final outwardLocal = _Vec3(side * 0.66, 0.30, 0.77);
    final centerW = xform(centerLocal);
    final outW = xform(outwardLocal);
    final eyeNormal = (outW - centerW).normalized();
    final toCam = _Vec3(
      -centerW.x,
      -centerW.y,
      _cameraDist - centerW.z,
    ).normalized();
    final facing = eyeNormal.dot(toCam);
    if (facing <= 0.04) return;

    final proj = _project(centerW, size);
    final radiusPx = 0.145 * bodyScale * proj.pxPerUnit;
    final rx = radiusPx * (0.58 + 0.42 * facing.clamp(0.0, 1.0));
    final ry = radiusPx;
    final alpha = (opacity * 255.0).round().clamp(0, 255);

    addPart(centerW, proj.viewZ - 0.08, (canvas) {
      canvas.save();
      canvas.translate(proj.screen.dx, proj.screen.dy);
      if (winking) {
        final path = Path()
          ..moveTo(-rx * 0.85, ry * 0.15)
          ..quadraticBezierTo(0, -ry * 0.58, rx * 0.85, ry * 0.15);
        final strokeWidth = math.max(2.3, radiusPx * 0.27);
        canvas.drawPath(
          path.shift(const Offset(0, 1.2)),
          Paint()
            ..color = const Color(0xFF230C38).withAlpha((0.75 * alpha).round())
            ..style = PaintingStyle.stroke
            ..strokeWidth = strokeWidth
            ..strokeCap = StrokeCap.round,
        );
        canvas.drawPath(
          path,
          Paint()
            ..color = _winkHighlight.withAlpha(alpha)
            ..style = PaintingStyle.stroke
            ..strokeWidth = strokeWidth
            ..strokeCap = StrokeCap.round,
        );
        canvas.restore();
        return;
      }

      // White sclera ring framing the black iris so dark pupils never merge into purple skin.
      final scleraRect = Rect.fromCenter(
        center: Offset(rx * 0.08, 0),
        width: rx * 2.28,
        height: ry * 2.24,
      );
      canvas.drawOval(
        scleraRect,
        Paint()
          ..color = _eyeSclera.withAlpha(alpha)
          ..style = PaintingStyle.fill
          ..isAntiAlias = true,
      );

      final eyeRect = Rect.fromCenter(
        center: Offset.zero,
        width: rx * 2,
        height: ry * 2,
      );
      canvas.drawOval(
        eyeRect,
        Paint()
          ..shader = RadialGradient(
            center: const Alignment(-0.25, -0.25),
            radius: 1.0,
            colors: [
              const Color(0xFF282E3D).withAlpha(alpha),
              _eyeBlack.withAlpha(alpha),
            ],
          ).createShader(eyeRect),
      );

      // Glossy catchlights giving the clay-figure sparkle.
      canvas.drawCircle(
        Offset(-rx * 0.28, -ry * 0.28),
        math.max(1.4, rx * 0.30),
        Paint()..color = Colors.white.withAlpha((0.94 * alpha).round()),
      );
      canvas.drawCircle(
        Offset(rx * 0.25, ry * 0.28),
        math.max(0.9, rx * 0.13),
        Paint()..color = Colors.white.withAlpha((0.68 * alpha).round()),
      );

      if (sad) {
        final slope = side < 0 ? 0.36 : -0.36;
        canvas.save();
        canvas.clipPath(Path()..addOval(scleraRect));
        canvas.rotate(slope);
        canvas.drawRect(
          Rect.fromLTRB(-rx * 1.4, -ry * 1.4, rx * 1.4, -ry * 0.16),
          Paint()..color = _bodyMid.withAlpha(alpha),
        );
        canvas.drawLine(
          Offset(-rx * 1.2, -ry * 0.18),
          Offset(rx * 1.2, -ry * 0.18),
          Paint()
            ..color = _sadLidEdge.withAlpha(alpha)
            ..strokeWidth = math.max(1.5, radiusPx * 0.16)
            ..strokeCap = StrokeCap.round,
        );
        canvas.restore();
      }
      canvas.restore();
    });
  }

  void _drawRingHalf(
    Canvas canvas, {
    required Size size,
    required _Vec3 center,
    required double majorRadius,
    required double minorRadius,
    required double yaw,
    required double pitch,
    required bool isLifebuoy,
    required double opacity,
    required bool drawBackHalf,
  }) {
    const segs = 36;
    final pts = <({Offset screen, double pxPerUnit, _Vec3 world, int idx})>[];
    for (var i = 0; i <= segs; i++) {
      final u = (i / segs) * math.pi * 2.0;
      final local = _Vec3(
        majorRadius * math.cos(u),
        majorRadius * math.sin(u),
        0,
      ).rotateX(pitch).rotateY(yaw);
      final w = local + center;
      final p = _project(w, size);
      pts.add((screen: p.screen, pxPerUnit: p.pxPerUnit, world: w, idx: i));
    }

    final alpha = (opacity * 255.0).round().clamp(0, 255);
    if (!isLifebuoy) {
      // Draw translucent bubble ring half as continuous stroke arcs (no beaded overlap).
      final strokeW = math.max(
        5.0,
        minorRadius * 2.0 * pts[segs ~/ 4].pxPerUnit,
      );
      Path? currentArc;
      final arcs = <Path>[];
      for (var i = 0; i < segs; i++) {
        final a = pts[i];
        final b = pts[i + 1];
        final midZ = (a.world.z + b.world.z) * 0.5;
        final isBack = midZ < center.z;
        if (isBack != drawBackHalf) {
          currentArc = null;
          continue;
        }
        if (currentArc == null) {
          currentArc = Path()..moveTo(a.screen.dx, a.screen.dy);
          arcs.add(currentArc);
        }
        currentArc.lineTo(b.screen.dx, b.screen.dy);
      }
      for (final arc in arcs) {
        canvas.drawPath(
          arc,
          Paint()
            ..color = const Color(0xFF9BE7FF).withAlpha((0.46 * alpha).round())
            ..style = PaintingStyle.stroke
            ..strokeWidth = strokeW
            ..strokeCap = StrokeCap.round
            ..strokeJoin = StrokeJoin.round,
        );
        canvas.drawPath(
          arc,
          Paint()
            ..color = Colors.white.withAlpha((0.68 * alpha).round())
            ..style = PaintingStyle.stroke
            ..strokeWidth = math.max(1.4, strokeW * 0.25)
            ..strokeCap = StrokeCap.round
            ..strokeJoin = StrokeJoin.round,
        );
      }
      return;
    }

    for (var i = 0; i < segs; i++) {
      final a = pts[i];
      final b = pts[i + 1];
      final midZ = (a.world.z + b.world.z) * 0.5;
      final isBack = midZ < center.z;
      if (isBack != drawBackHalf) continue;

      final strokeW = math.max(4.0, minorRadius * 2.0 * a.pxPerUnit);
      final stripeIdx = ((i / segs) * 12).floor();
      final baseColor = stripeIdx.isEven
          ? _lifebuoyRed.withAlpha(alpha)
          : _lifebuoyWhite.withAlpha(alpha);

      canvas.drawLine(
        a.screen,
        b.screen,
        Paint()
          ..color = baseColor
          ..style = PaintingStyle.stroke
          ..strokeWidth = strokeW
          ..strokeCap = StrokeCap.round,
      );

      canvas.drawLine(
        a.screen - Offset(0, strokeW * 0.16),
        b.screen - Offset(0, strokeW * 0.16),
        Paint()
          ..color = Colors.white.withAlpha((0.36 * alpha).round())
          ..style = PaintingStyle.stroke
          ..strokeWidth = math.max(1.4, strokeW * 0.24)
          ..strokeCap = StrokeCap.round,
      );
    }
  }

  void _drawWaterSplash(
    Canvas canvas, {
    required Size size,
    required double splashT,
  }) {
    final fade = (1.0 - splashT).clamp(0.0, 1.0);
    final rippleProj = _project(const _Vec3(-0.04, -0.32, 0.25), size);
    final rippleRx = (0.45 + 1.05 * splashT) * math.min(size.width, size.height) * 0.24;
    final rippleRy = rippleRx * 0.34;
    canvas.drawOval(
      Rect.fromCenter(
        center: rippleProj.screen,
        width: rippleRx * 2,
        height: rippleRy * 2,
      ),
      Paint()
        ..color = Color.fromARGB((fade * 175).round(), 179, 229, 252)
        ..style = PaintingStyle.stroke
        ..strokeWidth = 2.4,
    );

    const dropCount = 16;
    for (var i = 0; i < dropCount; i++) {
      final angle = (i / dropCount) * math.pi * 2.0 + 0.25;
      final speed = 0.65 + (i % 3) * 0.22;
      final r = 0.58 + splashT * 1.15 * speed;
      final x = math.cos(angle) * r;
      final y =
          -0.22 + math.sin(splashT * math.pi) * (0.42 + (i % 4) * 0.10) - splashT * 0.20;
      final z = 0.25 + math.sin(angle) * r * 0.55;
      final proj = _project(_Vec3(x, y, z), size);
      final dropRadius = math.max(2.0, (5.0 - (i % 3) * 1.0) * (1.0 - 0.3 * splashT));
      final color = i.isEven
          ? Color.fromARGB((fade * 230).round(), 225, 245, 254)
          : Color.fromARGB((fade * 215).round(), 129, 212, 250);
      canvas.drawCircle(proj.screen, dropRadius, Paint()..color = color);
    }
  }

  void _drawExitBubbles(
    Canvas canvas, {
    required Size size,
    required double progress,
  }) {
    final fade = (1.0 - math.pow(progress, 2)).clamp(0.0, 1.0);
    for (var i = 0; i < 8; i++) {
      final t = ((progress * 1.4) - i * 0.06).clamp(0.0, 1.0);
      if (t <= 0) continue;
      final x = -0.35 + math.sin(i * 1.7 + t * 4.0) * 0.16;
      final y = 0.06 + t * 0.68 + (i % 3) * 0.08;
      final z = 0.48 - t * 0.45;
      final proj = _project(_Vec3(x, y, z), size);
      final radius = 2.6 + (i % 3) * 1.3;
      canvas.drawCircle(
        proj.screen,
        radius,
        Paint()
          ..color = Color.fromARGB((fade * 200).round(), 225, 245, 254)
          ..style = PaintingStyle.stroke
          ..strokeWidth = 1.6,
      );
    }
  }
}
