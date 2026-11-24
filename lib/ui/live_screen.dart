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

import '../app/bs_epg_providers.dart';
import '../app/providers.dart';
import '../app/state.dart';
import '../core/core.dart';
import 'epg_subchannel_visibility.dart';
import 'error_messages.dart';
import 'format.dart';
import 'live_channel_switch_policy.dart';
import 'live_recording_policy.dart';
import 'multi_nasne_policy.dart';
import 'playback_launcher.dart';
import 'player_screen.dart';
import 'schedules_screen.dart' show twoPaneBreakpoint;
import 'widgets.dart';

class LiveScreen extends ConsumerStatefulWidget {
  const LiveScreen({super.key});

  @override
  ConsumerState<LiveScreen> createState() => _LiveScreenState();
}

class _LiveScreenState extends ConsumerState<LiveScreen>
    with WidgetsBindingObserver {
  String? _selectedId;
  final FocusNode _detailWatchFocusNode = FocusNode(debugLabel: 'liveWatch');

  /// Container id / band key whose tab is selected; null means the first band
  /// with channels.
  String? _selectedBandId;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (state == AppLifecycleState.resumed &&
        mounted &&
        ref.read(tabIndexProvider) == AppTabs.live) {
      _refreshOnReveal();
    }
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    _detailWatchFocusNode.dispose();
    super.dispose();
  }

  void _refreshOnReveal() {
    final regs =
        ref.read(registrationsProvider).value ?? const <RegisteredNasne>[];
    final selected = ref.read(selectedRegistrationProvider);
    final activeRegs = regs.length > 1
        ? regs
        : (selected != null ? [selected] : const <RegisteredNasne>[]);
    for (final r in activeRegs) {
      final bands = ref.read(liveChannelsProvider(r));
      if (bands.hasValue && !bands.isLoading) {
        ref.invalidate(liveChannelsProvider(r));
      }
      final sched = ref.read(schedulesProvider(r));
      if (sched.hasValue && !sched.isLoading) {
        ref.invalidate(schedulesProvider(r));
      }
    }
  }

  @override
  Widget build(BuildContext context) {
    ref.listen<int>(tabIndexProvider, (prev, next) {
      if (prev != AppTabs.live && next == AppTabs.live) {
        _refreshOnReveal();
      }
    });
    final reg = ref.watch(selectedRegistrationProvider);
    final regs =
        ref.watch(registrationsProvider).value ?? const <RegisteredNasne>[];
    final activeRegs = regs.length > 1
        ? regs
        : (reg != null ? [reg] : const <RegisteredNasne>[]);
    return Scaffold(
      appBar: AppBar(
        title: const Text('TV視聴'),
        actions: [
          if (reg != null)
            IconButton(
              icon: const Icon(Icons.refresh),
              tooltip: '更新',
              onPressed: () {
                for (final r in activeRegs) {
                  ref.invalidate(liveChannelsProvider(r));
                  ref.invalidate(schedulesProvider(r));
                }
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
              activeRegs: activeRegs,
              selectedId: _selectedId,
              selectedBandId: _selectedBandId,
              detailWatchFocusNode: _detailWatchFocusNode,
              onSelectBand: (bandId) =>
                  setState(() => _selectedBandId = bandId),
              onSelect: (selectionKey, channel, candidates, twoPane) {
                if (twoPane) {
                  setState(() => _selectedId = selectionKey);
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
                        candidates: candidates,
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

String _mergedBandTabLabel(MergedLiveBand band) => switch (band.kind) {
  LiveBandKind.terrestrial => '地デジ',
  LiveBandKind.bs => 'BS',
  LiveBandKind.cs => 'CS',
  LiveBandKind.other => band.title,
};

String _mergedBandTabKey(MergedLiveBand band) =>
    band.kind == LiveBandKind.other ? band.containerId : 'kind:${band.kind.name}';

class _LiveList extends ConsumerWidget {
  const _LiveList({
    required this.reg,
    required this.activeRegs,
    required this.selectedId,
    required this.selectedBandId,
    required this.detailWatchFocusNode,
    required this.onSelectBand,
    required this.onSelect,
  });

  final RegisteredNasne reg;
  final List<RegisteredNasne> activeRegs;
  final String? selectedId;
  final String? selectedBandId;
  final FocusNode detailWatchFocusNode;
  final ValueChanged<String> onSelectBand;
  final void Function(
    String selectionKey,
    LiveChannel channel,
    List<OwnedLiveChannel>? candidates,
    bool twoPane,
  )
  onSelect;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final showSubchannels = ref.watch(showSubchannelsProvider);
    final now = DateTime.now();

    if (activeRegs.length <= 1) {
      final bands = ref.watch(liveChannelsProvider(reg));
      final schedules =
          ref.watch(schedulesProvider(reg)).value ?? const <RecordSchedule>[];
      return asyncSection(
        bands,
        (list) {
          final visibleBands = liveBandsWithSubchannelSetting(
            list,
            showSubchannels,
          );
          final channels = [for (final band in visibleBands) ...band.channels];
          if (channels.isEmpty) {
            return const Center(child: Text('視聴可能なチャンネルがありません'));
          }
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
              final twoPane = constraints.maxWidth >= twoPaneBreakpoint;
              final listView = ListView(
                children: [
                  for (final channel in selectedBand.channels)
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
                          title: Text(
                            channel.channelName ?? channel.programTitle,
                          ),
                          subtitle: Text(
                            _channelSubtitle(channel),
                            maxLines: 2,
                            overflow: TextOverflow.ellipsis,
                          ),
                          trailing: isRecording
                              ? const _LiveRecordingBadge()
                              : null,
                          onTap: () => onSelect(
                            channel.id,
                            channel,
                            null,
                            twoPane,
                          ),
                        );
                      },
                    ),
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
        },
        skipLoadingOnReload: true,
        onRetry: () => ref.invalidate(liveChannelsProvider(reg)),
      );
    }

    // Multi-nasne merged mode: keep online nasnes usable even if another is
    // temporarily unreachable.
    final loadedSources = <({RegisteredNasne reg, List<LiveBand> bands})>[];
    final failedLabels = <String>[];
    var anyLoading = false;
    Object? firstError;
    final schedulesByHost = <String, List<RecordSchedule>>{};

    for (final r in activeRegs) {
      schedulesByHost[r.host] =
          ref.watch(schedulesProvider(r)).value ?? const <RecordSchedule>[];
      final async = ref.watch(liveChannelsProvider(r));
      final value = async.value;
      if (value != null) {
        loadedSources.add((
          reg: r,
          bands: liveBandsWithSubchannelSetting(value, showSubchannels),
        ));
      } else if (async.hasError) {
        failedLabels.add(nasneDisplayLabel(r));
        firstError ??= async.error;
      } else if (async.isLoading) {
        anyLoading = true;
      }
    }

    if (loadedSources.isEmpty) {
      if (anyLoading) return const LoadingView();
      return ErrorView(
        message: firstError != null
            ? userMessageForError(firstError)
            : '視聴可能なチャンネルを取得できませんでした',
        onRetry: () {
          for (final r in activeRegs) {
            ref.invalidate(liveChannelsProvider(r));
            ref.invalidate(schedulesProvider(r));
          }
        },
      );
    }

    final mergedBands = mergeLiveBands(loadedSources, preferredReg: reg);
    final tabBands = [
      for (final band in mergedBands)
        if (band.channels.isNotEmpty) band,
    ];
    if (tabBands.isEmpty) {
      return const Center(child: Text('視聴可能なチャンネルがありません'));
    }
    final allChannels = [for (final band in tabBands) ...band.channels];
    final selectedBand = tabBands.firstWhere(
      (band) =>
          _mergedBandTabKey(band) == selectedBandId ||
          band.containerId == selectedBandId,
      orElse: () => tabBands.first,
    );
    final selectedBandKey = _mergedBandTabKey(selectedBand);

    return LayoutBuilder(
      builder: (context, constraints) {
        final twoPane = constraints.maxWidth >= twoPaneBreakpoint;
        final listView = ListView(
          children: [
            for (final merged in selectedBand.channels)
              Builder(
                builder: (context) {
                  final ch = merged.primary;
                  final isRecording = merged.candidates.any(
                    (c) =>
                        findActiveSameChannelRecording(
                          schedulesByHost[c.reg.host] ??
                              const <RecordSchedule>[],
                          currentChannel: c.channel,
                          now: now,
                        ) !=
                        null,
                  );
                  return ListTile(
                    selected: merged.serviceKey == selectedId,
                    contentPadding: const EdgeInsets.symmetric(
                      horizontal: 16,
                      vertical: 8,
                    ),
                    leading: const Icon(Icons.live_tv_outlined),
                    title: Text(ch.channelName ?? ch.programTitle),
                    subtitle: Text(
                      _channelSubtitle(ch),
                      maxLines: 2,
                      overflow: TextOverflow.ellipsis,
                    ),
                    trailing: isRecording ? const _LiveRecordingBadge() : null,
                    onTap: () => onSelect(
                      merged.serviceKey,
                      merged.primary,
                      merged.candidates,
                      twoPane,
                    ),
                  );
                },
              ),
          ],
        );
        final content = Column(
          children: [
            if (failedLabels.isNotEmpty)
              Padding(
                padding: const EdgeInsets.fromLTRB(12, 8, 12, 0),
                child: Align(
                  alignment: Alignment.centerLeft,
                  child: Text(
                    '一部の nasne に接続できませんでした（${failedLabels.join('、')}）',
                    style: Theme.of(context).textTheme.bodySmall?.copyWith(
                      color: Theme.of(context).colorScheme.error,
                    ),
                  ),
                ),
              ),
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
                        value: _mergedBandTabKey(band),
                        label: Text(_mergedBandTabLabel(band)),
                      ),
                  ],
                  selected: {selectedBandKey},
                  onSelectionChanged: (selection) =>
                      onSelectBand(selection.first),
                ),
              ),
            Expanded(child: listView),
          ],
        );
        if (!twoPane) return content;
        MergedLiveChannel? selected;
        for (final m in allChannels) {
          if (m.serviceKey == selectedId) selected = m;
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
                      reg: selected.primaryReg,
                      channel: selected.primary,
                      candidates: selected.candidates,
                      watchFocusNode: detailWatchFocusNode,
                    ),
            ),
          ],
        );
      },
    );
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
  final regs =
      ref.read(registrationsProvider).value ?? const <RegisteredNasne>[];
  final activeRegs = regs.length > 1 ? regs : <RegisteredNasne>[reg];
  final candidates = <OwnedLiveChannel>[];
  var anySucceeded = false;

  for (final r in activeRegs) {
    try {
      final bands = await ref.read(liveChannelsProvider(r).future);
      anySucceeded = true;
      final live = liveChannelForService(
        bands,
        networkId: channel.networkId,
        transportStreamId: channel.transportStreamId,
        serviceId: channel.serviceId,
      );
      if (live != null) {
        candidates.add(OwnedLiveChannel(reg: r, channel: live));
      }
    } catch (_) {
      // Skip unavailable nasne; report below only if none responded.
    }
  }
  if (!context.mounted) return;
  if (!anySucceeded) {
    showSnack(context, 'チャンネル情報を取得できませんでした');
    return;
  }
  if (candidates.isEmpty) {
    showSnack(context, '視聴可能なチャンネルが見つかりません');
    return;
  }
  final primary = candidates.first;
  await Navigator.push(
    context,
    MaterialPageRoute<void>(
      builder: (_) => LiveChannelDetailPage(
        reg: primary.reg,
        channelId: primary.channel.id,
        candidates: candidates.length > 1 ? candidates : null,
      ),
    ),
  );
}

