/// Shared 3-digit channel number and station logo plate helpers/widgets for
/// Live TV lists, EPG headers, player OSD headers, and channel switch cards.
library;

import 'dart:typed_data';

import 'package:material_ui/material_ui.dart';

import '../core/core.dart';

/// Formats a broadcast channel number as a 3-digit zero-padded string
/// (`031`, `101`, `296`), or `null` when absent / outside 1..999 (which ignores
/// 5-digit UPnP `upnp:channelNr` identifiers such as `30310`).
String? formatChannelNumber3Digit(int? number) {
  if (number == null || number <= 0 || number > 999) return null;
  return number.toString().padLeft(3, '0');
}

/// Finds the [Channel] matching [live] from a channel-list lookup.
Channel? findMatchingChannelForLive(
  LiveChannel live,
  Iterable<Channel> channels,
) {
  final sid = live.serviceId;
  if (sid == null) return null;
  final nid = live.networkId;
  final tsid = live.transportStreamId;
  Channel? byNidSid;
  Channel? bySid;
  for (final ch in channels) {
    if (ch.serviceId != sid) continue;
    if (nid != null &&
        tsid != null &&
        ch.networkId == nid &&
        ch.transportStreamId == tsid) {
      return ch;
    }
    if (nid != null && ch.networkId == nid) {
      byNidSid ??= ch;
    }
    bySid ??= ch;
  }
  return byNidSid ?? bySid;
}

/// Resolves the 3-digit channel number label for [live] using [channels] first
/// and falling back to [LiveChannel.channelNr] only when it is in 1..999.
String? resolveLiveChannelNumberLabel(
  LiveChannel live,
  Iterable<Channel> channels,
) {
  final matched = findMatchingChannelForLive(live, channels);
  return formatChannelNumber3Digit(matched?.channelNumber) ??
      formatChannelNumber3Digit(live.channelNr);
}

/// Resolves cached PNG logo bytes for [live] by its `serviceId`, returning
/// `null` when unavailable or empty.
Uint8List? resolveLiveChannelLogoBytes(
  LiveChannel live,
  Map<int, List<int>> logos,
) {
  final sid = live.serviceId;
  if (sid == null) return null;
  final raw = logos[sid];
  if (raw == null || raw.isEmpty) return null;
  return raw is Uint8List ? raw : Uint8List.fromList(raw);
}

/// Renders a station logo PNG inside a light rounded backing plate so dark-ink
/// broadcaster logos remain crisp on dark OSD overlays and in night mode.
class ChannelLogoPlate extends StatelessWidget {
  const ChannelLogoPlate({
    super.key,
    required this.bytes,
    this.width = 42,
    this.height = 24,
    this.darkSurface = false,
  });

  final Uint8List bytes;
  final double width;
  final double height;
  final bool darkSurface;

  @override
  Widget build(BuildContext context) {
    final isDark =
        darkSurface || Theme.of(context).brightness == Brightness.dark;
    return Container(
      width: width,
      height: height,
      padding: const EdgeInsets.symmetric(horizontal: 4, vertical: 2),
      decoration: BoxDecoration(
        color: isDark ? Colors.white.withValues(alpha: 0.92) : Colors.white,
        borderRadius: BorderRadius.circular(4),
        border: isDark ? null : Border.all(color: Colors.black12, width: 0.5),
      ),
      child: Image.memory(
        bytes,
        fit: BoxFit.contain,
        gaplessPlayback: true,
        errorBuilder: (_, _, _) => const SizedBox.shrink(),
      ),
    );
  }
}

/// Compact pill badge displaying a 3-digit channel number (`031`, `101`, etc.).
class ChannelNumberBadge extends StatelessWidget {
  const ChannelNumberBadge({
    super.key,
    required this.label,
    this.darkSurface = false,
    this.compact = false,
  });

  final String label;
  final bool darkSurface;
  final bool compact;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final bgColor = darkSurface
        ? Colors.white.withValues(alpha: 0.16)
        : theme.colorScheme.surfaceContainerHighest;
    final fgColor = darkSurface
        ? Colors.white
        : theme.colorScheme.onSurfaceVariant;
    return Container(
      padding: EdgeInsets.symmetric(
        horizontal: compact ? 5 : 6,
        vertical: compact ? 1 : 2,
      ),
      decoration: BoxDecoration(
        color: bgColor,
        borderRadius: BorderRadius.circular(4),
        border: darkSurface ? Border.all(color: Colors.white24) : null,
      ),
      child: Text(
        label,
        style: TextStyle(
          color: fgColor,
          fontSize: compact ? 10.5 : 12,
          fontWeight: FontWeight.w700,
          height: 1.15,
          fontFeatures: const [FontFeature.tabularFigures()],
        ),
      ),
    );
  }
}
