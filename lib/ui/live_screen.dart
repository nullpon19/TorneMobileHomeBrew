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
import 'dart:typed_data';

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:material_ui/material_ui.dart';

import '../app/bs_epg_providers.dart';
import '../app/providers.dart';
import '../app/state.dart';
import '../core/core.dart';
import 'channel_badge.dart';
import 'epg_genre.dart';
import 'epg_subchannel_visibility.dart';
import 'epg_title_badges.dart';
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

  void _handleTwoPanePlaybackReturned(
    LiveWatchedChannelTarget target, {
    required bool isMultiNasne,
  }) {
    final activeRegs =
        ref.read(registrationsProvider).value ?? const <RegisteredNasne>[];
    final regs = activeRegs.length > 1 ? activeRegs : <RegisteredNasne>[target.reg];
    for (final r in regs) {
      final liveAsync = ref.read(liveChannelsProvider(r));
      if (liveAsync.hasValue && !liveAsync.isLoading) {
        ref.invalidate(liveChannelsProvider(r));
      }
      final schedAsync = ref.read(schedulesProvider(r));
      if (schedAsync.hasValue && !schedAsync.isLoading) {
        ref.invalidate(schedulesProvider(r));
      }
    }
    setState(() {
      _selectedId = isMultiNasne ? target.serviceKey : target.channel.id;
      _selectedBandId = target.channel.bandId;
    });
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (mounted && _detailWatchFocusNode.canRequestFocus) {
        _detailWatchFocusNode.requestFocus();
      }
    });
  }

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
                  ref.invalidate(channelsProvider(r));
                  ref.invalidate(bsChannelsProvider(r));
                  ref.invalidate(csChannelsProvider(r));
                  ref.invalidate(epgGuideProvider(r));
                  ref.invalidate(bsEpgGuideProvider(r));
                  unawaited(invalidateChannelLogosWithCacheReset(ref, r));
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
              onPlaybackReturned: (target) => _handleTwoPanePlaybackReturned(
                target,
                isMultiNasne: activeRegs.length > 1,
              ),
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

class _LiveChannelListTile extends StatelessWidget {
  const _LiveChannelListTile({
    required this.channel,
    required this.display,
    required this.selected,
    required this.isRecording,
    this.channelNumber,
    this.logoBytes,
    required this.onTap,
  });

  final LiveChannel channel;
  final ResolvedLiveChannelDisplay display;
  final bool selected;
  final bool isRecording;
  final String? channelNumber;
  final Uint8List? logoBytes;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final subtitleStyle = theme.textTheme.bodyMedium?.copyWith(
      color: theme.colorScheme.onSurfaceVariant,
    );
    final metaStyle = theme.textTheme.bodySmall?.copyWith(
      color: theme.colorScheme.onSurfaceVariant,
      fontFeatures: const [FontFeature.tabularFigures()],
    );
    final nextTitle = display.nextProgramTitle?.trim() ?? '';
    final nextRange = display.nextTimeRange;
    final progressBarColor = theme.brightness == Brightness.dark
        ? Colors.lightBlueAccent
        : const Color(0xFF0288D1);
    return ListTile(
      selected: selected,
      contentPadding: const EdgeInsets.symmetric(
        horizontal: 16,
        vertical: 8,
      ),
      leading: SizedBox(
        width: 52,
        child: Column(
          mainAxisSize: MainAxisSize.min,
          mainAxisAlignment: MainAxisAlignment.center,
          children: [
            if (logoBytes != null)
              ChannelLogoPlate(bytes: logoBytes!, width: 48, height: 27)
            else
              const Icon(Icons.live_tv_outlined, size: 26),
            if (channelNumber != null) ...[
              const SizedBox(height: 3),
              Text(
                channelNumber!,
                style: theme.textTheme.bodyMedium?.copyWith(
                  color: theme.colorScheme.onSurface.withValues(alpha: 0.88),
                  fontSize: 14.5,
                  fontWeight: FontWeight.w700,
                  height: 1.15,
                  fontFeatures: const [FontFeature.tabularFigures()],
                ),
              ),
            ],
          ],
        ),
      ),
      title: Text(
        channel.channelName ?? display.programTitle,
        maxLines: 1,
        overflow: TextOverflow.ellipsis,
      ),
      subtitle: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          if (channel.channelName != null)
            Row(
              children: [
                if (display.programStart != null &&
                    display.programEnd != null) ...[
                  Text(
                    '${formatTimeJst(display.programStart!)}–${formatTimeJst(display.programEnd!)}',
                    style: subtitleStyle,
                  ),
                  const SizedBox(width: 6),
                ],
                Expanded(
                  child: BroadcastTitleLine(
                    rawTitle: display.programTitle,
                    maxLines: 1,
                    darkSurface: theme.brightness == Brightness.dark,
                    badgeScale: 1.0,
                    maxAttributeBadges: 4,
                    style: subtitleStyle,
                  ),
                ),
              ],
            )
          else
            Text(
              _channelSubtitleFromDisplay(channel, display),
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: subtitleStyle,
            ),
          if (display.progress != null) ...[
            const SizedBox(height: 5),
            ClipRRect(
              borderRadius: BorderRadius.circular(2),
              child: LinearProgressIndicator(
                value: display.progress,
                minHeight: 4,
                color: progressBarColor,
                backgroundColor: theme.colorScheme.surfaceContainerHighest,
              ),
            ),
          ],
          if (nextTitle.isNotEmpty) ...[
            const SizedBox(height: 5),
            Row(
              children: [
                Container(
                  padding: const EdgeInsets.symmetric(
                    horizontal: 5,
                    vertical: 1,
                  ),
                  decoration: BoxDecoration(
                    color: theme.colorScheme.surfaceContainerHighest,
                    borderRadius: BorderRadius.circular(4),
                  ),
                  child: Text(
                    '次',
                    style: theme.textTheme.labelSmall?.copyWith(
                      fontSize: 10,
                      fontWeight: FontWeight.w700,
                    ),
                  ),
                ),
                const SizedBox(width: 6),
                if (nextRange != null) ...[
                  Text(nextRange, style: metaStyle),
                  const SizedBox(width: 6),
                ],
                Expanded(
                  child: BroadcastTitleLine(
                    rawTitle: nextTitle,
                    maxLines: 1,
                    darkSurface: theme.brightness == Brightness.dark,
                    badgeScale: 0.92,
                    maxAttributeBadges: 3,
                    style: metaStyle,
                  ),
                ),
              ],
            ),
          ],
        ],
      ),
      trailing: isRecording ? const _LiveRecordingBadge() : null,
      onTap: onTap,
    );
  }
}

class _LiveList extends ConsumerStatefulWidget {
  const _LiveList({
    required this.reg,
    required this.activeRegs,
    required this.selectedId,
    required this.selectedBandId,
    required this.detailWatchFocusNode,
    required this.onSelectBand,
    required this.onPlaybackReturned,
    required this.onSelect,
  });

  final RegisteredNasne reg;
  final List<RegisteredNasne> activeRegs;
  final String? selectedId;
  final String? selectedBandId;
  final FocusNode detailWatchFocusNode;
  final ValueChanged<String> onSelectBand;
  final ValueChanged<LiveWatchedChannelTarget> onPlaybackReturned;
  final void Function(
    String selectionKey,
    LiveChannel channel,
    List<OwnedLiveChannel>? candidates,
    bool twoPane,
  )
  onSelect;

  @override
  ConsumerState<_LiveList> createState() => _LiveListState();
}