/// Detail page for narrow layouts.
class LiveChannelDetailPage extends ConsumerWidget {
  const LiveChannelDetailPage({
    super.key,
    required this.reg,
    required this.channelId,
    this.candidates,
  });

  final RegisteredNasne reg;
  final String channelId;
  final List<OwnedLiveChannel>? candidates;

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
                candidates: candidates,
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
    this.candidates,
    this.watchFocusNode,
    this.autofocusWatch = false,
  });

  final RegisteredNasne reg;
  final LiveChannel channel;
  final List<OwnedLiveChannel>? candidates;
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
    if (oldWidget.channel.id != widget.channel.id ||
        oldWidget.reg.host != widget.reg.host) {
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
    final effectiveCandidates =
        widget.candidates != null && widget.candidates!.isNotEmpty
        ? widget.candidates!
        : [OwnedLiveChannel(reg: reg, channel: ch)];
    final now = DateTime.now();
    final isChannelRecording = effectiveCandidates.any((c) {
      final scheds =
          ref.watch(schedulesProvider(c.reg)).value ?? const <RecordSchedule>[];
      return findActiveSameChannelRecording(
            scheds,
            currentChannel: c.channel,
            now: now,
          ) !=
          null;
    });
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
        candidates: widget.candidates,
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
        .listSchedules()
        .timeout(const Duration(seconds: 4));
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
  String? nasneName,
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
    nasneName: nasneName,
    sourceRegistration: reg,
  );
}

