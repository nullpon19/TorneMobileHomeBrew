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
  return normalizeAribLogoPng(
    raw is Uint8List ? raw : Uint8List.fromList(raw),
  );
}

String _normalizeChannelNameForMatch(String name) =>
    name.trim().replaceAll(RegExp(r'[\s\u3000]+'), ' ').toLowerCase();

/// Finds the [Channel] matching recorded metadata ([serviceId] first, then
/// normalized [channelName] fallback).
Channel? findMatchingChannelForRecorded({
  int? serviceId,
  String? channelName,
  required Iterable<Channel> channels,
}) {
  if (serviceId != null) {
    for (final ch in channels) {
      if (ch.serviceId == serviceId) return ch;
    }
  }
  final targetName = channelName != null
      ? _normalizeChannelNameForMatch(channelName)
      : '';
  if (targetName.isNotEmpty) {
    for (final ch in channels) {
      if (_normalizeChannelNameForMatch(ch.serviceName) == targetName) {
        return ch;
      }
    }
  }
  return null;
}

/// Resolves the 3-digit channel number label (`011`, `101`, etc.) for a
/// recorded title from [channels], or `null` when unavailable.
String? resolveRecordedChannelNumberLabel({
  int? serviceId,
  String? channelName,
  required Iterable<Channel> channels,
}) {
  final matched = findMatchingChannelForRecorded(
    serviceId: serviceId,
    channelName: channelName,
    channels: channels,
  );
  return formatChannelNumber3Digit(matched?.channelNumber);
}

/// Resolves cached PNG logo bytes for a recorded title from [logos] via
/// [serviceId] or matched channel name, returning `null` when unavailable.
Uint8List? resolveRecordedChannelLogoBytes({
  int? serviceId,
  String? channelName,
  required Iterable<Channel> channels,
  required Map<int, List<int>> logos,
}) {
  final matched = findMatchingChannelForRecorded(
    serviceId: serviceId,
    channelName: channelName,
    channels: channels,
  );
  final sid = serviceId ?? matched?.serviceId;
  if (sid == null) return null;
  final raw = logos[sid];
  if (raw == null || raw.isEmpty) return null;
  return normalizeAribLogoPng(
    raw is Uint8List ? raw : Uint8List.fromList(raw),
  );
}

/// Renders a station logo PNG clipped directly with rounded corners inside a
/// fixed-size slot, with no background plate or border.
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
    return SizedBox(
      width: width,
      height: height,
      child: Center(
        child: ConstrainedBox(
          constraints: BoxConstraints(maxWidth: width, maxHeight: height),
          child: ClipRRect(
            borderRadius: BorderRadius.circular(4),
            child: Image.memory(
              bytes,
              fit: BoxFit.contain,
              gaplessPlayback: true,
              errorBuilder: (_, _, _) => Icon(
                Icons.live_tv_outlined,
                size: 18,
                color: isDark ? Colors.white54 : Colors.black38,
              ),
            ),
          ),
        ),
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