class _LiveListState extends ConsumerState<_LiveList>
    with WidgetsBindingObserver {
  Timer? _refreshTimer;
  DateTime? _scheduledTargetAt;
  bool _scheduledIsBoundary = false;
  DateTime? _lastBoundaryInvalidateAt;
  bool _appResumed = true;
  int _clockTick = 0;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    final nextResumed = state == AppLifecycleState.resumed;
    if (_appResumed != nextResumed) {
      _appResumed = nextResumed;
      if (!nextResumed) {
        _cancelRefreshTimer();
      } else if (mounted) {
        setState(() => _clockTick++);
      }
    }
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    _cancelRefreshTimer();
    super.dispose();
  }

  void _cancelRefreshTimer() {
    _refreshTimer?.cancel();
    _refreshTimer = null;
    _scheduledTargetAt = null;
  }

  void _scheduleAutoRefresh({
    required List<({LiveChannel channel, ResolvedLiveChannelDisplay display})>
    items,
    required DateTime now,
    required bool enabled,
  }) {
    if (!enabled || items.isEmpty) {
      _cancelRefreshTimer();
      return;
    }
    final next = computeNextLiveListRefresh(
      programEnds: [for (final item in items) item.display.programEnd],
      now: now,
    );
    final targetAt = now.add(next.delay);
    final existing = _refreshTimer;
    final existingTarget = _scheduledTargetAt;
    if (existing != null &&
        existing.isActive &&
        existingTarget != null &&
        _scheduledIsBoundary == next.isBoundary &&
        existingTarget.difference(targetAt).abs() <
            const Duration(seconds: 2)) {
      return;
    }
    _cancelRefreshTimer();
    _scheduledTargetAt = targetAt;
    _scheduledIsBoundary = next.isBoundary;
    final bandTypes = <int>{};
    if (next.isBoundary) {
      for (final item in items) {
        final bandType = broadcastingTypeForLiveBandId(item.channel.bandId);
        if (bandType == terrestrialBroadcastingType ||
            bandType == bsBroadcastingType) {
          bandTypes.add(bandType!);
        }
      }
    }
    _refreshTimer = Timer(next.delay, () {
      _refreshTimer = null;
      _scheduledTargetAt = null;
      if (!mounted || !_appResumed || !TickerMode.valuesOf(context).enabled) {
        return;
      }
      final fireNow = DateTime.now();
      if (next.isBoundary &&
          (_lastBoundaryInvalidateAt == null ||
              fireNow.difference(_lastBoundaryInvalidateAt!) >=
                  const Duration(seconds: 5))) {
        _lastBoundaryInvalidateAt = fireNow;
        for (final r in widget.activeRegs) {
          final liveAsync = ref.read(liveChannelsProvider(r));
          if (liveAsync.hasValue && !liveAsync.isLoading) {
            ref.invalidate(liveChannelsProvider(r));
          }
          final schedAsync = ref.read(schedulesProvider(r));
          if (schedAsync.hasValue && !schedAsync.isLoading) {
            ref.invalidate(schedulesProvider(r));
          }
          if (bandTypes.contains(terrestrialBroadcastingType)) {
            final epg = ref.read(epgGuideProvider(r)).value;
            final epgTo = epg?.to;
            if (epg == null || (epgTo != null && !epgTo.isAfter(fireNow))) {
              ref.invalidate(epgGuideProvider(r));
            }
          }
          if (bandTypes.contains(bsBroadcastingType)) {
            final bsEpg = ref.read(bsEpgGuideProvider(r)).value;
            final bsTo = bsEpg?.to;
            if (bsEpg == null || (bsTo != null && !bsTo.isAfter(fireNow))) {
              ref.invalidate(bsEpgGuideProvider(r));
            }
          }
        }
      }
      setState(() => _clockTick++);
    });
  }

  ({
    ResolvedLiveChannelDisplay display,
    bool isRecording,
    String? channelNumber,
    Uint8List? logoBytes,
  }) _resolveRowState({
    required RegisteredNasne ownerReg,
    required LiveChannel channel,
    required List<OwnedLiveChannel> candidates,
    required Map<String, List<RecordSchedule>> schedulesByHost,
    required DateTime now,
  }) {
    final bandType = broadcastingTypeForLiveBandId(channel.bandId);
    final display = resolveLiveChannelDisplay(
      channel: channel,
      guideEvents: _watchedGuideEventsForChannel(ref, ownerReg, channel),
      now: now,
    );
    final activeSched = _firstActiveScheduleForCandidates(
      candidates,
      schedulesByHost,
      now: now,
    );
    final isRecording = isProgramMatchingActiveRecording(
      activeSchedule: activeSched,
      programStart: display.programStart,
      programEnd: display.programEnd,
      now: now,
    );
    final bandChannels = _watchedBandChannels(ref, ownerReg, bandType);
    final bandLogos = _watchedBandLogos(ref, ownerReg, bandType);
    return (
      display: display,
      isRecording: isRecording,
      channelNumber: resolveLiveChannelNumberLabel(channel, bandChannels),
      logoBytes: resolveLiveChannelLogoBytes(channel, bandLogos),
    );
  }

  Widget _buildEpgLoadingBanner(BuildContext context) {
    final theme = Theme.of(context);
    return Padding(
      padding: const EdgeInsets.fromLTRB(16, 0, 16, 6),
      child: Row(
        children: [
          const SizedBox(
            width: 14,
            height: 14,
            child: CircularProgressIndicator(strokeWidth: 2),
          ),
          const SizedBox(width: 8),
          Flexible(
            child: Text(
              '次の番組を読み込み中…',
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: theme.textTheme.bodySmall?.copyWith(
                color: theme.colorScheme.onSurfaceVariant,
              ),
            ),
          ),
        ],
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final _ = _clockTick;
    final showSubchannels = ref.watch(showSubchannelsProvider);
    final now = DateTime.now();
    final tickerEnabled = TickerMode.valuesOf(context).enabled && _appResumed;

    if (widget.activeRegs.length <= 1) {
      final bands = ref.watch(liveChannelsProvider(widget.reg));
      final schedulesByHost = <String, List<RecordSchedule>>{
        widget.reg.host:
            ref.watch(schedulesProvider(widget.reg)).value ??
            const <RecordSchedule>[],
      };
      return asyncSection(
        bands,
        (list) {
          final visibleBands = liveBandsWithSubchannelSetting(
            list,
            showSubchannels,
          );
          final channels = [for (final band in visibleBands) ...band.channels];
          if (channels.isEmpty) {
            _cancelRefreshTimer();
            return const Center(child: Text('視聴可能なチャンネルがありません'));
          }
          final tabBands = [
            for (final band in visibleBands)
              if (band.channels.isNotEmpty) band,
          ];
          final selectedBand = tabBands.firstWhere(
            (band) => band.containerId == widget.selectedBandId,
            orElse: () => tabBands.first,
          );
          final rows = [
            for (final channel in selectedBand.channels)
              () {
                final state = _resolveRowState(
                  ownerReg: widget.reg,
                  channel: channel,
                  candidates: [
                    OwnedLiveChannel(reg: widget.reg, channel: channel),
                  ],
                  schedulesByHost: schedulesByHost,
                  now: now,
                );
                return (
                  channel: channel,
                  display: state.display,
                  isRecording: state.isRecording,
                  channelNumber: state.channelNumber,
                  logoBytes: state.logoBytes,
                );
              }(),
          ];
          final selectedBandType = selectedBand.channels.isNotEmpty
              ? broadcastingTypeForLiveBandId(selectedBand.channels.first.bandId)
              : null;
          final epgLoading = _isBandEpgLoading(
            ref,
            [widget.reg],
            selectedBandType,
          );
          _scheduleAutoRefresh(
            items: [
              for (final r in rows) (channel: r.channel, display: r.display),
            ],
            now: now,
            enabled: tickerEnabled,
          );
          return LayoutBuilder(
            builder: (context, constraints) {
              final twoPane = constraints.maxWidth >= twoPaneBreakpoint;
              final listView = ListView(
                children: [
                  for (final row in rows)
                    _LiveChannelListTile(
                      channel: row.channel,
                      display: row.display,
                      selected: row.channel.id == widget.selectedId,
                      isRecording: row.isRecording,
                      channelNumber: row.channelNumber,
                      logoBytes: row.logoBytes,
                      onTap: () => widget.onSelect(
                        row.channel.id,
                        row.channel,
                        null,
                        twoPane,
                      ),
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
                            widget.onSelectBand(selection.first),
                      ),
                    ),
                  if (epgLoading) _buildEpgLoadingBanner(context),
                  Expanded(child: listView),
                ],
              );
              if (!twoPane) return content;
              LiveChannel? selected;
              for (final channel in channels) {
                if (channel.id == widget.selectedId) selected = channel;
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
                            reg: widget.reg,
                            channel: selected,
                            watchFocusNode: widget.detailWatchFocusNode,
                            onLivePlaybackReturned: widget.onPlaybackReturned,
                          ),
                  ),
                ],
              );
            },
          );
        },
        skipLoadingOnReload: bands.hasValue,
        onRetry: () {
          if (bands.hasError) {
            ref.invalidate(httpClientProvider);
          }
          ref.invalidate(liveChannelsProvider(widget.reg));
        },
      );
    }

    // Multi-nasne merged mode: keep online nasnes usable even if another is
    // temporarily unreachable.
    final loadedSources = <({RegisteredNasne reg, List<LiveBand> bands})>[];
    final failedLabels = <String>[];
    var anyLoading = false;
    Object? firstError;
    final schedulesByHost = <String, List<RecordSchedule>>{};

    for (final r in widget.activeRegs) {
      schedulesByHost[r.host] =
          ref.watch(schedulesProvider(r)).value ?? const <RecordSchedule>[];
      final async = ref.watch(liveChannelsProvider(r));
      final value = async.value;
      if (value != null) {
        loadedSources.add((
          reg: r,
          bands: liveBandsWithSubchannelSetting(value, showSubchannels),
        ));
      } else if (async.isLoading) {
        anyLoading = true;
      } else if (async.hasError) {
        failedLabels.add(nasneDisplayLabel(r));
        firstError ??= async.error;
      }
    }

    if (loadedSources.isEmpty) {
      _cancelRefreshTimer();
      if (anyLoading) return const LoadingView();
      return ErrorView(
        message: firstError != null
            ? userMessageForError(firstError)
            : '視聴可能なチャンネルを取得できませんでした',
        onRetry: () {
          ref.invalidate(httpClientProvider);
          for (final r in widget.activeRegs) {
            ref.invalidate(liveChannelsProvider(r));
            ref.invalidate(schedulesProvider(r));
          }
        },
      );
    }

    final mergedBands = mergeLiveBands(loadedSources, preferredReg: widget.reg);
    final tabBands = [
      for (final band in mergedBands)
        if (band.channels.isNotEmpty) band,
    ];
    if (tabBands.isEmpty) {
      _cancelRefreshTimer();
      return const Center(child: Text('視聴可能なチャンネルがありません'));
    }
    final allChannels = [for (final band in tabBands) ...band.channels];
    final selectedBand = tabBands.firstWhere(
      (band) =>
          _mergedBandTabKey(band) == widget.selectedBandId ||
          band.containerId == widget.selectedBandId,
      orElse: () => tabBands.first,
    );
    final selectedBandKey = _mergedBandTabKey(selectedBand);
    final mergedRows = [
      for (final merged in selectedBand.channels)
        () {
          final state = _resolveRowState(
            ownerReg: merged.primaryReg,
            channel: merged.primary,
            candidates: merged.candidates,
            schedulesByHost: schedulesByHost,
            now: now,
          );
          return (
            merged: merged,
            display: state.display,
            isRecording: state.isRecording,
            channelNumber: state.channelNumber,
            logoBytes: state.logoBytes,
          );
        }(),
    ];
    final selectedBandType = selectedBand.channels.isNotEmpty
        ? broadcastingTypeForLiveBandId(
            selectedBand.channels.first.primary.bandId,
          )
        : null;
    final epgLoading = _isBandEpgLoading(
      ref,
      [for (final s in loadedSources) s.reg],
      selectedBandType,
    );
    _scheduleAutoRefresh(
      items: [
        for (final r in mergedRows)
          (channel: r.merged.primary, display: r.display),
      ],
      now: now,
      enabled: tickerEnabled,
    );

    return LayoutBuilder(
      builder: (context, constraints) {
        final twoPane = constraints.maxWidth >= twoPaneBreakpoint;
        final listView = ListView(
          children: [
            for (final row in mergedRows)
              _LiveChannelListTile(
                channel: row.merged.primary,
                display: row.display,
                selected: row.merged.serviceKey == widget.selectedId,
                isRecording: row.isRecording,
                channelNumber: row.channelNumber,
                logoBytes: row.logoBytes,
                onTap: () => widget.onSelect(
                  row.merged.serviceKey,
                  row.merged.primary,
                  row.merged.candidates,
                  twoPane,
                ),
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
                      widget.onSelectBand(selection.first),
                ),
              ),
            if (epgLoading) _buildEpgLoadingBanner(context),
            Expanded(child: listView),
          ],
        );
        if (!twoPane) return content;
        MergedLiveChannel? selected;
        for (final m in allChannels) {
          if (m.serviceKey == widget.selectedId) selected = m;
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
                      watchFocusNode: widget.detailWatchFocusNode,
                      onLivePlaybackReturned: widget.onPlaybackReturned,
                    ),
            ),
          ],
        );
      },
    );
  }
}

