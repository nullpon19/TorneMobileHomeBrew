/// Reusable touch & desktop player controls and pure scrubbing/swipe helpers.
library;

import 'dart:math' as math;

import 'package:material_ui/material_ui.dart';

import 'live_channel_switch_policy.dart';

/// Maps a normalized `[0.0, 1.0]` seek bar fraction to a [Duration] within
/// `[Duration.zero, duration]`.
Duration scrubFractionToDuration(double fraction, Duration duration) {
  if (duration <= Duration.zero) return Duration.zero;
  final clamped = fraction.clamp(0.0, 1.0).toDouble();
  return Duration(milliseconds: (duration.inMilliseconds * clamped).round());
}

/// Maps a normalized tap/drag fraction on the Live timeshift bar to a target
/// position in mpv stream seconds, or `null` when timeshift range is unavailable.
double? resolveLiveTimeshiftTargetSeconds({
  required double fraction,
  required double liveEdgeFraction,
  required double playableStartFraction,
  required bool usesProgramTimeline,
  DateTime? programStart,
  DateTime? programEnd,
  double? cacheStartSeconds,
  double? cacheEndSeconds,
}) {
  if (cacheStartSeconds == null ||
      cacheEndSeconds == null ||
      !cacheStartSeconds.isFinite ||
      !cacheEndSeconds.isFinite ||
      cacheEndSeconds <= cacheStartSeconds) {
    return null;
  }
  final minFrac = playableStartFraction.clamp(0.0, liveEdgeFraction).toDouble();
  final maxFrac = liveEdgeFraction.clamp(0.0, 1.0).toDouble();
  if (maxFrac <= minFrac + 1e-6) {
    return cacheEndSeconds;
  }
  final clampedFrac = fraction.clamp(minFrac, maxFrac).toDouble();
  if (usesProgramTimeline &&
      programStart != null &&
      programEnd != null &&
      programEnd.isAfter(programStart)) {
    final totalSec = programEnd.difference(programStart).inMilliseconds / 1000.0;
    final lagSec = math.max(0.0, (maxFrac - clampedFrac) * totalSec);
    return math.max(cacheStartSeconds, cacheEndSeconds - lagSec);
  }
  final normalized = ((clampedFrac - minFrac) / (maxFrac - minFrac))
      .clamp(0.0, 1.0)
      .toDouble();
  return cacheStartSeconds + (cacheEndSeconds - cacheStartSeconds) * normalized;
}

/// Resolves a horizontal touch swipe on the video surface to a channel switch
/// direction (`previous` on right-ward swipe, `next` on left-ward swipe).
ChannelSwitchDirection? resolveTouchHorizontalSwipeDirection({
  required double dragDeltaX,
  double? primaryVelocity,
  required double startX,
  required double viewportWidth,
}) {
  final width = viewportWidth <= 0 ? 1.0 : viewportWidth;
  final vel = primaryVelocity ?? 0.0;
  final isRightSwipe = dragDeltaX > 42.0 || (dragDeltaX > 18.0 && vel > 320.0);
  final isLeftSwipe = dragDeltaX < -42.0 || (dragDeltaX < -18.0 && vel < -320.0);
  if (isRightSwipe && startX <= width * 0.6) {
    return ChannelSwitchDirection.previous;
  }
  if (isLeftSwipe && startX >= width * 0.4) {
    return ChannelSwitchDirection.next;
  }
  return null;
}

/// Center transport buttons (`-10秒`, `Play/Pause`, `+10秒`) shown on hover
/// (desktop) or tap (touch).
class PlayerCenterTransportOverlay extends StatelessWidget {
  const PlayerCenterTransportOverlay({
    super.key,
    required this.visible,
    required this.isPlaying,
    required this.canSeekBackward,
    required this.canSeekForward,
    required this.onRewind,
    required this.onTogglePlayPause,
    required this.onForward,
    this.compact = false,
  });

  final bool visible;
  final bool isPlaying;
  final bool canSeekBackward;
  final bool canSeekForward;
  final VoidCallback onRewind;
  final VoidCallback onTogglePlayPause;
  final VoidCallback onForward;
  final bool compact;

  @override
  Widget build(BuildContext context) {
    if (!visible) return const SizedBox.shrink();
    final sideSize = compact ? 44.0 : 54.0;
    final playSize = compact ? 58.0 : 72.0;
    final gap = compact ? 18.0 : 28.0;
    return IgnorePointer(
      ignoring: !visible,
      child: Center(
        child: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            _CircleTransportButton(
              key: const ValueKey('player_center_rewind'),
              size: sideSize,
              icon: Icons.replay_10,
              iconSize: compact ? 24 : 28,
              tooltip: '-10秒',
              enabled: canSeekBackward,
              onPressed: onRewind,
            ),
            SizedBox(width: gap),
            _CircleTransportButton(
              key: const ValueKey('player_center_play_pause'),
              size: playSize,
              icon: isPlaying ? Icons.pause : Icons.play_arrow,
              iconSize: compact ? 32 : 40,
              tooltip: isPlaying ? '一時停止' : '再生',
              enabled: true,
              emphasized: true,
              onPressed: onTogglePlayPause,
            ),
            SizedBox(width: gap),
            _CircleTransportButton(
              key: const ValueKey('player_center_forward'),
              size: sideSize,
              icon: Icons.forward_10,
              iconSize: compact ? 24 : 28,
              tooltip: '+10秒',
              enabled: canSeekForward,
              onPressed: onForward,
            ),
          ],
        ),
      ),
    );
  }
}