/// Checks [currentReg] for an active other-channel recording conflict and,
/// when [multiNasneRegs] has another nasne with a free or same-channel tuner
/// carrying the same broadcast channel, attaches automatic failover details.
Future<LiveRecordingConflict?> resolveLiveRecordingConflictOrFailover(
  ProviderContainer container,
  RegisteredNasne currentReg,
  LiveChannel currentChannel, {
  List<RegisteredNasne> multiNasneRegs = const [],
}) async {
  final isMulti = multiNasneRegs.length > 1;
  final conflict = await _resolveOtherChannelConflict(
    container,
    currentReg,
    currentChannel,
    nasneName: isMulti ? nasneDisplayLabel(currentReg) : null,
  );
  if (conflict == null) return null;
  if (!isMulti) return conflict;

  final serviceKey = liveServiceKey(currentChannel);
  final altCandidates = <OwnedLiveChannel>[];
  final altSchedulesByHost = <String, List<RecordSchedule>>{};
  for (final other in multiNasneRegs) {
    if (other.host == currentReg.host) continue;
    try {
      final bands = await container.read(liveChannelsProvider(other).future);
      LiveChannel? match;
      for (final b in bands) {
        for (final ch in b.channels) {
          if (liveServiceKey(ch) == serviceKey) {
            match = ch;
            break;
          }
        }
        if (match != null) break;
      }
      if (match == null) continue;
      final scheds = await _fetchFreshSchedules(container, other);
      altCandidates.add(OwnedLiveChannel(reg: other, channel: match));
      altSchedulesByHost[other.host] = scheds;
    } catch (_) {
      // Skip offline/unreachable alternate nasne.
    }
  }
  if (altCandidates.isEmpty) return conflict;
  final alt = selectLiveTunerCandidate(
    candidates: altCandidates,
    schedulesByHost: altSchedulesByHost,
    now: DateTime.now(),
    excludeHost: currentReg.host,
  );
  if (alt == null) return conflict;
  return LiveRecordingConflict(
    schedule: conflict.schedule,
    displayTitle: conflict.displayTitle,
    channelName: conflict.channelName,
    liveChannel: conflict.liveChannel,
    nasneName: conflict.nasneName,
    sourceRegistration: conflict.sourceRegistration,
    failoverRegistration: alt.target.reg,
    failoverChannel: alt.target.channel,
  );
}

