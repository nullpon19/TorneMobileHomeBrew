/// Live viewing screen (plan 39): the LiveTuner bands and their
/// channels, each with the programme currently on air, and a
/// detail view that starts viewing through the PlaybackEngine
/// boundary — the same DTCP-IP path as recorded playback, with
/// the plan-33 quality choice. The official torne name of the
/// feature, TV視聴, is the screen's title.
///
/// Plan 95: the bands sit under tabs (地デジ / BS / CS, the
/// guide's wording), one band's channels on screen at a time in
/// large rows, instead of one long list with band headings;
/// the guide's subchannel switch applies to the list as well.
///
/// The programme information is the snapshot the DIDL items
/// carried when the list was fetched; the refresh action
/// re-fetches it (a programme boundary does not update an
/// already listed item).
library;

import 'dart:async';

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:material_ui/material_ui.dart';

import '../app/providers.dart';
import '../app/state.dart';
import '../core/core.dart';
import 'epg_subchannel_visibility.dart';
import 'format.dart';
import 'live_recording_policy.dart';
import 'playback_launcher.dart';
import 'player_screen.dart';
import 'schedules_screen.dart' show twoPaneBreakpoint;
import 'widgets.dart';

class LiveScreen extends ConsumerStatefulWidget {
  const LiveScreen({super.key});

  @override
  ConsumerState<LiveScreen> createState() => _LiveScreenState();
}

class _LiveScreenState extends ConsumerState<LiveScreen> {
  String? _selectedId;
  final FocusNode _detailWatchFocusNode = FocusNode(debugLabel: 'liveWatch');

  /// Container id of the band whose tab is selected; null
  /// means the first band with channels.
  String? _selectedBandId;

  @override
  void dispose() {
    _detailWatchFocusNode.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final reg = ref.watch(selectedRegistrationProvider);
    return Scaffold(
      appBar: AppBar(
        title: const Text('TV視聴'),
        actions: [
          if (reg != null)
            IconButton(
              icon: const Icon(Icons.refresh),
              tooltip: '更新',
              onPressed: () {
                ref.invalidate(liveChannelsProvider(reg));
                ref.invalidate(schedulesProvider(reg));
              },
            ),
        ],
      ),
      body: reg == null
          ? NoDeviceView(
              onRegister: () =>
                  ref.read(tabIndexProvider.notifier).select(AppTabs.settings),
            )
          : _LiveList(
              reg: reg,
              selectedId: _selectedId,
              selectedBandId: _selectedBandId,
              detailWatchFocusNode: _detailWatchFocusNode,
              onSelectBand: (bandId) =>
                  setState(() => _selectedBandId = bandId),
              onSelect: (channel, twoPane) {
                if (twoPane) {
                  setState(() => _selectedId = channel.id);
                  WidgetsBinding.instance.addPostFrameCallback((_) {
                    if (mounted && _detailWatchFocusNode.canRequestFocus) {
                      _detailWatchFocusNode.requestFocus();
                    }
                  });
                } else {
                  Navigator.of(context).push(
                    MaterialPageRoute(
                      builder: (_) => LiveChannelDetailPage(
                        reg: reg,
                        channelId: channel.id,
                      ),
                    ),
                  );
                }
              },
            ),
    );
  }
}

/// The short tab label of a live band (plan 95): the guide's
/// 地デジ / BS wording for the measured bands, CS alike; an
/// unrecognised band keeps the title the device advertises.
String liveBandTabLabel(LiveBand band) => switch (liveBandKind(band)) {
  LiveBandKind.terrestrial => '地デジ',
  LiveBandKind.bs => 'BS',
  LiveBandKind.cs => 'CS',
  LiveBandKind.other => band.title,
};

class _LiveList extends ConsumerWidget {
  const _LiveList({
    required this.reg,
    required this.selectedId,
    required this.selectedBandId,
    required this.detailWatchFocusNode,
    required this.onSelectBand,
    required this.onSelect,
  });