class _CircleTransportButton extends StatelessWidget {
  const _CircleTransportButton({
    super.key,
    required this.size,
    required this.icon,
    required this.iconSize,
    required this.tooltip,
    required this.enabled,
    required this.onPressed,
    this.emphasized = false,
  });

  final double size;
  final IconData icon;
  final double iconSize;
  final String tooltip;
  final bool enabled;
  final VoidCallback onPressed;
  final bool emphasized;

  @override
  Widget build(BuildContext context) {
    return Tooltip(
      message: tooltip,
      child: Material(
        color: emphasized
            ? Colors.black.withValues(alpha: 0.68)
            : Colors.black.withValues(alpha: 0.52),
        shape: CircleBorder(
          side: BorderSide(
            color: enabled
                ? Colors.white.withValues(alpha: emphasized ? 0.55 : 0.3)
                : Colors.white12,
            width: 1.5,
          ),
        ),
        clipBehavior: Clip.antiAlias,
        child: InkWell(
          onTap: enabled ? onPressed : null,
          child: SizedBox(
            width: size,
            height: size,
            child: Icon(
              icon,
              size: iconSize,
              color: enabled ? Colors.white : Colors.white38,
            ),
          ),
        ),
      ),
    );
  }
}

/// Compact mute button + horizontal volume slider for PC and touch OSD bars.
class PlayerVolumeControl extends StatelessWidget {
  const PlayerVolumeControl({
    super.key,
    required this.volume,
    required this.muted,
    required this.onToggleMute,
    required this.onVolumeChanged,
    this.sliderWidth = 108.0,
  });

  final double volume;
  final bool muted;
  final VoidCallback onToggleMute;
  final ValueChanged<double> onVolumeChanged;
  final double sliderWidth;

  @override
  Widget build(BuildContext context) {
    final effective = muted ? 0.0 : volume.clamp(0.0, 100.0);
    final IconData icon;
    if (muted || effective <= 0.1) {
      icon = Icons.volume_off;
    } else if (effective < 50.0) {
      icon = Icons.volume_down;
    } else {
      icon = Icons.volume_up;
    }
    return Row(
      mainAxisSize: MainAxisSize.min,
      children: [
        IconButton(
          key: const ValueKey('player_mute_button'),
          icon: Icon(icon, color: Colors.white, size: 22),
          tooltip: muted ? 'ミュート解除' : 'ミュート',
          onPressed: onToggleMute,
          visualDensity: VisualDensity.compact,
        ),
        SizedBox(
          width: sliderWidth,
          child: SliderTheme(
            data: SliderTheme.of(context).copyWith(
              trackHeight: 3,
              thumbShape: const RoundSliderThumbShape(enabledThumbRadius: 6),
              overlayShape: const RoundSliderOverlayShape(overlayRadius: 12),
              activeTrackColor: Colors.lightBlueAccent,
              inactiveTrackColor: Colors.white24,
              thumbColor: Colors.white,
            ),
            child: Slider(
              key: const ValueKey('player_volume_slider'),
              value: effective,
              min: 0.0,
              max: 100.0,
              onChanged: onVolumeChanged,
            ),
          ),
        ),
      ],
    );
  }
}

/// Left/right edge hover & click hit-zones on desktop live playback. Hovering
/// peeks the adjacent channel card; clicking expands the full preview card.
class DesktopChannelEdgeZones extends StatelessWidget {
  const DesktopChannelEdgeZones({
    super.key,
    required this.enabled,
    required this.hasPrevious,
    required this.hasNext,
    required this.onHoverDirection,
    required this.onClickDirection,
  });

  final bool enabled;
  final bool hasPrevious;
  final bool hasNext;
  final ValueChanged<ChannelSwitchDirection?> onHoverDirection;
  final ValueChanged<ChannelSwitchDirection> onClickDirection;

  @override
  Widget build(BuildContext context) {
    if (!enabled) return const SizedBox.shrink();
    return Positioned.fill(
      top: 72,
      bottom: 220,
      child: Row(
        children: [
          if (hasPrevious)
            _EdgeHitStrip(
              key: const ValueKey('desktop_edge_previous'),
              onEnter: () => onHoverDirection(ChannelSwitchDirection.previous),
              onExit: () => onHoverDirection(null),
              onTap: () => onClickDirection(ChannelSwitchDirection.previous),
            )
          else
            const SizedBox(width: 96),
          const Spacer(),
          if (hasNext)
            _EdgeHitStrip(
              key: const ValueKey('desktop_edge_next'),
              onEnter: () => onHoverDirection(ChannelSwitchDirection.next),
              onExit: () => onHoverDirection(null),
              onTap: () => onClickDirection(ChannelSwitchDirection.next),
            )
          else
            const SizedBox(width: 96),
        ],
      ),
    );
  }
}

class _EdgeHitStrip extends StatelessWidget {
  const _EdgeHitStrip({
    super.key,
    required this.onEnter,
    required this.onExit,
    required this.onTap,
  });

  final VoidCallback onEnter;
  final VoidCallback onExit;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    return MouseRegion(
      cursor: SystemMouseCursors.click,
      onEnter: (_) => onEnter(),
      onExit: (_) => onExit(),
      child: GestureDetector(
        behavior: HitTestBehavior.translucent,
        onTap: onTap,
        child: const SizedBox(width: 96, height: double.infinity),
      ),
    );
  }
}