/// Last-viewed live channel returned when exiting live playback or closing
/// the live detail page, used to sync detail views and the EPG cursor.
class LiveWatchedChannelTarget {
  const LiveWatchedChannelTarget({
    required this.reg,
    required this.channel,
    required this.exitedAt,
  });

  final RegisteredNasne reg;
  final LiveChannel channel;
  final DateTime exitedAt;

  int? get bandType => broadcastingTypeForLiveBandId(channel.bandId);
  String get serviceKey => liveServiceKey(channel);
}

/// Display-ready current programme metadata for a live channel list tile or
/// detail view, preferring active EPG data when cached and falling back cleanly
/// to the [LiveChannel] snapshot.
class ResolvedLiveChannelDisplay {
  const ResolvedLiveChannelDisplay({
    required this.programTitle,
    this.programStart,
    this.programEnd,
    this.genre,
    this.shortDescription,
    this.longDescription,
    this.progress,
    this.nextProgramTitle,
    this.nextProgramStart,
    this.nextProgramEnd,
  });

  final String programTitle;
  final DateTime? programStart;
  final DateTime? programEnd;
  final String? genre;
  final String? shortDescription;
  final String? longDescription;
  final double? progress;
  final String? nextProgramTitle;
  final DateTime? nextProgramStart;
  final DateTime? nextProgramEnd;

  String? get nextTimeRange =>
      (nextProgramStart != null && nextProgramEnd != null)
      ? '${formatTimeJst(nextProgramStart!)}–${formatTimeJst(nextProgramEnd!)}'
      : null;
}

double? _computeProgramProgress(
  DateTime? start,
  DateTime? end,
  DateTime now,
) {
  if (start == null || end == null || !end.isAfter(start)) return null;
  final totalMs = end.difference(start).inMilliseconds;
  if (totalMs <= 0) return null;
  final elapsedMs = now.difference(start).inMilliseconds;
  return (elapsedMs / totalMs).clamp(0.0, 1.0).toDouble();
}

/// Computes the next scheduled refresh delay for [_LiveList] from visible
/// programme end times so progress bars advance every [progressInterval] and
/// boundaries across any channel trigger immediately upon programme rollover.
({Duration delay, bool isBoundary}) computeNextLiveListRefresh({
  required Iterable<DateTime?> programEnds,
  required DateTime now,
  Duration progressInterval = const Duration(seconds: 30),
  Duration boundaryMargin = const Duration(seconds: 1),
}) {
  DateTime? earliestEnd;
  for (final end in programEnds) {
    if (end == null || !end.isAfter(now)) continue;
    if (earliestEnd == null || end.isBefore(earliestEnd)) {
      earliestEnd = end;
    }
  }
  if (earliestEnd != null) {
    final remaining = earliestEnd.difference(now) + boundaryMargin;
    if (remaining <= progressInterval) {
      final clamped = remaining < const Duration(seconds: 1)
          ? const Duration(seconds: 1)
          : remaining;
      return (delay: clamped, isBoundary: true);
    }
  }
  return (delay: progressInterval, isBoundary: false);
}