Future<
  ({List<LiveChannelSwitchEntry> entries, int currentIndex})
> _resolveLiveSwitchContext({
  required ProviderContainer container,
  required RegisteredNasne currentReg,
  required LiveChannel currentChannel,
  required List<RegisteredNasne> multiNasneRegs,
}) async {
  final showSubchannels = container.read(showSubchannelsProvider);
  final targetKey = liveServiceKey(currentChannel);

  if (multiNasneRegs.length <= 1) {
    List<LiveBand> rawBands = const [];
    try {
      rawBands = await container
          .read(liveChannelsProvider(currentReg).future)
          .timeout(const Duration(seconds: 3));
    } catch (_) {
      rawBands = container.read(liveChannelsProvider(currentReg)).value ?? const [];
    }
    final bands = liveBandsWithSubchannelSetting(rawBands, showSubchannels);
    for (final band in bands) {
      final idx = band.channels.indexWhere(
        (c) => liveServiceKey(c) == targetKey || c.id == currentChannel.id,
      );
      if (idx >= 0) {
        return (
          entries: [
            for (final ch in band.channels)
              LiveChannelSwitchEntry(
                channel: ch,
                primaryReg: currentReg,
                candidates: [OwnedLiveChannel(reg: currentReg, channel: ch)],
              ),
          ],
          currentIndex: idx,
        );
      }
    }
    return (entries: const <LiveChannelSwitchEntry>[], currentIndex: -1);
  }

  final loadedSources = <({RegisteredNasne reg, List<LiveBand> bands})>[];
  for (final r in multiNasneRegs) {
    List<LiveBand>? raw;
    try {
      raw = await container
          .read(liveChannelsProvider(r).future)
          .timeout(const Duration(seconds: 3));
    } catch (_) {
      raw = container.read(liveChannelsProvider(r)).value;
    }
    if (raw != null) {
      loadedSources.add((
        reg: r,
        bands: liveBandsWithSubchannelSetting(raw, showSubchannels),
      ));
    }
  }
  if (loadedSources.isEmpty) {
    return (entries: const <LiveChannelSwitchEntry>[], currentIndex: -1);
  }
  final mergedBands = mergeLiveBands(loadedSources, preferredReg: currentReg);
  for (final band in mergedBands) {
    final idx = band.channels.indexWhere((m) => m.serviceKey == targetKey);
    if (idx >= 0) {
      return (
        entries: [
          for (final m in band.channels)
            LiveChannelSwitchEntry(
              channel: m.primary,
              primaryReg: m.primaryReg,
              candidates: m.candidates,
            ),
        ],
        currentIndex: idx,
      );
    }
  }
  return (entries: const <LiveChannelSwitchEntry>[], currentIndex: -1);
}

