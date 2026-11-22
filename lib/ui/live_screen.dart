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

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:material_ui/material_ui.dart';

import '../app/providers.dart';
import '../app/state.dart';
import '../core/core.dart';
import 'epg_subchannel_visibility.dart';
import 'format.dart';
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
              onPressed: () => ref.invalidate(liveChannelsProvider(reg)),
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
              for (final channel in selectedBand.channels)
                ListTile(
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
                  onTap: () => onSelect(channel, twoPane),
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
  /// A viewing start is in flight (plan 35 guard, shared with
  /// recordings): while set, the button is disabled and _watch
  /// is re-entrancy-guarded.
  bool _starting = false;

  RegisteredNasne get reg => widget.reg;
  LiveChannel get channel => widget.channel;

  @override
  Widget build(BuildContext context) {
    final ch = channel;
    final mobileRes = ch.mobileRes;
    final start = ch.programStart;
    final end = ch.programEnd;
    return ListView(
      padding: const EdgeInsets.all(16),
      children: [
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
              Text(
                '画質: モバイル固定',
                style: Theme.of(context).textTheme.bodySmall,
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
    final engine = ref.read(deviceServicesProvider(reg)).playback;
    if (!engine.isSupported) {
      await showPlaybackUnsupportedDialog(context, subject: 'TV視聴');
      return;
    }
    if (channel.res.isEmpty) {
      showSnack(context, '視聴可能なコンテンツがありません');
      return;
    }
    final res = channel.mobileRes ?? channel.originalRes ?? channel.res.first;
    setState(() => _starting = true);
    try {
      await startPlaybackAndShowPlayer(
        context: context,
        ref: ref,
        start: () => engine.startLivePlayback(channel, res),
        buildPlayer: (session) => PlayerScreen(
          title: channel.channelName ?? channel.programTitle,
          session: session,
          live: true,
        ),
        unsupportedSubject: 'TV視聴',
        startFailureMessage: '視聴を開始できませんでした',
      );
    } finally {
      if (mounted) setState(() => _starting = false);
    }
  }
}