/// Resolves the currently broadcasting programme metadata for [channel] at
/// [now] from [guideEvents], falling back to [channel]'s snapshot without
/// leaking an expired programme's description into a newer EPG event.
ResolvedLiveChannelDisplay resolveLiveChannelDisplay({
  required LiveChannel channel,
  required List<EpgEvent> guideEvents,
  required DateTime now,
}) {
  final info = resolveLiveOsdProgramInfo(
    channel: channel,
    guideEvents: guideEvents,
    now: now,
  );
  final ev = info.currentEvent;
  if (ev == null) {
    return ResolvedLiveChannelDisplay(
      programTitle: channel.programTitle,
      programStart: channel.programStart,
      programEnd: channel.programEnd,
      genre: channel.genre,
      shortDescription: channel.description,
      longDescription: channel.longDescription,
      progress: _computeProgramProgress(
        channel.programStart,
        channel.programEnd,
        now,
      ),
      nextProgramTitle: info.nextTitle,
      nextProgramStart: info.nextStart,
      nextProgramEnd: info.nextEnd,
    );
  }
  final hasChannelTimes =
      channel.programStart != null || channel.programEnd != null;
  final sameSlot =
      channel.programStart != null &&
      channel.programEnd != null &&
      channel.programStart!.isAtSameMomentAs(ev.start) &&
      channel.programEnd!.isAtSameMomentAs(ev.end);
  final channelActiveAtNow =
      channel.programStart != null &&
      channel.programEnd != null &&
      !now.isBefore(channel.programStart!) &&
      channel.programEnd!.isAfter(now);
  if (!sameSlot &&
      channelActiveAtNow &&
      channel.programTitle.trim().isNotEmpty) {
    final sorted = sortEpgEventsByStart(guideEvents);
    final nextCutoff = channel.programEnd!.subtract(const Duration(minutes: 1));
    EpgEvent? nextAfterChannel;
    for (final candidate in sorted) {
      final candidateTitle = candidate.title?.trim() ?? '';
      if (candidateTitle.isEmpty || !candidate.end.isAfter(now)) continue;
      if (!candidate.start.isBefore(nextCutoff)) {
        nextAfterChannel = candidate;
        break;
      }
    }
    return ResolvedLiveChannelDisplay(
      programTitle: channel.programTitle.trim(),
      programStart: channel.programStart,
      programEnd: channel.programEnd,
      genre: channel.genre,
      shortDescription: channel.description,
      longDescription: channel.longDescription,
      progress: _computeProgramProgress(
        channel.programStart,
        channel.programEnd,
        now,
      ),
      nextProgramTitle: nextAfterChannel?.title?.trim() ?? info.nextTitle,
      nextProgramStart: nextAfterChannel?.start ?? info.nextStart,
      nextProgramEnd: nextAfterChannel?.end ?? info.nextEnd,
    );
  }
  final preserveChannelFields = sameSlot || !hasChannelTimes;
  final evTitle = (ev.title ?? '').trim();
  final evGenre = epgGenreLabel(ev.genreLevel1);
  final evShort = ev.shortText?.trim() ?? '';
  final evDesc = ev.description?.trim() ?? '';
  final evCast = ev.cast?.trim() ?? '';

  String? evShortDescription;
  String? evLongDescription;
  if (evShort.isNotEmpty && evDesc.isNotEmpty) {
    if (evDesc == evShort || evDesc.startsWith(evShort)) {
      evShortDescription = evDesc;
      evLongDescription = evCast.isNotEmpty ? '出演: $evCast' : null;
    } else {
      evShortDescription = evShort;
      evLongDescription = evDesc;
    }
  } else if (evShort.isNotEmpty) {
    evShortDescription = evShort;
    evLongDescription = evCast.isNotEmpty ? '出演: $evCast' : null;
  } else if (evDesc.isNotEmpty) {
    evShortDescription = evDesc;
    evLongDescription = evCast.isNotEmpty ? '出演: $evCast' : null;
  } else if (evCast.isNotEmpty) {
    evLongDescription = '出演: $evCast';
  }

  if (preserveChannelFields) {
    final resolvedStart = channel.programStart ?? ev.start;
    final resolvedEnd = channel.programEnd ?? ev.end;
    return ResolvedLiveChannelDisplay(
      programTitle: channel.programTitle.trim().isNotEmpty
          ? channel.programTitle
          : (evTitle.isNotEmpty ? evTitle : info.currentTitle),
      programStart: resolvedStart,
      programEnd: resolvedEnd,
      genre: (channel.genre != null && channel.genre!.trim().isNotEmpty)
          ? channel.genre
          : evGenre,
      shortDescription:
          (channel.description != null &&
              channel.description!.trim().isNotEmpty)
          ? channel.description
          : evShortDescription,
      longDescription:
          (channel.longDescription != null &&
              channel.longDescription!.trim().isNotEmpty)
          ? channel.longDescription
          : evLongDescription,
      progress: _computeProgramProgress(resolvedStart, resolvedEnd, now),
      nextProgramTitle: info.nextTitle,
      nextProgramStart: info.nextStart,
      nextProgramEnd: info.nextEnd,
    );
  }

  return ResolvedLiveChannelDisplay(
    programTitle: evTitle.isNotEmpty ? evTitle : info.currentTitle,
    programStart: ev.start,
    programEnd: ev.end,
    genre: evGenre,
    shortDescription: evShortDescription,
    longDescription: evLongDescription,
    progress: _computeProgramProgress(ev.start, ev.end, now),
    nextProgramTitle: info.nextTitle,
    nextProgramStart: info.nextStart,
    nextProgramEnd: info.nextEnd,
  );
}

List<EpgEvent> _watchedGuideEventsForChannel(
  WidgetRef ref,
  RegisteredNasne reg,
  LiveChannel channel,
) {
  final bandType = broadcastingTypeForLiveBandId(channel.bandId);
  EpgGuide? guide;
  if (bandType == terrestrialBroadcastingType) {
    guide = ref.watch(epgGuideProvider(reg)).value;
  } else if (bandType == bsBroadcastingType) {
    guide = ref.watch(bsEpgGuideProvider(reg)).value;
  }
  return _serviceEventsFromGuide(guide, channel);
}

List<Channel> _watchedBandChannels(
  WidgetRef ref,
  RegisteredNasne reg,
  int? bandType,
) {
  if (bandType == terrestrialBroadcastingType) {
    final direct = ref.watch(channelsProvider(reg)).value;
    if (direct != null && direct.isNotEmpty) return direct;
    final guide = ref.watch(epgGuideProvider(reg)).value;
    return [for (final s in guide?.services ?? const <EpgServiceGuide>[]) s.channel];
  }
  if (bandType == bsBroadcastingType) {
    final direct = ref.watch(bsChannelsProvider(reg)).value;
    if (direct != null && direct.isNotEmpty) return direct;
    final guide = ref.watch(bsEpgGuideProvider(reg)).value;
    return [for (final s in guide?.services ?? const <EpgServiceGuide>[]) s.channel];
  }
  if (bandType == csBroadcastingType) {
    return ref.watch(csChannelsProvider(reg)).value ?? const <Channel>[];
  }
  return const <Channel>[];
}

Map<int, List<int>> _watchedBandLogos(
  WidgetRef ref,
  RegisteredNasne reg,
  int? bandType,
) {
  if (bandType == terrestrialBroadcastingType) {
    return ref.watch(channelLogosProvider(reg)).value ??
        const <int, List<int>>{};
  }
  if (bandType == bsBroadcastingType) {
    return ref.watch(bsChannelLogosProvider(reg)).value ??
        const <int, List<int>>{};
  }
  if (bandType == csBroadcastingType) {
    return ref.watch(csChannelLogosProvider(reg)).value ??
        const <int, List<int>>{};
  }
  return const <int, List<int>>{};
}

bool _isBandEpgLoading(
  WidgetRef ref,
  Iterable<RegisteredNasne> regs,
  int? bandType,
) {
  if (bandType == terrestrialBroadcastingType) {
    for (final r in regs) {
      final a = ref.watch(epgGuideProvider(r));
      if (a.isLoading && !a.hasValue) return true;
    }
  } else if (bandType == bsBroadcastingType) {
    for (final r in regs) {
      final a = ref.watch(bsEpgGuideProvider(r));
      if (a.isLoading && !a.hasValue) return true;
    }
  }
  return false;
}

RecordSchedule? _firstActiveScheduleForCandidates(
  List<OwnedLiveChannel> candidates,
  Map<String, List<RecordSchedule>> schedulesByHost, {
  required DateTime now,
}) {
  for (final c in candidates) {
    final scheds = schedulesByHost[c.reg.host] ?? const <RecordSchedule>[];
    final active = findActiveSameChannelRecording(
      scheds,
      currentChannel: c.channel,
      now: now,
    );
    if (active != null) return active;
  }
  return null;
}