Widget _buildLivePlayerScreen({
  required ProviderContainer container,
  required RegisteredNasne reg,
  required LiveChannel channel,
  required PlaybackSession session,
  required bool useMobile,
  required List<RecordSchedule> initialSchedules,
  List<RegisteredNasne> multiNasneRegs = const [],
  List<LiveChannelSwitchEntry> liveSwitchChannels = const [],
  int currentLiveSwitchIndex = -1,
  String? initialCornerNotice,
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
  final scheduleOwnerById = <String, RegisteredNasne>{
    for (final s in initialSchedules) s.id: reg,
  };
  return PlayerScreen(
    title: channel.channelName ?? channel.programTitle,
    session: session,
    live: true,
    liveUseMobile: useMobile,
    programDetailTitle: channel.programTitle,
    programDetailMeta: detailMeta,
    programDetailBody: detailBody,
    currentLiveChannel: channel,
    initialRecordingSchedules: initialSchedules,
    liveSwitchChannels: liveSwitchChannels,
    currentLiveSwitchIndex: currentLiveSwitchIndex,
    initialCornerNotice: initialCornerNotice,
    onStartCurrentProgramRecording: () => _startCurrentLiveRecording(
      container: container,
      reg: reg,
      channel: channel,
      multiNasneRegs: multiNasneRegs,
      scheduleOwnerById: scheduleOwnerById,
    ),
    onStopCurrentProgramRecording: (activeSchedule) =>
        _stopCurrentLiveRecording(
          container: container,
          defaultReg: reg,
          activeSchedule: activeSchedule,
          multiNasneRegs: multiNasneRegs,
          scheduleOwnerById: scheduleOwnerById,
        ),
    onCheckRecordingConflict: () => resolveLiveRecordingConflictOrFailover(
      container,
      reg,
      channel,
      multiNasneRegs: multiNasneRegs,
    ),
    onSwitchLiveChannel: (
      playerContext,
      target,
      stopCurrentSession,
    ) =>
        _switchLivePlayerToChannel(
          container: container,
          playerContext: playerContext,
          target: target,
          stopCurrentSession: stopCurrentSession,
          useMobile: useMobile,
          multiNasneRegs: multiNasneRegs,
        ),
    onBuildFailoverPlayer: multiNasneRegs.length > 1
        ? (targetReg, targetChannel, notice) async {
            final services = container.read(deviceServicesProvider(targetReg));
            final targetSchedules = await _fetchFreshSchedules(
              container,
              targetReg,
            );
            final switchCtx = await _resolveLiveSwitchContext(
              container: container,
              currentReg: targetReg,
              currentChannel: targetChannel,
              multiNasneRegs: multiNasneRegs,
            );
            final targetSession = await _startLiveSession(
              services.playback,
              targetChannel,
              useMobile: useMobile,
              allowQualityFallback: true,
            );
            return _buildLivePlayerScreen(
              container: container,
              reg: targetReg,
              channel: targetChannel,
              session: targetSession,
              useMobile: useMobile,
              initialSchedules: targetSchedules,
              multiNasneRegs: multiNasneRegs,
              liveSwitchChannels: switchCtx.entries,
              currentLiveSwitchIndex: switchCtx.currentIndex,
              initialCornerNotice: notice,
            );
          }
        : null,
    onBuildRecordingChannelPlayer: (target) async {
      final services = container.read(deviceServicesProvider(reg));
      final targetSchedules = await _fetchFreshSchedules(container, reg);
      final switchCtx = await _resolveLiveSwitchContext(
        container: container,
        currentReg: reg,
        currentChannel: target,
        multiNasneRegs: multiNasneRegs,
      );
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
        multiNasneRegs: multiNasneRegs,
        liveSwitchChannels: switchCtx.entries,
        currentLiveSwitchIndex: switchCtx.currentIndex,
      );
    },
  );
}