  final RegisteredNasne reg;
  final String? selectedId;
  final String? selectedBandId;
  final FocusNode detailWatchFocusNode;
  final ValueChanged<String> onSelectBand;
  final void Function(LiveChannel channel, bool twoPane) onSelect;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final bands = ref.watch(liveChannelsProvider(reg));
    final showSubchannels = ref.watch(showSubchannelsProvider);
    final schedules =
        ref.watch(schedulesProvider(reg)).value ?? const <RecordSchedule>[];
    final now = DateTime.now();
    return asyncSection(bands, (list) {
      // The guide's subchannel switch applies to this list
      // too (plan 95): the same setting, not a new one.
      final visibleBands = liveBandsWithSubchannelSetting(
        list,
        showSubchannels,
      );
      final channels = [for (final band in visibleBands) ...band.channels];
      if (channels.isEmpty) {
        return const Center(child: Text('視聴可能なチャンネルがありません'));
      }
      // One tab per band that actually offers a channel; the
      // selected band survives refreshes by container id and
      // falls back to the first tab when it is gone.
      final tabBands = [
        for (final band in visibleBands)
          if (band.channels.isNotEmpty) band,
      ];
      final selectedBand = tabBands.firstWhere(
        (band) => band.containerId == selectedBandId,
        orElse: () => tabBands.first,
      );
      return LayoutBuilder(
        builder: (context, constraints) {
          // One width decides both the layout and the tap
          // behaviour: the width this list actually gets. Reading
          // the MediaQuery window width for the tap instead left
          // a band (window >= breakpoint, list < breakpoint, e.g.
          // a 1024-wide iPad in landscape past the shell's rail)
          // where a tap updated only the selection and opened
          // nothing. See titles_screen.dart for the full note.
          final twoPane = constraints.maxWidth >= twoPaneBreakpoint;
          final listView = ListView(
            children: [
              for (final channel in selectedBand.channels) ...[
                Builder(
                  builder: (context) {
                    final isRecording =
                        findActiveSameChannelRecording(
                          schedules,
                          currentChannel: channel,
                          now: now,
                        ) !=
                        null;
                    return ListTile(
                      selected: channel.id == selectedId,
                      contentPadding: const EdgeInsets.symmetric(
                        horizontal: 16,
                        vertical: 8,
                      ),
                      leading: const Icon(Icons.live_tv_outlined),
                      title: Text(channel.channelName ?? channel.programTitle),
                      subtitle: Text(
                        _channelSubtitle(channel),
                        maxLines: 2,
                        overflow: TextOverflow.ellipsis,
                      ),
                      trailing: isRecording ? const _LiveRecordingBadge() : null,
                      onTap: () => onSelect(channel, twoPane),
                    );
                  },
                ),
              ],
            ],
          );
          final content = Column(
            children: [
              if (tabBands.length > 1)
                Padding(
                  padding: const EdgeInsets.symmetric(
                    horizontal: 12,
                    vertical: 8,
                  ),
                  child: SegmentedButton<String>(
                    segments: [
                      for (final band in tabBands)
                        ButtonSegment<String>(
                          value: band.containerId,
                          label: Text(liveBandTabLabel(band)),
                        ),
                    ],
                    selected: {selectedBand.containerId},
                    onSelectionChanged: (selection) =>
                        onSelectBand(selection.first),
                  ),
                ),
              Expanded(child: listView),
            ],
          );
          if (!twoPane) return content;
          LiveChannel? selected;
          for (final channel in channels) {
            if (channel.id == selectedId) selected = channel;
          }
          return Row(
            children: [
              Expanded(flex: 5, child: content),
              const VerticalDivider(thickness: 1, width: 1),
              Expanded(
                flex: 6,
                child: selected == null
                    ? const Center(child: Text('チャンネルを選択してください'))
                    : LiveChannelDetailView(
                        reg: reg,
                        channel: selected,
                        watchFocusNode: detailWatchFocusNode,
                      ),
              ),
            ],
          );
        },
      );
    }, onRetry: () => ref.invalidate(liveChannelsProvider(reg)));
  }
}