String _channelSubtitleFromDisplay(
  LiveChannel channel,
  ResolvedLiveChannelDisplay display,
) {
  final start = display.programStart;
  final end = display.programEnd;
  final range = start != null && end != null
      ? '${formatTimeJst(start)}–${formatTimeJst(end)} '
      : '';
  if (channel.channelName != null) return '$range${display.programTitle}';
  return '$range${display.shortDescription ?? ''}';
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
Future<LiveWatchedChannelTarget?> openLiveChannelForEpg(
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
  final now = DateTime.now();

  for (final r in activeRegs) {
    final schedAsync = ref.read(schedulesProvider(r));
    if (schedAsync.hasValue && !schedAsync.isLoading) {
      ref.invalidate(schedulesProvider(r));
    }
    final cached = ref.read(liveChannelsProvider(r)).value;
    if (cached != null) {
      final cachedLive = liveChannelForService(
        cached,
        networkId: channel.networkId,
        transportStreamId: channel.transportStreamId,
        serviceId: channel.serviceId,
      );
      final isExpired =
          cachedLive == null ||
          (cachedLive.programEnd != null &&
              !cachedLive.programEnd!.isAfter(now)) ||
          _hasStaleLiveBand(cached, cachedLive.bandId, now);
      if (isExpired) {
        ref.invalidate(liveChannelsProvider(r));
      }
    }
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
  if (!context.mounted) return null;
  if (!anySucceeded) {
    showSnack(context, 'チャンネル情報を取得できませんでした');
    return null;
  }
  if (candidates.isEmpty) {
    showSnack(context, '視聴可能なチャンネルが見つかりません');
    return null;
  }
  final primary = candidates.first;
  LiveWatchedChannelTarget? latestTarget = LiveWatchedChannelTarget(
    reg: primary.reg,
    channel: primary.channel,
    exitedAt: DateTime.now(),
  );
  await Navigator.push<void>(
    context,
    MaterialPageRoute<void>(
      builder: (_) => LiveChannelDetailPage(
        reg: primary.reg,
        channelId: primary.channel.id,
        candidates: candidates.length > 1 ? candidates : null,
        onActiveChannelChanged: (target) => latestTarget = target,
      ),
    ),
  );
  if (latestTarget == null) return null;
  return LiveWatchedChannelTarget(
    reg: latestTarget!.reg,
    channel: latestTarget!.channel,
    exitedAt: DateTime.now(),
  );
}

/// Detail page for narrow layouts.
class LiveChannelDetailPage extends ConsumerStatefulWidget {
  const LiveChannelDetailPage({
    super.key,
    required this.reg,
    required this.channelId,
    this.candidates,
    this.onActiveChannelChanged,
  });

  final RegisteredNasne reg;
  final String channelId;
  final List<OwnedLiveChannel>? candidates;
  final ValueChanged<LiveWatchedChannelTarget>? onActiveChannelChanged;

  @override
  ConsumerState<LiveChannelDetailPage> createState() =>
      _LiveChannelDetailPageState();
}

class _LiveChannelDetailPageState extends ConsumerState<LiveChannelDetailPage> {
  late RegisteredNasne _activeReg;
  late String _activeChannelId;
  List<OwnedLiveChannel>? _activeCandidates;
  LiveChannel? _fallbackChannel;

  @override
  void initState() {
    super.initState();
    _activeReg = widget.reg;
    _activeChannelId = widget.channelId;
    _activeCandidates = widget.candidates;
  }

  void _handlePlaybackReturned(LiveWatchedChannelTarget target) {
    final regs =
        ref.read(registrationsProvider).value ?? const <RegisteredNasne>[];
    final nextCandidates = <OwnedLiveChannel>[];
    if (regs.length > 1) {
      final targetKey = target.serviceKey;
      for (final r in regs) {
        final bands = ref.read(liveChannelsProvider(r)).value;
        if (bands == null) continue;
        for (final band in bands) {
          for (final ch in band.channels) {
            if (liveServiceKey(ch) == targetKey) {
              nextCandidates.add(OwnedLiveChannel(reg: r, channel: ch));
            }
          }
        }
      }
    }
    setState(() {
      _activeReg = target.reg;
      _activeChannelId = target.channel.id;
      _fallbackChannel = target.channel;
      _activeCandidates = nextCandidates.length > 1 ? nextCandidates : null;
    });
    widget.onActiveChannelChanged?.call(target);
  }

  @override
  Widget build(BuildContext context) {
    final bands = ref.watch(liveChannelsProvider(_activeReg));
    return Scaffold(
      appBar: AppBar(title: const Text('チャンネルの詳細')),
      body: asyncSection(
        bands,
        (list) {
          LiveChannel? matched;
          final fallback = _fallbackChannel;
          final fallbackKey = fallback != null ? liveServiceKey(fallback) : null;
          for (final band in list) {
            for (final ch in band.channels) {
              if (ch.id == _activeChannelId) {
                matched = ch;
                break;
              }
            }
            if (matched != null) break;
          }
          if (matched == null && fallbackKey != null) {
            for (final band in list) {
              for (final ch in band.channels) {
                if (liveServiceKey(ch) == fallbackKey) {
                  matched = ch;
                  break;
                }
              }
              if (matched != null) break;
            }
          }
          matched ??= _fallbackChannel;
          if (matched != null) {
            return LiveChannelDetailView(
              reg: _activeReg,
              channel: matched,
              candidates: _activeCandidates,
              autofocusWatch: true,
              onLivePlaybackReturned: _handlePlaybackReturned,
            );
          }
          return const Center(child: Text('チャンネルが見つかりません'));
        },
        skipLoadingOnReload: true,
        onRetry: () => ref.invalidate(liveChannelsProvider(_activeReg)),
      ),
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
    this.onLivePlaybackReturned,
  });

  final RegisteredNasne reg;
  final LiveChannel channel;
  final List<OwnedLiveChannel>? candidates;
  final FocusNode? watchFocusNode;
  final bool autofocusWatch;
  final ValueChanged<LiveWatchedChannelTarget>? onLivePlaybackReturned;

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
    final guideEvents = _watchedGuideEventsForChannel(ref, reg, ch);
    final display = resolveLiveChannelDisplay(
      channel: ch,
      guideEvents: guideEvents,
      now: now,
    );
    final schedulesByHost = <String, List<RecordSchedule>>{
      for (final c in effectiveCandidates)
        c.reg.host:
            ref.watch(schedulesProvider(c.reg)).value ??
            const <RecordSchedule>[],
    };
    final activeSchedule = _firstActiveScheduleForCandidates(
      effectiveCandidates,
      schedulesByHost,
      now: now,
    );
    final isChannelRecording = isProgramMatchingActiveRecording(
      activeSchedule: activeSchedule,
      programStart: display.programStart,
      programEnd: display.programEnd,
      now: now,
    );
    final bandType = broadcastingTypeForLiveBandId(ch.bandId);
    final bandChannels = _watchedBandChannels(ref, reg, bandType);
    final bandLogos = _watchedBandLogos(ref, reg, bandType);
    final channelNumber = resolveLiveChannelNumberLabel(ch, bandChannels);
    final logoBytes = resolveLiveChannelLogoBytes(ch, bandLogos);
    final start = display.programStart;
    final end = display.programEnd;
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
        BroadcastTitleHeading(
          rawTitle: display.programTitle,
          style: Theme.of(context).textTheme.titleLarge,
          maxLines: 3,
          darkSurface: Theme.of(context).brightness == Brightness.dark,
        ),
        const SizedBox(height: 8),
        if (ch.channelName != null || channelNumber != null || logoBytes != null)
          Padding(
            padding: const EdgeInsets.symmetric(vertical: 3),
            child: Row(
              crossAxisAlignment: CrossAxisAlignment.center,
              children: [
                SizedBox(
                  width: 104,
                  child: Text(
                    'チャンネル',
                    style: Theme.of(context).textTheme.bodyMedium?.copyWith(
                      color: Theme.of(context).colorScheme.onSurfaceVariant,
                    ),
                  ),
                ),
                if (logoBytes != null) ...[
                  ChannelLogoPlate(bytes: logoBytes, width: 42, height: 24),
                  const SizedBox(width: 8),
                ],
                if (channelNumber != null) ...[
                  ChannelNumberBadge(label: channelNumber),
                  const SizedBox(width: 8),
                ],
                Expanded(child: Text(ch.channelName ?? '')),
              ],
            ),
          ),
        if (start != null && end != null)
          FieldRow(
            label: '放送時間',
            value:
                '${formatDateTimeWithWeekdayJst(start)}–${formatTimeJst(end)}',
          ),
        if (display.genre != null && display.genre!.isNotEmpty)
          FieldRow(label: 'ジャンル', value: display.genre!),
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
        if (display.shortDescription != null &&
            display.shortDescription!.isNotEmpty) ...[
          const SizedBox(height: 12),
          Text(
            display.shortDescription!,
            maxLines: 2,
            overflow: TextOverflow.ellipsis,
            style: Theme.of(context).textTheme.bodySmall,
          ),
        ],
        if (display.longDescription != null &&
            display.longDescription!.isNotEmpty) ...[
          const SizedBox(height: 6),
          Text(
            display.longDescription!,
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
      final returnedTarget = await _launchLiveChannel(
        context: context,
        ref: ref,
        reg: reg,
        channel: channel,
        useMobile: useMobile,
        candidates: widget.candidates,
      );
      if (!mounted) return;
      final effectiveRegs = <RegisteredNasne>{
        reg,
        if (returnedTarget != null) returnedTarget.reg,
        if (widget.candidates != null)
          for (final c in widget.candidates!) c.reg,
      };
      for (final r in effectiveRegs) {
        final liveAsync = ref.read(liveChannelsProvider(r));
        if ((liveAsync.hasValue && !liveAsync.isLoading) ||
            (returnedTarget != null && r.host == returnedTarget.reg.host)) {
          ref.invalidate(liveChannelsProvider(r));
        }
        final schedAsync = ref.read(schedulesProvider(r));
        if ((schedAsync.hasValue && !schedAsync.isLoading) ||
            (returnedTarget != null && r.host == returnedTarget.reg.host)) {
          ref.invalidate(schedulesProvider(r));
        }
      }
      if (returnedTarget != null) {
        widget.onLivePlaybackReturned?.call(returnedTarget);
      }
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

Future<List<LiveBand>?> _fetchLiveBandsForSwitch({
  required ProviderContainer container,
  required RegisteredNasne reg,
  required String targetBandId,
  required DateTime now,
  required bool refreshIfStale,
  required bool forceRefresh,
}) async {
  if (forceRefresh) {
    container.invalidate(liveChannelsProvider(reg));
  } else if (refreshIfStale) {
    final cached = container.read(liveChannelsProvider(reg)).value;
    if (cached != null && _hasStaleLiveBand(cached, targetBandId, now)) {
      container.invalidate(liveChannelsProvider(reg));
    }
  }
  try {
    return await container
        .read(liveChannelsProvider(reg).future)
        .timeout(const Duration(seconds: 3));
  } catch (_) {
    return container.read(liveChannelsProvider(reg)).value;
  }
}

Future<
  ({List<LiveChannelSwitchEntry> entries, int currentIndex})
> _resolveLiveSwitchContext({
  required ProviderContainer container,
  required RegisteredNasne currentReg,
  required LiveChannel currentChannel,
  required List<RegisteredNasne> multiNasneRegs,
  bool refreshIfStale = false,
  bool forceRefresh = false,
}) async {
  final showSubchannels = container.read(showSubchannelsProvider);
  final targetKey = liveServiceKey(currentChannel);
  final now = DateTime.now();

  if (multiNasneRegs.length <= 1) {
    final rawBands =
        await _fetchLiveBandsForSwitch(
          container: container,
          reg: currentReg,
          targetBandId: currentChannel.bandId,
          now: now,
          refreshIfStale: refreshIfStale,
          forceRefresh: forceRefresh,
        ) ??
        const <LiveBand>[];
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
    final raw = await _fetchLiveBandsForSwitch(
      container: container,
      reg: r,
      targetBandId: currentChannel.bandId,
      now: now,
      refreshIfStale: refreshIfStale,
      forceRefresh: forceRefresh,
    );
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

LiveChannel _resolveChannelFromSwitchContext(
  ({List<LiveChannelSwitchEntry> entries, int currentIndex}) switchCtx, {
  required RegisteredNasne ownerReg,
  required LiveChannel fallback,
}) {
  if (switchCtx.currentIndex < 0 ||
      switchCtx.currentIndex >= switchCtx.entries.length) {
    return fallback;
  }
  final entry = switchCtx.entries[switchCtx.currentIndex];
  final fallbackKey = liveServiceKey(fallback);
  for (final candidate in entry.candidates) {
    if (candidate.reg.host == ownerReg.host &&
        (liveServiceKey(candidate.channel) == fallbackKey ||
            candidate.channel.id == fallback.id)) {
      return candidate.channel;
    }
  }
  return entry.channel;
}

bool _hasStaleLiveBand(
  List<LiveBand> bands,
  String targetBandId,
  DateTime now,
) {
  for (final band in bands) {
    if (band.containerId != targetBandId) continue;
    for (final ch in band.channels) {
      final end = ch.programEnd;
      if (end != null && !end.isAfter(now)) return true;
    }
  }
  return false;
}

EpgGuide? _cachedEpgGuideForBand(
  ProviderContainer container,
  RegisteredNasne reg,
  int? bandType,
) {
  if (bandType == terrestrialBroadcastingType) {
    return container.read(epgGuideProvider(reg)).value;
  }
  if (bandType == bsBroadcastingType) {
    return container.read(bsEpgGuideProvider(reg)).value;
  }
  return null;
}

Future<EpgGuide?> _loadEpgGuideForBand(
  ProviderContainer container,
  RegisteredNasne reg,
  int? bandType,
) async {
  final provider = switch (bandType) {
    terrestrialBroadcastingType => epgGuideProvider(reg),
    bsBroadcastingType => bsEpgGuideProvider(reg),
    _ => null,
  };
  if (provider == null) return null;
  try {
    return await container
        .read(provider.future)
        .timeout(const Duration(seconds: 10));
  } catch (_) {
    return null;
  }
}

Map<String, List<EpgEvent>> _bandGuideEventsMap(
  EpgGuide? guide,
  Iterable<LiveChannel> channels,
) {
  if (guide == null) return const {};
  final result = <String, List<EpgEvent>>{};
  for (final ch in channels) {
    final key = liveServiceKey(ch);
    if (result.containsKey(key)) continue;
    final events = _serviceEventsFromGuide(guide, ch);
    if (events.isNotEmpty) {
      result[key] = events;
    }
  }
  return result;
}

List<EpgEvent> _serviceEventsFromGuide(EpgGuide? guide, LiveChannel channel) {
  if (guide == null || channel.serviceId == null) return const [];
  for (final svc in guide.services) {
    if (svc.channel.serviceId == channel.serviceId &&
        (channel.networkId == null ||
            svc.channel.networkId == channel.networkId)) {
      return svc.events;
    }
  }
  return const [];
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
  void Function(RegisteredNasne ownerReg, LiveChannel? lastChannel)?
      onLiveSessionFinished,
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
  final canSwitchQuality =
      channel.originalRes != null &&
      channel.mobileRes != null &&
      channel.originalRes != channel.mobileRes;
  final bandType = broadcastingTypeForLiveBandId(channel.bandId);
  final cachedGuide = _cachedEpgGuideForBand(container, reg, bandType);
  final bandChannels = <LiveChannel>[
    channel,
    for (final entry in liveSwitchChannels) entry.channel,
  ];
  final initialLiveGuideEvents = _serviceEventsFromGuide(cachedGuide, channel);
  final initialLiveBandGuideEvents = _bandGuideEventsMap(
    cachedGuide,
    bandChannels,
  );
  ({Map<String, String> numbers, Map<String, Uint8List> logos})
  buildCachedChannelMeta() {
    final cachedChannels = switch (bandType) {
      terrestrialBroadcastingType =>
        container.read(channelsProvider(reg)).value ??
            [for (final s in cachedGuide?.services ?? const <EpgServiceGuide>[]) s.channel],
      bsBroadcastingType =>
        container.read(bsChannelsProvider(reg)).value ??
            [for (final s in cachedGuide?.services ?? const <EpgServiceGuide>[]) s.channel],
      csBroadcastingType =>
        container.read(csChannelsProvider(reg)).value ?? const <Channel>[],
      _ => const <Channel>[],
    };
    final cachedLogos = switch (bandType) {
      terrestrialBroadcastingType =>
        container.read(channelLogosProvider(reg)).value ??
            const <int, List<int>>{},
      bsBroadcastingType =>
        container.read(bsChannelLogosProvider(reg)).value ??
            const <int, List<int>>{},
      csBroadcastingType =>
        container.read(csChannelLogosProvider(reg)).value ??
            const <int, List<int>>{},
      _ => const <int, List<int>>{},
    };
    final numbers = <String, String>{};
    final logos = <String, Uint8List>{};
    for (final ch in bandChannels) {
      final key = liveServiceKey(ch);
      final numLabel = resolveLiveChannelNumberLabel(ch, cachedChannels);
      if (numLabel != null) numbers[key] = numLabel;
      final logo = resolveLiveChannelLogoBytes(ch, cachedLogos);
      if (logo != null) logos[key] = logo;
    }
    return (numbers: numbers, logos: logos);
  }

  final initialMeta = buildCachedChannelMeta();
  return PlayerScreen(
    title: channel.channelName ?? channel.programTitle,
    session: session,
    live: true,
    liveUseMobile: useMobile,
    initialLiveGuideEvents: initialLiveGuideEvents,
    loadLiveGuideEvents: () async {
      final guide = await _loadEpgGuideForBand(container, reg, bandType);
      return _serviceEventsFromGuide(guide, channel);
    },
    initialLiveBandGuideEvents: initialLiveBandGuideEvents,
    loadLiveBandGuideEvents: () async {
      final guide = await _loadEpgGuideForBand(container, reg, bandType);
      return _bandGuideEventsMap(guide, bandChannels);
    },
    initialLiveChannelNumbers: initialMeta.numbers,
    initialLiveChannelLogos: initialMeta.logos,
    loadLiveChannelMetadata: () async {
      List<Channel> channels = const [];
      Map<int, List<int>> rawLogos = const {};
      final channelProvider = switch (bandType) {
        terrestrialBroadcastingType => channelsProvider(reg),
        bsBroadcastingType => bsChannelsProvider(reg),
        csBroadcastingType => csChannelsProvider(reg),
        _ => null,
      };
      final logoProvider = switch (bandType) {
        terrestrialBroadcastingType => channelLogosProvider(reg),
        bsBroadcastingType => bsChannelLogosProvider(reg),
        csBroadcastingType => csChannelLogosProvider(reg),
        _ => null,
      };
      await Future.wait([
        if (channelProvider != null)
          () async {
            try {
              channels = await container
                  .read(channelProvider.future)
                  .timeout(const Duration(seconds: 6));
            } catch (_) {}
          }(),
        if (logoProvider != null)
          () async {
            try {
              rawLogos = await container
                  .read(logoProvider.future)
                  .timeout(const Duration(seconds: 6));
            } catch (_) {}
          }(),
      ]);
      final numbers = <String, String>{};
      final logos = <String, Uint8List>{};
      for (final ch in bandChannels) {
        final key = liveServiceKey(ch);
        final numLabel = resolveLiveChannelNumberLabel(ch, channels);
        if (numLabel != null) numbers[key] = numLabel;
        final logo = resolveLiveChannelLogoBytes(ch, rawLogos);
        if (logo != null) logos[key] = logo;
      }
      return (numbers: numbers, logos: logos);
    },
    onRefreshLiveChannels: () async {
      final refreshed = await _resolveLiveSwitchContext(
        container: container,
        currentReg: reg,
        currentChannel: channel,
        multiNasneRegs: multiNasneRegs,
        forceRefresh: true,
      );
      return refreshed.entries;
    },
    canSwitchQuality: canSwitchQuality,
    currentUseMobile: useMobile,
    programDetailTitle: channel.programTitle,
    programDetailMeta: detailMeta,
    programDetailBody: detailBody,
    currentLiveChannel: channel,
    initialRecordingSchedules: initialSchedules,
    liveSwitchChannels: liveSwitchChannels,
    currentLiveSwitchIndex: currentLiveSwitchIndex,
    initialCornerNotice: initialCornerNotice,
    onLivePlaybackFinished: onLiveSessionFinished == null
        ? null
        : (lastChannel) => onLiveSessionFinished(reg, lastChannel ?? channel),
    onSwitchQuality: canSwitchQuality
        ? (
            playerContext,
            nextUseMobile,
            _,
            stopCurrentSession,
          ) async {
            await stopCurrentSession();
            final engine = container.read(deviceServicesProvider(reg)).playback;
            var actualUseMobile = nextUseMobile;
            String? notice;
            PlaybackSession nextSession;
            try {
              nextSession = await _startLiveSession(
                engine,
                channel,
                useMobile: nextUseMobile,
                allowQualityFallback: false,
              );
              notice = nextUseMobile ? 'モバイル画質に切り替えました' : '元画質に切り替えました';
            } on NasneError {
              actualUseMobile = useMobile;
              nextSession = await _startLiveSession(
                engine,
                channel,
                useMobile: useMobile,
                allowQualityFallback: true,
              );
              notice = '録画中などのため画質を切り替えられませんでした（元の画質で継続）';
            }
            if (!playerContext.mounted) {
              await nextSession.stop();
              return null;
            }
            late final List<RecordSchedule> freshSchedules;
            late final ({
              List<LiveChannelSwitchEntry> entries,
              int currentIndex,
            }) switchCtx;
            try {
              freshSchedules = await _fetchFreshSchedules(container, reg);
              switchCtx = await _resolveLiveSwitchContext(
                container: container,
                currentReg: reg,
                currentChannel: channel,
                multiNasneRegs: multiNasneRegs,
                refreshIfStale: true,
              );
            } catch (_) {
              await nextSession.stop();
              rethrow;
            }
            if (!playerContext.mounted) {
              await nextSession.stop();
              return null;
            }
            final effectiveChannel = _resolveChannelFromSwitchContext(
              switchCtx,
              ownerReg: reg,
              fallback: channel,
            );
            return _buildLivePlayerScreen(
              container: container,
              reg: reg,
              channel: effectiveChannel,
              session: nextSession,
              useMobile: actualUseMobile,
              initialSchedules: freshSchedules,
              multiNasneRegs: multiNasneRegs,
              liveSwitchChannels: switchCtx.entries,
              currentLiveSwitchIndex: switchCtx.currentIndex,
              initialCornerNotice: notice,
              onLiveSessionFinished: onLiveSessionFinished,
            );
          }
        : null,
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
          onLiveSessionFinished: onLiveSessionFinished,
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
              refreshIfStale: true,
            );
            final effectiveChannel = _resolveChannelFromSwitchContext(
              switchCtx,
              ownerReg: targetReg,
              fallback: targetChannel,
            );
            final targetSession = await _startLiveSession(
              services.playback,
              effectiveChannel,
              useMobile: useMobile,
              allowQualityFallback: true,
            );
            return _buildLivePlayerScreen(
              container: container,
              reg: targetReg,
              channel: effectiveChannel,
              session: targetSession,
              useMobile: useMobile,
              initialSchedules: targetSchedules,
              multiNasneRegs: multiNasneRegs,
              liveSwitchChannels: switchCtx.entries,
              currentLiveSwitchIndex: switchCtx.currentIndex,
              initialCornerNotice: notice,
              onLiveSessionFinished: onLiveSessionFinished,
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
        refreshIfStale: true,
      );
      final effectiveTarget = _resolveChannelFromSwitchContext(
        switchCtx,
        ownerReg: reg,
        fallback: target,
      );
      final targetSession = await _startLiveSession(
        services.playback,
        effectiveTarget,
        useMobile: useMobile,
        allowQualityFallback: true,
      );
      return _buildLivePlayerScreen(
        container: container,
        reg: reg,
        channel: effectiveTarget,
        session: targetSession,
        useMobile: useMobile,
        initialSchedules: targetSchedules,
        multiNasneRegs: multiNasneRegs,
        liveSwitchChannels: switchCtx.entries,
        currentLiveSwitchIndex: switchCtx.currentIndex,
        onLiveSessionFinished: onLiveSessionFinished,
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
  void Function(RegisteredNasne ownerReg, LiveChannel? lastChannel)?
      onLiveSessionFinished,
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
  if (!playerContext.mounted) {
    await targetSession.stop();
    return null;
  }
  late final ({
    List<LiveChannelSwitchEntry> entries,
    int currentIndex,
  }) switchCtx;
  try {
    switchCtx = await _resolveLiveSwitchContext(
      container: container,
      currentReg: chosenReg,
      currentChannel: chosenChannel,
      multiNasneRegs: multiNasneRegs,
      refreshIfStale: true,
    );
  } catch (_) {
    await targetSession.stop();
    rethrow;
  }
  if (!playerContext.mounted) {
    await targetSession.stop();
    return null;
  }
  final effectiveChannel = _resolveChannelFromSwitchContext(
    switchCtx,
    ownerReg: chosenReg,
    fallback: chosenChannel,
  );
  return _buildLivePlayerScreen(
    container: container,
    reg: chosenReg,
    channel: effectiveChannel,
    session: targetSession,
    useMobile: useMobile,
    initialSchedules: chosenSchedules,
    multiNasneRegs: multiNasneRegs,
    liveSwitchChannels: switchCtx.entries,
    currentLiveSwitchIndex: switchCtx.currentIndex,
    onLiveSessionFinished: onLiveSessionFinished,
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

  Future<Channel?> resolveMatchingChannel(RegisteredNasne owner) async {
    final provider = switch (bandType) {
      terrestrialBroadcastingType => channelsProvider(owner),
      bsBroadcastingType => bsChannelsProvider(owner),
      _ => null,
    };
    if (provider == null) return null;
    var list = container.read(provider).value ?? const <Channel>[];
    if (list.isEmpty && channel.networkId == null) {
      try {
        list = await container
            .read(provider.future)
            .timeout(const Duration(seconds: 3));
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
  final guide = _cachedEpgGuideForBand(container, reg, bandType);
  EpgEvent? matchingEvent;
  if (guide != null) {
    final svcEvents = _serviceEventsFromGuide(guide, channel);
    matchingEvent = findActiveEpgEvent(sortEpgEventsByStart(svcEvents), now);
  }

  var effectiveChannel = channel;
  if (matchingEvent == null &&
      (channel.programEnd == null || !channel.programEnd!.isAfter(now))) {
    try {
      container.invalidate(liveChannelsProvider(reg));
      final bands = await container
          .read(liveChannelsProvider(reg).future)
          .timeout(const Duration(seconds: 3));
      final targetKey = liveServiceKey(channel);
      for (final b in bands) {
        for (final ch in b.channels) {
          if (liveServiceKey(ch) == targetKey || ch.id == channel.id) {
            effectiveChannel = ch;
            break;
          }
        }
      }
    } catch (_) {}
  }

  final quality = container.read(defaultRecordingQualityProvider);
  final candidate = buildImmediateLiveRecordingSchedule(
    channel: effectiveChannel,
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
      title: matchingEvent?.title ?? effectiveChannel.programTitle,
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

Future<LiveWatchedChannelTarget?> _launchLiveChannel({
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
    if (!context.mounted) return null;

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
        if (!context.mounted) return null;
        if (conflict != null) {
          final switchToRecording = await showLiveRecordingConflictDialog(
            context,
            conflict: conflict,
            midStream: false,
          );
          if (!context.mounted) return null;
          if (switchToRecording == true && conflict.liveChannel != null) {
            return _launchLiveChannel(
              context: context,
              ref: ref,
              reg: conflict.sourceRegistration ?? conflictOwner.reg,
              channel: conflict.liveChannel!,
              useMobile: useMobile,
              checkConflictBeforeStart: false,
              allowQualityFallback: true,
            );
          }
          return null;
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
    if (!context.mounted) return null;
    if (checkConflictBeforeStart) {
      final conflict = await _resolveOtherChannelConflict(
        container,
        chosenReg,
        chosenChannel,
        knownSchedules: chosenSchedules,
      );
      if (!context.mounted) return null;
      if (conflict != null) {
        final switchToRecording = await showLiveRecordingConflictDialog(
          context,
          conflict: conflict,
          midStream: false,
        );
        if (!context.mounted) return null;
        if (switchToRecording == true && conflict.liveChannel != null) {
          return _launchLiveChannel(
            context: context,
            ref: ref,
            reg: conflict.sourceRegistration ?? chosenReg,
            channel: conflict.liveChannel!,
            useMobile: useMobile,
            checkConflictBeforeStart: false,
            allowQualityFallback: true,
          );
        }
        return null;
      }
    }
  }

  final engine = container.read(deviceServicesProvider(chosenReg)).playback;
  if (!engine.isSupported) {
    await showPlaybackUnsupportedDialog(context, subject: 'TV視聴');
    return null;
  }
  if (chosenChannel.res.isEmpty) {
    showSnack(context, '視聴可能なコンテンツがありません');
    return null;
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
    refreshIfStale: true,
  );
  final effectiveChannel = _resolveChannelFromSwitchContext(
    switchCtx,
    ownerReg: chosenReg,
    fallback: chosenChannel,
  );
  if (!context.mounted) return null;
  final exitCompleter = Completer<LiveWatchedChannelTarget?>();
  var enteredPlayer = false;
  var lastSeenReg = chosenReg;
  var lastSeenChannel = effectiveChannel;

  void handleSessionFinished(RegisteredNasne ownerReg, LiveChannel? lastCh) {
    lastSeenReg = ownerReg;
    if (lastCh != null) lastSeenChannel = lastCh;
    if (!exitCompleter.isCompleted) {
      exitCompleter.complete(
        LiveWatchedChannelTarget(
          reg: lastSeenReg,
          channel: lastSeenChannel,
          exitedAt: DateTime.now(),
        ),
      );
    }
  }

  var activeChannel = effectiveChannel;
  var retryAttempt = 0;

  await startPlaybackAndShowPlayer(
    context: context,
    ref: ref,
    start: () async {
      if (retryAttempt++ > 0) {
        try {
          final freshBands = await container
              .read(deviceServicesProvider(chosenReg))
              .live
              .listLiveChannels()
              .timeout(const Duration(seconds: 4));
          final targetKey = liveServiceKey(activeChannel);
          for (final band in freshBands) {
            for (final ch in band.channels) {
              if (ch.id == activeChannel.id ||
                  liveServiceKey(ch) == targetKey) {
                activeChannel = ch;
                break;
              }
            }
          }
        } catch (_) {
          // Keep previously resolved channel if refresh fails or times out.
        }
      }
      final activeEngine = container
          .read(deviceServicesProvider(chosenReg))
          .playback;
      return _startLiveSession(
        activeEngine,
        activeChannel,
        useMobile: useMobile,
        allowQualityFallback: allowQualityFallback || sameChannelRecording,
      );
    },
    buildPlayer: (session) {
      enteredPlayer = true;
      return _buildLivePlayerScreen(
        container: container,
        reg: chosenReg,
        channel: activeChannel,
        session: session,
        useMobile: useMobile,
        initialSchedules: chosenSchedules,
        multiNasneRegs: multiNasneRegs,
        liveSwitchChannels: switchCtx.entries,
        currentLiveSwitchIndex: switchCtx.currentIndex,
        onLiveSessionFinished: handleSessionFinished,
      );
    },
    unsupportedSubject: 'TV視聴',
    startFailureMessage: '視聴を開始できませんでした',
  );
  if (!enteredPlayer) return null;
  return exitCompleter.future.timeout(
    const Duration(seconds: 2),
    onTimeout: () => LiveWatchedChannelTarget(
      reg: lastSeenReg,
      channel: lastSeenChannel,
      exitedAt: DateTime.now(),
    ),
  );
}