Future<Widget?> _switchLivePlayerToChannel({
  required ProviderContainer container,
  required BuildContext playerContext,
  required LiveChannelSwitchEntry target,
  required Future<void> Function() stopCurrentSession,
  required bool useMobile,
  required List<RegisteredNasne> multiNasneRegs,
}) async {
  final effectiveCandidates = target.candidates.isNotEmpty
      ? target.candidates
      : [OwnedLiveChannel(reg: target.primaryReg, channel: target.channel)];
  var chosenReg = effectiveCandidates.first.reg;
  var chosenChannel = effectiveCandidates.first.channel;
  List<RecordSchedule> chosenSchedules;
  var allowQualityFallback = false;

  if (effectiveCandidates.length > 1) {
    final schedulesByHost = <String, List<RecordSchedule>>{};
    final fetched = await Future.wait([
      for (final c in effectiveCandidates)
        _fetchFreshSchedules(container, c.reg).then((s) => (c.reg, s)),
    ]);
    for (final entry in fetched) {
      schedulesByHost[entry.$1.host] = entry.$2;
    }
    if (!playerContext.mounted) return null;

    final selection = selectLiveTunerCandidate(
      candidates: effectiveCandidates,
      schedulesByHost: schedulesByHost,
      now: DateTime.now(),
      preferredReg: target.primaryReg,
    );
    if (selection == null) {
      final conflictOwner = effectiveCandidates.first;
      final conflict = await _resolveOtherChannelConflict(
        container,
        conflictOwner.reg,
        conflictOwner.channel,
        knownSchedules: schedulesByHost[conflictOwner.reg.host],
        nasneName: nasneDisplayLabel(conflictOwner.reg),
      );
      if (!playerContext.mounted) return null;
      if (conflict != null) {
        final switchToRecording = await showLiveRecordingConflictDialog(
          playerContext,
          conflict: conflict,
          midStream: false,
        );
        if (switchToRecording == true && conflict.liveChannel != null) {
          chosenReg = conflict.sourceRegistration ?? conflictOwner.reg;
          chosenChannel = conflict.liveChannel!;
          chosenSchedules = schedulesByHost[chosenReg.host] ?? const [];
          allowQualityFallback = true;
        } else {
          return null;
        }
      } else {
        chosenSchedules = schedulesByHost[chosenReg.host] ?? const [];
      }
    } else {
      chosenReg = selection.target.reg;
      chosenChannel = selection.target.channel;
      chosenSchedules = schedulesByHost[chosenReg.host] ?? const [];
      if (selection.sameChannelRecording) {
        allowQualityFallback = true;
      }
    }
  } else {
    chosenSchedules = await _fetchFreshSchedules(container, chosenReg);
    if (!playerContext.mounted) return null;
    final conflict = await _resolveOtherChannelConflict(
      container,
      chosenReg,
      chosenChannel,
      knownSchedules: chosenSchedules,
    );
    if (!playerContext.mounted) return null;
    if (conflict != null) {
      final switchToRecording = await showLiveRecordingConflictDialog(
        playerContext,
        conflict: conflict,
        midStream: false,
      );
      if (switchToRecording == true && conflict.liveChannel != null) {
        chosenReg = conflict.sourceRegistration ?? chosenReg;
        chosenChannel = conflict.liveChannel!;
        allowQualityFallback = true;
      } else {
        return null;
      }
    }
  }

  final sameChannelRecording =
      findActiveSameChannelRecording(
        chosenSchedules,
        currentChannel: chosenChannel,
        now: DateTime.now(),
      ) !=
      null;
  await stopCurrentSession();
  final engine = container.read(deviceServicesProvider(chosenReg)).playback;
  final targetSession = await _startLiveSession(
    engine,
    chosenChannel,
    useMobile: useMobile,
    allowQualityFallback: allowQualityFallback || sameChannelRecording,
  );
  final switchCtx = await _resolveLiveSwitchContext(
    container: container,
    currentReg: chosenReg,
    currentChannel: chosenChannel,
    multiNasneRegs: multiNasneRegs,
  );
  return _buildLivePlayerScreen(
    container: container,
    reg: chosenReg,
    channel: chosenChannel,
    session: targetSession,
    useMobile: useMobile,
    initialSchedules: chosenSchedules,
    multiNasneRegs: multiNasneRegs,
    liveSwitchChannels: switchCtx.entries,
    currentLiveSwitchIndex: switchCtx.currentIndex,
  );
}