/// The list subtitle: the on-air time range and programme title
/// (the channel name already heads the tile), or the programme
/// outline when the item carried no channel name.
String _channelSubtitle(LiveChannel channel) {
  final start = channel.programStart;
  final end = channel.programEnd;
  final range = start != null && end != null
      ? '${formatTimeJst(start)}–${formatTimeJst(end)} '
      : '';
  if (channel.channelName != null) return '$range${channel.programTitle}';
  return '$range${channel.description ?? ''}';
}

/// The live channel carrying a programme-guide service,
/// matched on the (networkId, transportStreamId, serviceId)
/// triple the DIDL ids and the guide share (plan 95); null
/// when the LiveTuner tree has no such channel.
LiveChannel? liveChannelForService(
  List<LiveBand> bands, {
  required int networkId,
  required int transportStreamId,
  required int serviceId,
}) {
  for (final band in bands) {
    for (final channel in band.channels) {
      if (channel.networkId == networkId &&
          channel.transportStreamId == transportStreamId &&
          channel.serviceId == serviceId) {
        return channel;
      }
    }
  }
  return null;
}

/// From the programme guide to live viewing (plan 95):
/// resolves the guide channel's live channel and opens its
/// detail page, where the 視聴 button starts playback. When
/// the channel cannot be resolved — a band the LiveTuner
/// tree does not carry, or a failed fetch — a snackbar says
/// so instead of navigating nowhere.
Future<void> openLiveChannelForEpg(
  BuildContext context,
  WidgetRef ref, {
  required RegisteredNasne reg,
  required Channel channel,
}) async {
  final List<LiveBand> bands;
  try {
    bands = await ref.read(liveChannelsProvider(reg).future);
  } catch (_) {
    if (context.mounted) showSnack(context, 'チャンネル情報を取得できませんでした');
    return;
  }
  final live = liveChannelForService(
    bands,
    networkId: channel.networkId,
    transportStreamId: channel.transportStreamId,
    serviceId: channel.serviceId,
  );
  if (!context.mounted) return;
  if (live == null) {
    showSnack(context, '視聴可能なチャンネルが見つかりません');
    return;
  }
  await Navigator.push(
    context,
    MaterialPageRoute<void>(
      builder: (_) => LiveChannelDetailPage(reg: reg, channelId: live.id),
    ),
  );
}

/// Detail page for narrow layouts.
class LiveChannelDetailPage extends ConsumerWidget {
  const LiveChannelDetailPage({
    super.key,
    required this.reg,
    required this.channelId,
  });

  final RegisteredNasne reg;
  final String channelId;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final bands = ref.watch(liveChannelsProvider(reg));
    return Scaffold(
      appBar: AppBar(title: const Text('チャンネルの詳細')),
      body: asyncSection(bands, (list) {
        for (final band in list) {
          for (final channel in band.channels) {
            if (channel.id == channelId) {
              return LiveChannelDetailView(
                reg: reg,
                channel: channel,
                autofocusWatch: true,
              );
            }
          }
        }
        return const Center(child: Text('チャンネルが見つかりません'));
      }, onRetry: () => ref.invalidate(liveChannelsProvider(reg))),
    );
  }
}

/// The channel detail optimized for Fire TV D-pad navigation:
/// programme title, channel/broadcast time, and the watch button
/// placed immediately above truncated descriptions, with playback
/// quality fixed to mobile (falling back when unavailable).
class LiveChannelDetailView extends ConsumerStatefulWidget {
  const LiveChannelDetailView({
    super.key,
    required this.reg,
    required this.channel,
    this.watchFocusNode,
    this.autofocusWatch = false,
  });

  final RegisteredNasne reg;
  final LiveChannel channel;
  final FocusNode? watchFocusNode;
  final bool autofocusWatch;

  @override
  ConsumerState<LiveChannelDetailView> createState() =>
      _LiveChannelDetailViewState();
}

class _LiveChannelDetailViewState extends ConsumerState<LiveChannelDetailView> {
  /// Optional per-visit quality override (`false` = original, `true` = mobile).
  /// Null until changed on this detail screen; falls back to the saved
  /// settings default without overwriting it.
  bool? _useMobileChoice;

  /// A viewing start is in flight (plan 35 guard, shared with
  /// recordings): while set, the button is disabled and _watch
  /// is re-entrancy-guarded.
  bool _starting = false;

  RegisteredNasne get reg => widget.reg;
  LiveChannel get channel => widget.channel;

  @override
  void didUpdateWidget(covariant LiveChannelDetailView oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.channel.id != widget.channel.id) {
      _useMobileChoice = null;
    }
  }

  @override
  Widget build(BuildContext context) {
    final ch = channel;
    final mobileRes = ch.mobileRes;
    final originalRes = ch.originalRes;
    final bool useMobile =
        _useMobileChoice ?? ref.watch(playbackQualityProvider);
    final originalLabel = originalRes?.quality == null
        ? '元画質'
        : '元画質 (${resQualityLabel(originalRes!.quality)})';
    final schedules =
        ref.watch(schedulesProvider(reg)).value ?? const <RecordSchedule>[];
    final isChannelRecording =
        findActiveSameChannelRecording(
          schedules,
          currentChannel: ch,
          now: DateTime.now(),
        ) !=
        null;
    final start = ch.programStart;
    final end = ch.programEnd;
    return ListView(
      padding: const EdgeInsets.all(16),
      children: [
        if (isChannelRecording) ...[
          const Align(
            alignment: Alignment.centerLeft,
            child: _LiveRecordingBadge(),
          ),
          const SizedBox(height: 8),
        ],
        Text(
          ch.programTitle,
          style: Theme.of(context).textTheme.titleLarge,
          maxLines: 3,
          overflow: TextOverflow.ellipsis,
        ),
        const SizedBox(height: 8),
        if (ch.channelName != null)
          FieldRow(label: 'チャンネル', value: ch.channelName!),
        if (start != null && end != null)
          FieldRow(
            label: '放送時間',
            value:
                '${formatDateTimeWithWeekdayJst(start)}–${formatTimeJst(end)}',
          ),
        if (ch.genre != null) FieldRow(label: 'ジャンル', value: ch.genre!),
        const SizedBox(height: 16),
        Wrap(
          spacing: 12,
          runSpacing: 8,
          crossAxisAlignment: WrapCrossAlignment.center,
          children: [
            FilledButton.icon(
              focusNode: widget.watchFocusNode,
              autofocus: widget.autofocusWatch,
              onPressed: _starting ? null : () => _watch(context, ref),
              icon: const Icon(Icons.play_arrow),
              label: const Text('視聴'),
            ),
            if (mobileRes != null)
              SegmentedButton<bool>(
                segments: [
                  ButtonSegment(value: false, label: Text(originalLabel)),
                  const ButtonSegment(value: true, label: Text('モバイル')),
                ],
                selected: {useMobile},
                onSelectionChanged: (selection) =>
                    setState(() => _useMobileChoice = selection.first),
              ),
          ],
        ),
        if (ch.description != null && ch.description!.isNotEmpty) ...[
          const SizedBox(height: 12),
          Text(
            ch.description!,
            maxLines: 2,
            overflow: TextOverflow.ellipsis,
            style: Theme.of(context).textTheme.bodySmall,
          ),
        ],
        if (ch.longDescription != null && ch.longDescription!.isNotEmpty) ...[
          const SizedBox(height: 6),
          Text(
            ch.longDescription!,
            maxLines: 2,
            overflow: TextOverflow.ellipsis,
            style: Theme.of(context).textTheme.bodySmall,
          ),
        ],
      ],
    );
  }

  Future<void> _watch(BuildContext context, WidgetRef ref) async {
    if (_starting) return;
    final bool useMobile =
        _useMobileChoice ?? ref.read(playbackQualityProvider);
    setState(() => _starting = true);
    try {
      await _launchLiveChannel(
        context: context,
        ref: ref,
        reg: reg,
        channel: channel,
        useMobile: useMobile,
      );
    } finally {
      if (mounted) setState(() => _starting = false);
    }
  }
}