Future<LiveRecordingActionResult> _startCurrentLiveRecording({
  required ProviderContainer container,
  required RegisteredNasne reg,
  required LiveChannel channel,
  required List<RegisteredNasne> multiNasneRegs,
  required Map<String, RegisteredNasne> scheduleOwnerById,
}) async {
  final now = DateTime.now();
  final bandType = broadcastingTypeForLiveBandId(channel.bandId);
  final isBs = bandType == bsBroadcastingType;

  Future<Channel?> resolveMatchingChannel(RegisteredNasne owner) async {
    var list = isBs
        ? (container.read(bsChannelsProvider(owner)).value ?? const <Channel>[])
        : (container.read(channelsProvider(owner)).value ?? const <Channel>[]);
    if (list.isEmpty && channel.networkId == null) {
      try {
        list = await container.read(
          (isBs ? bsChannelsProvider(owner) : channelsProvider(owner)).future,
        );
      } catch (_) {}
    }
    for (final c in list) {
      if (c.serviceId == channel.serviceId &&
          (channel.networkId == null || c.networkId == channel.networkId)) {
        return c;
      }
    }
    return null;
  }

  final matchingChannel = await resolveMatchingChannel(reg);
  final guide = isBs
      ? container.read(bsEpgGuideProvider(reg)).value
      : container.read(epgGuideProvider(reg)).value;
  EpgEvent? matchingEvent;
  if (guide != null && channel.serviceId != null) {
    for (final svc in guide.services) {
      if (svc.channel.serviceId != channel.serviceId) continue;
      for (final ev in svc.events) {
        if (!now.isBefore(ev.start) && ev.end.isAfter(now)) {
          matchingEvent = ev;
          break;
        }
      }
      if (matchingEvent != null) break;
    }
  }

  final quality = container.read(defaultRecordingQualityProvider);
  final candidate = buildImmediateLiveRecordingSchedule(
    channel: channel,
    now: now,
    desiredQualityMode: quality,
    matchingEpgEvent: matchingEvent,
    matchingChannel: matchingChannel,
  );
  if (candidate == null) {
    return const LiveRecordingActionResult(
      success: false,
      message: 'チャンネル情報を取得できないため録画を開始できません',
    );
  }

  var targetReg = reg;
  try {
    final currentConflicts = await container
        .read(deviceServicesProvider(reg))
        .schedules
        .checkConflicts(candidate);
    if (currentConflicts.isNotEmpty) {
      if (multiNasneRegs.length > 1) {
        final hasConflictByHost = <String, bool>{reg.host: true};
        final freeBytesByHost = <String, int>{
          reg.host: totalFreeBytesForHdds(
            container.read(hddDetailsProvider(reg)).value,
          ),
        };
        for (final other in multiNasneRegs) {
          if (other.host == reg.host) continue;
          freeBytesByHost[other.host] = totalFreeBytesForHdds(
            container.read(hddDetailsProvider(other)).value,
          );
          try {
            final c = await container
                .read(deviceServicesProvider(other))
                .schedules
                .checkConflicts(candidate);
            hasConflictByHost[other.host] = c.isNotEmpty;
          } catch (_) {
            hasConflictByHost[other.host] = true;
          }
        }
        final alt = selectAutoScheduleNasne(
          candidates: multiNasneRegs,
          hasConflictByHost: hasConflictByHost,
          freeBytesByHost: freeBytesByHost,
          preferredReg: reg,
        );
        if (alt == null) {
          return const LiveRecordingActionResult(
            success: false,
            message: '同じ時間帯に別の録画予約があるため開始できませんでした',
          );
        }
        targetReg = alt;
      } else {
        return const LiveRecordingActionResult(
          success: false,
          message: '同じ時間帯に別の録画予約があるため開始できませんでした',
        );
      }
    }

    final createdId = await container
        .read(deviceServicesProvider(targetReg))
        .schedules
        .createSchedule(candidate);
    scheduleOwnerById[createdId] = targetReg;
    container.invalidate(schedulesProvider(targetReg));
    final fresh = await _fetchFreshSchedules(container, targetReg);
    for (final s in fresh) {
      scheduleOwnerById.putIfAbsent(s.id, () => targetReg);
    }
    final fallbackSchedule = RecordSchedule(
      id: createdId,
      start: candidate.start,
      durationSeconds: candidate.durationSeconds,
      conditionId: candidate.conditionId.isEmpty ? '1' : candidate.conditionId,
      channel: candidate.channel,
      desiredQualityMode: candidate.desiredQualityMode,
      desiredMatchingId: candidate.desiredMatchingId,
      reservationCreatorId: candidate.reservationCreatorId,
      priorityFlag: candidate.priorityFlag,
      recordDestinationId: candidate.recordDestinationId,
      title: matchingEvent?.title ?? channel.programTitle,
    );
    final freshWithFallback = ensureSchedulePresent(fresh, fallbackSchedule);
    final merged = [
      ...freshWithFallback,
      if (targetReg.host != reg.host)
        ...await _fetchFreshSchedules(container, reg),
    ];
    return LiveRecordingActionResult(
      success: true,
      message: '録画を開始しました',
      updatedSchedules: merged,
    );
  } catch (e) {
    return LiveRecordingActionResult(
      success: false,
      message: userMessageForError(e),
    );
  }
}

Future<LiveRecordingActionResult> _stopCurrentLiveRecording({
  required ProviderContainer container,
  required RegisteredNasne defaultReg,
  required RecordSchedule activeSchedule,
  required List<RegisteredNasne> multiNasneRegs,
  required Map<String, RegisteredNasne> scheduleOwnerById,
}) async {
  final ownerReg = scheduleOwnerById[activeSchedule.id] ?? defaultReg;
  try {
    await container
        .read(deviceServicesProvider(ownerReg))
        .schedules
        .deleteSchedule(activeSchedule.id);
    scheduleOwnerById.remove(activeSchedule.id);
    container.invalidate(schedulesProvider(ownerReg));
    final freshOwner = await _fetchFreshSchedules(container, ownerReg);
    final merged = ownerReg.host == defaultReg.host
        ? freshOwner
        : [...freshOwner, ...await _fetchFreshSchedules(container, defaultReg)];
    return LiveRecordingActionResult(
      success: true,
      message: '録画を停止しました',
      updatedSchedules: schedulesWithoutId(merged, activeSchedule.id),
    );
  } catch (e) {
    return LiveRecordingActionResult(
      success: false,
      message: userMessageForError(e),
    );
  }
}

Future<void> _launchLiveChannel({
  required BuildContext context,
  required WidgetRef ref,
  required RegisteredNasne reg,
  required LiveChannel channel,
  required bool useMobile,
  List<OwnedLiveChannel>? candidates,
  bool checkConflictBeforeStart = true,
  bool allowQualityFallback = false,
}) async {
  final container = ProviderScope.containerOf(context);
  final regs =
      container.read(registrationsProvider).value ?? const <RegisteredNasne>[];
  final multiNasneRegs = regs.length > 1 ? regs : const <RegisteredNasne>[];
  final effectiveCandidates = (candidates != null && candidates.length > 1)
      ? candidates
      : <OwnedLiveChannel>[OwnedLiveChannel(reg: reg, channel: channel)];

  var chosenReg = effectiveCandidates.first.reg;
  var chosenChannel = effectiveCandidates.first.channel;
  List<RecordSchedule> chosenSchedules;

  if (effectiveCandidates.length > 1) {
    final schedulesByHost = <String, List<RecordSchedule>>{};
    final fetched = await Future.wait([
      for (final c in effectiveCandidates)
        _fetchFreshSchedules(container, c.reg).then((s) => (c.reg, s)),
    ]);
    for (final entry in fetched) {
      schedulesByHost[entry.$1.host] = entry.$2;
    }
    if (!context.mounted) return;

    final selection = selectLiveTunerCandidate(
      candidates: effectiveCandidates,
      schedulesByHost: schedulesByHost,
      now: DateTime.now(),
      preferredReg: reg,
    );
    if (selection == null) {
      if (checkConflictBeforeStart) {
        final conflictOwner = effectiveCandidates.first;
        final conflict = await _resolveOtherChannelConflict(
          container,
          conflictOwner.reg,
          conflictOwner.channel,
          knownSchedules: schedulesByHost[conflictOwner.reg.host],
          nasneName: nasneDisplayLabel(conflictOwner.reg),
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
              reg: conflict.sourceRegistration ?? conflictOwner.reg,
              channel: conflict.liveChannel!,
              useMobile: useMobile,
              checkConflictBeforeStart: false,
              allowQualityFallback: true,
            );
          }
          return;
        }
      }
      chosenSchedules = schedulesByHost[chosenReg.host] ?? const [];
    } else {
      chosenReg = selection.target.reg;
      chosenChannel = selection.target.channel;
      chosenSchedules = schedulesByHost[chosenReg.host] ?? const [];
      if (selection.sameChannelRecording) {
        allowQualityFallback = true;
      }
    }
  } else {
    chosenSchedules = await _fetchFreshSchedules(container, chosenReg);
    if (!context.mounted) return;
    if (checkConflictBeforeStart) {
      final conflict = await _resolveOtherChannelConflict(
        container,
        chosenReg,
        chosenChannel,
        knownSchedules: chosenSchedules,
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
            reg: conflict.sourceRegistration ?? chosenReg,
            channel: conflict.liveChannel!,
            useMobile: useMobile,
            checkConflictBeforeStart: false,
            allowQualityFallback: true,
          );
        }
        return;
      }
    }
  }

  final engine = container.read(deviceServicesProvider(chosenReg)).playback;
  if (!engine.isSupported) {
    await showPlaybackUnsupportedDialog(context, subject: 'TV視聴');
    return;
  }
  if (chosenChannel.res.isEmpty) {
    showSnack(context, '視聴可能なコンテンツがありません');
    return;
  }
  final sameChannelRecording =
      findActiveSameChannelRecording(
        chosenSchedules,
        currentChannel: chosenChannel,
        now: DateTime.now(),
      ) !=
      null;
  final switchCtx = await _resolveLiveSwitchContext(
    container: container,
    currentReg: chosenReg,
    currentChannel: chosenChannel,
    multiNasneRegs: multiNasneRegs,
  );
  if (!context.mounted) return;
  await startPlaybackAndShowPlayer(
    context: context,
    ref: ref,
    start: () => _startLiveSession(
      engine,
      chosenChannel,
      useMobile: useMobile,
      allowQualityFallback: allowQualityFallback || sameChannelRecording,
    ),
    buildPlayer: (session) => _buildLivePlayerScreen(
      container: container,
      reg: chosenReg,
      channel: chosenChannel,
      session: session,
      useMobile: useMobile,
      initialSchedules: chosenSchedules,
      multiNasneRegs: multiNasneRegs,
      liveSwitchChannels: switchCtx.entries,
      currentLiveSwitchIndex: switchCtx.currentIndex,
    ),
    unsupportedSubject: 'TV視聴',
    startFailureMessage: '視聴を開始できませんでした',
  );
}