/// Compact red badge marking a live channel that is currently being recorded.
class _LiveRecordingBadge extends StatelessWidget {
  const _LiveRecordingBadge();

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 3),
      decoration: BoxDecoration(
        color: const Color(0xFFC62828),
        borderRadius: BorderRadius.circular(12),
      ),
      child: const Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          Icon(Icons.fiber_manual_record, size: 10, color: Colors.white),
          SizedBox(width: 4),
          Text(
            '録画中',
            style: TextStyle(
              color: Colors.white,
              fontSize: 11,
              fontWeight: FontWeight.bold,
            ),
          ),
        ],
      ),
    );
  }
}

Future<PlaybackSession> _startLiveSession(
  PlaybackEngine engine,
  LiveChannel channel, {
  required bool useMobile,
  required bool allowQualityFallback,
}) async {
  final primaryRes = useMobile
      ? (channel.mobileRes ?? channel.originalRes ?? channel.res.first)
      : (channel.originalRes ?? channel.mobileRes ?? channel.res.first);
  final secondaryRes = useMobile
      ? (channel.originalRes != primaryRes ? channel.originalRes : null)
      : (channel.mobileRes != primaryRes ? channel.mobileRes : null);
  try {
    return await engine.startLivePlayback(channel, primaryRes);
  } on NasneError {
    if (!allowQualityFallback || secondaryRes == null) rethrow;
    return engine.startLivePlayback(channel, secondaryRes);
  }
}

Future<List<RecordSchedule>> _fetchFreshSchedules(
  ProviderContainer container,
  RegisteredNasne reg,
) async {
  try {
    return await container
        .read(deviceServicesProvider(reg))
        .schedules
        .listSchedules();
  } catch (_) {
    return container.read(schedulesProvider(reg)).value ??
        const <RecordSchedule>[];
  }
}

Future<LiveRecordingConflict?> _resolveOtherChannelConflict(
  ProviderContainer container,
  RegisteredNasne reg,
  LiveChannel currentChannel, {
  List<RecordSchedule>? knownSchedules,
}) async {
  final schedules = knownSchedules ?? await _fetchFreshSchedules(container, reg);
  final conflictSchedule = findActiveOtherChannelRecording(
    schedules,
    currentChannel: currentChannel,
    now: DateTime.now(),
  );
  if (conflictSchedule == null) return null;
  List<LiveBand> bands = const [];
  try {
    bands = await container.read(liveChannelsProvider(reg).future);
  } catch (_) {
    bands = container.read(liveChannelsProvider(reg)).value ?? const [];
  }
  final target = findLiveChannelForSchedule(bands, conflictSchedule);
  final title = conflictSchedule.title;
  final displayTitle = (title == null || title.isEmpty) ? '予約番組' : title;
  return LiveRecordingConflict(
    schedule: conflictSchedule,
    displayTitle: displayTitle,
    channelName: target?.channelName,
    liveChannel: target,
  );
}

Widget _buildLivePlayerScreen({
  required ProviderContainer container,
  required RegisteredNasne reg,
  required LiveChannel channel,
  required PlaybackSession session,
  required bool useMobile,
  required List<RecordSchedule> initialSchedules,
}) {
  final start = channel.programStart;
  final end = channel.programEnd;
  final detailMetaParts = <String>[
    if (channel.channelName != null && channel.channelName!.isNotEmpty)
      channel.channelName!,
    if (start != null && end != null)
      '${formatDateTimeWithWeekdayJst(start)}–${formatTimeJst(end)}',
    if (channel.genre != null && channel.genre!.isNotEmpty) channel.genre!,
  ];
  final detailMeta =
      detailMetaParts.isEmpty ? null : detailMetaParts.join(' ・ ');
  final detailBody = formatProgramDetailBody(
    description: channel.description,
    longDescription: channel.longDescription,
  );
  return PlayerScreen(
    title: channel.channelName ?? channel.programTitle,
    session: session,
    live: true,
    programDetailTitle: channel.programTitle,
    programDetailMeta: detailMeta,
    programDetailBody: detailBody,
    currentLiveChannel: channel,
    initialRecordingSchedules: initialSchedules,
    onCheckRecordingConflict: () =>
        _resolveOtherChannelConflict(container, reg, channel),
    onBuildRecordingChannelPlayer: (target) async {
      final services = container.read(deviceServicesProvider(reg));
      final targetSchedules = await _fetchFreshSchedules(container, reg);
      final targetSession = await _startLiveSession(
        services.playback,
        target,
        useMobile: useMobile,
        allowQualityFallback: true,
      );
      return _buildLivePlayerScreen(
        container: container,
        reg: reg,
        channel: target,
        session: targetSession,
        useMobile: useMobile,
        initialSchedules: targetSchedules,
      );
    },
  );
}

Future<void> _launchLiveChannel({
  required BuildContext context,
  required WidgetRef ref,
  required RegisteredNasne reg,
  required LiveChannel channel,
  required bool useMobile,
  bool checkConflictBeforeStart = true,
  bool allowQualityFallback = false,
}) async {
  final container = ProviderScope.containerOf(context);
  final engine = container.read(deviceServicesProvider(reg)).playback;
  if (!engine.isSupported) {
    await showPlaybackUnsupportedDialog(context, subject: 'TV視聴');
    return;
  }
  if (channel.res.isEmpty) {
    showSnack(context, '視聴可能なコンテンツがありません');
    return;
  }
  final freshSchedules = await _fetchFreshSchedules(container, reg);
  if (!context.mounted) return;
  if (checkConflictBeforeStart) {
    final conflict = await _resolveOtherChannelConflict(
      container,
      reg,
      channel,
      knownSchedules: freshSchedules,
    );
    if (!context.mounted) return;
    if (conflict != null) {
      final switchToRecording = await showLiveRecordingConflictDialog(
        context,
        conflict: conflict,
        midStream: false,
      );
      if (!context.mounted) return;
      if (switchToRecording == true && conflict.liveChannel != null) {
        await _launchLiveChannel(
          context: context,
          ref: ref,
          reg: reg,
          channel: conflict.liveChannel!,
          useMobile: useMobile,
          checkConflictBeforeStart: false,
          allowQualityFallback: true,
        );
      }
      return;
    }
  }
  final sameChannelRecording =
      findActiveSameChannelRecording(
        freshSchedules,
        currentChannel: channel,
        now: DateTime.now(),
      ) !=
      null;
  await startPlaybackAndShowPlayer(
    context: context,
    ref: ref,
    start: () => _startLiveSession(
      engine,
      channel,
      useMobile: useMobile,
      allowQualityFallback: allowQualityFallback || sameChannelRecording,
    ),
    buildPlayer: (session) => _buildLivePlayerScreen(
      container: container,
      reg: reg,
      channel: channel,
      session: session,
      useMobile: useMobile,
      initialSchedules: freshSchedules,
    ),
    unsupportedSubject: 'TV視聴',
    startFailureMessage: '視聴を開始できませんでした',
  );
}
