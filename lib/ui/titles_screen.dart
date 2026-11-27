/// Recorded titles screen (plan 5.6 item 3): the title list with
/// remaining copy counts and protection state, and a detail view
/// with the additional information. Playback goes through the
/// PlaybackEngine boundary only; the v1 stub reports "unsupported"
/// and the UI turns that into the not-implemented notice
/// (plan 1.2 item 5, 5.7).
///
/// Plan 86: when the nasne holds a resume position for a title,
/// the detail view asks whether to continue from it or start at
/// the beginning, and the choice reaches the player as its open
/// start. Before this the position was display-only (plan 85
/// item 1).
///
/// Plan 86.6: list rows and the detail view show the title's
/// thumbnail when the unit provides one. Before this the
/// endpoint was defined but never called (plan 85 item 6).
/// Real-unit measurement (plan 97 / 99) showed the map
/// carries no image — it is a position index — and the
/// actual frames live behind recordedContentThumbnailGet,
/// AES-128-CBC encrypted with an app-common key and stored
/// as 360x240 UYVY; fetchThumbnail decodes them (plan 99).
///
/// Plan 86.5: the list can be searched by title, sorted, and
/// filtered by channel / genre / unwatched; the genre comes
/// from the DIDL merge (upnp:genre). Before this the list was
/// the raw fetch order only (plan 85 item 5).
///
/// Plan 86.3: titles can be deleted from the detail view (and
/// by long-pressing a list row), behind a confirmation.
/// Protected and currently-recording titles are refused with
/// the reason, before any confirmation. Before this the app
/// had no title deletion at all (plan 85 item 3).
///
/// Plan 98: the detail view's protection switch flips the
/// unit's titleProtectFlag (X_UpdateTitle, the shape verified
/// in plan 86.3). A delete the unit still refuses with error
/// 877 — the title was protected after the list in hand was
/// fetched — is explained as protection and resynced, not
/// reported as a generic failure.
///
/// Plan 100: the list loads progressively. The first chunk
/// (20 titles) is shown as soon as it arrives and the rest
/// follows page by page, instead of the screen waiting for
/// every page plus the DIDL Browse before showing anything.
/// While a stage is incomplete the screen says so beside the
/// filters, and an empty filtered result shows as still
/// loading, never as "no match" — search, filtering and
/// sorting are whole-set operations, and only the complete
/// stage settles them.
///
/// Plan 104 follow-up: a viewing's resume report (plan 102)
/// is reflected in the loaded list at once, the same
/// one-title patch as a protection update (plan 103). The
/// detail the viewer returns to shows the position just
/// recorded — or none, after a completed viewing cleared
/// it — instead of the snapshot from before the playback.
/// The unit already held the new point; only the display
/// lagged, which made the recording look unrecorded.
library;

import 'dart:typed_data';

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:material_ui/material_ui.dart';

import '../app/bs_epg_providers.dart';
import '../app/providers.dart';
import '../app/state.dart';
import '../core/core.dart';
import 'channel_badge.dart';
import 'dlna_browser_view.dart';
import 'epg_title_badges.dart';
import 'error_messages.dart';
import 'format.dart';
import 'multi_nasne_policy.dart';
import 'playback_launcher.dart';
import 'player_screen.dart';
import 'title_list_filter.dart';
import 'schedules_screen.dart' show twoPaneBreakpoint;
import 'widgets.dart';

/// The resume start a title offers (plan 86): the position the
/// nasne recorded, as a duration, or null when there is nothing
/// to resume from (never played, or playback reached the start).
Duration? resumeStartOf(RecordedTitle title) {
  final seconds = title.resumePointSeconds;
  if (seconds == null || seconds <= 0) return null;
  return Duration(seconds: seconds);
}

/// How far before the recorded position a resume actually
/// starts (plan 98; the mechanism corrected by plan 102).
///
/// Plan 98 assumed the unit derives the position from what
/// it served, read-ahead included, and the rewind corrected
/// for the overshoot. Plan 102 measured otherwise: serving
/// alone never moves the unit's point — the point is what
/// the last client to play the title reported from its own
/// playhead when its playback ended (the official client's
/// write, and now this app's, plan 102). The recorded
/// position is therefore a watched position, and the rewind
/// is kept as a context rewind: a resume replays a few
/// seconds so the viewer picks the thread back up, and any
/// small overshoot in how a client reports is absorbed.
/// The choice dialog still names the recorded position —
/// that is what was watched to; only the open start moves.
const Duration resumeRewind = Duration(seconds: 10);

/// The start a "continue" choice opens at (plan 98): the
/// recorded position rewound by [resumeRewind], clamped at
/// the beginning. Zero when the title offers no resume.
Duration resumePlaybackStartOf(RecordedTitle title) {
  final recorded = resumeStartOf(title);
  if (recorded == null) return Duration.zero;
  final start = recorded - resumeRewind;
  return start < Duration.zero ? Duration.zero : start;
}

/// Asks whether to continue from [resumeStart] or start over
/// (plan 86). Returns true for "continue", false for "from the
/// beginning", and null when the dialog was dismissed without a
/// choice (the caller then does not start playback).
Future<bool?> showResumeChoiceDialog(
  BuildContext context,
  Duration resumeStart,
) {
  return showDialog<bool>(
    context: context,
    builder: (context) => AlertDialog(
      title: const Text('前回の続きがあります'),
      content: Text(
        '前回は ${formatDurationSeconds(resumeStart.inSeconds)} まで観ました。'
        '続きから再生しますか？',
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.of(context).pop(false),
          child: const Text('最初から再生'),
        ),
        FilledButton(
          autofocus: true,
          onPressed: () => Navigator.of(context).pop(true),
          child: const Text('続きから再生'),
        ),
      ],
    ),
  );
}

/// The title deletion flow (plan 86.3), shared by the detail
/// view's delete button and the list's long-press. Protected
/// titles (the unit's guard against accidental deletion) and
/// titles still being recorded are refused with the reason and
/// never reach the confirmation. Anything else asks first —
/// deletion cannot be undone — then deletes, refreshes the
/// list and counts, and reports. [onDeleted] runs after a
/// successful deletion (the detail page uses it to go back to
/// the list; the two-pane layout needs nothing, its selection
/// simply stops resolving).
Future<void> deleteRecordedTitle({
  required BuildContext context,
  required WidgetRef ref,
  required RegisteredNasne reg,
  required RecordedTitle title,
  VoidCallback? onDeleted,
}) async {
  if (title.protectFlag) {
    await _showDeleteRefusal(context, 'このタイトルは保護されているため削除できません。');
    return;
  }
  if (title.recordingFlag) {
    await _showDeleteRefusal(context, '録画中のタイトルは削除できません。');
    return;
  }
  final confirmed = await confirmDialog(
    context,
    title: 'タイトルを削除',
    message: '「${title.title}」を削除しますか？\n削除した録画は元に戻せません。',
    confirmLabel: '削除',
  );
  if (!confirmed || !context.mounted) return;
  try {
    await ref.read(deviceServicesProvider(reg)).titles.deleteTitle(title.id);
  } on NasneError catch (e) {
    ref.read(diagLogProvider)(DiagCategory.ui, 'title delete failed: $e');
    if (!context.mounted) return;
    if (e.code == '877') {
      // The unit refused: the title is protected there even
      // though the list in hand said otherwise (plan 86.3 —
      // protection can be set from another client after the
      // list was fetched). Resync the list and explain it the
      // same way as the up-front refusal.
      ref.invalidate(titlesProvider(reg));
      await _showDeleteRefusal(context, 'このタイトルは保護されているため削除できません。');
      return;
    }
    showSnack(context, userMessageForError(e));
    return;
  } catch (e) {
    ref.read(diagLogProvider)(DiagCategory.ui, 'title delete failed: $e');
    if (context.mounted) showSnack(context, '削除できませんでした');
    return;
  }
  ref.invalidate(titlesProvider(reg));
  ref.invalidate(titleCountsProvider(reg));
  if (!context.mounted) return;
  showSnack(context, '削除しました');
  onDeleted?.call();
}

/// The protection toggle flow (plan 98), driven by the title
/// detail's switch: sends the X_UpdateTitle the unit expects
/// (the shape verified in plan 86.3), then rewrites the one
/// title's flag in the loaded list (plan 103). No refetch: the
/// whole list costs more the larger the library grows, and the
/// unit's title list may keep answering with the pre-update
/// flag for a while anyway (device-observed after plan 98), so
/// a refetch could not be trusted to settle the switch either.
/// The patched list state is what the row's lock icon and the
/// detail's switch both read, so both settle at once. A failure
/// changes nothing and surfaces the error. Returns whether the
/// unit accepted the update.
Future<bool> setRecordedTitleProtection({
  required BuildContext context,
  required WidgetRef ref,
  required RegisteredNasne reg,
  required RecordedTitle title,
  required bool protect,
}) async {
  try {
    await ref
        .read(deviceServicesProvider(reg))
        .titles
        .setTitleProtection(title, protect: protect);
  } on NasneError catch (e) {
    ref.read(diagLogProvider)(DiagCategory.ui, 'title protect failed: $e');
    if (context.mounted) showSnack(context, userMessageForError(e));
    return false;
  } catch (e) {
    ref.read(diagLogProvider)(DiagCategory.ui, 'title protect failed: $e');
    if (context.mounted) showSnack(context, '保護を変更できませんでした');
    return false;
  }
  ref.read(titlesProvider(reg).notifier).applyProtection(title.id, protect);
  if (!context.mounted) return true;
  showSnack(context, protect ? '保護しました' : '保護を解除しました');
  return true;
}

/// The resume report a closing player makes (plan 102), and
/// its reflection in the loaded list (plan 104 follow-up).
///
/// The unit is told where the viewing stopped; on success
/// the one title's resume point in the loaded list is
/// rewritten with the reported value — the same one-title
/// patch as a protection update (plan 103) — so the detail
/// the viewer returns to shows the position that was just
/// recorded, and a completed viewing's clear (a reported
/// zero) shows as no position. A failure throws before the
/// patch: the display keeps the old value, and the player's
/// teardown logs the failed report. No refetch either way.
Future<void> _reportResumePositionWithContainer({
  required ProviderContainer container,
  required RegisteredNasne reg,
  required String titleId,
  required Duration position,
}) async {
  await container
      .read(deviceServicesProvider(reg))
      .titles
      .setResumePosition(titleId, position);
  container
      .read(titlesProvider(reg).notifier)
      .applyResumePoint(titleId, position.inSeconds);
}

Future<void> reportResumePosition({
  required WidgetRef ref,
  required RegisteredNasne reg,
  required String titleId,
  required Duration position,
}) async {
  await ref
      .read(deviceServicesProvider(reg))
      .titles
      .setResumePosition(titleId, position);
  ref
      .read(titlesProvider(reg).notifier)
      .applyResumePoint(titleId, position.inSeconds);
}

String? _formatRecordedDetailMeta(RecordedTitle title) {
  final parts = <String>[
    if (title.scheduledStart != null)
      formatDateTimeWithWeekdayJst(title.scheduledStart!),
    if (title.scheduledDurationSeconds != null)
      formatDurationSeconds(title.scheduledDurationSeconds!),
    if (title.channelName != null && title.channelName!.isNotEmpty)
      title.channelName!,
    if (title.genre != null && title.genre!.isNotEmpty) title.genre!,
  ];
  return parts.isEmpty ? null : parts.join(' ・ ');
}

({RegisteredNasne reg, RecordedTitle title})? _resolveNextRecordedEpisode({
  required ProviderContainer container,
  required RegisteredNasne currentReg,
  required RecordedTitle currentTitle,
}) {
  try {
    final regs = container.read(registrationsProvider).value;
    final candidates = (regs != null && regs.isNotEmpty) ? regs : [currentReg];
    final allTitles = <RecordedTitle>[];
    final ownerByIdentity = Map<RecordedTitle, RegisteredNasne>.identity();
    for (final reg in candidates) {
      if (reg.host.isEmpty) continue;
      final stage = container.read(titlesProvider(reg)).value;
      if (stage == null || stage.titles.isEmpty) continue;
      for (final item in stage.titles) {
        if (item.res.isEmpty) continue;
        allTitles.add(item);
        ownerByIdentity[item] = reg;
      }
    }
    if (allTitles.length < 2) return null;
    final groups = groupRecordedTitles(
      allTitles,
      sort: TitleSortOrder.recordedOldest,
    );
    for (final group in groups) {
      if (!group.isFolder) continue;
      if (!group.titles.any((t) => t.id == currentTitle.id)) continue;
      final next = resolveNextEpisodeInSeries(
        current: currentTitle,
        groupTitles: group.titles,
      );
      if (next == null) return null;
      final owner = ownerByIdentity[next] ?? currentReg;
      return (reg: owner, title: next);
    }
  } catch (_) {}
  return null;
}

Iterable<int> _recordedChannelBandCandidates(int? broadcastingType) {
  if (broadcastingType == terrestrialBroadcastingType ||
      broadcastingType == bsBroadcastingType ||
      broadcastingType == csBroadcastingType) {
    return [broadcastingType!];
  }
  return const [
    terrestrialBroadcastingType,
    bsBroadcastingType,
    csBroadcastingType,
  ];
}

({String? number, Uint8List? logo}) _resolveCachedRecordedChannelMetadata(
  ProviderContainer container,
  RegisteredNasne reg,
  RecordedTitle title,
) {
  final serviceId = title.channel?.serviceId;
  final channelName = title.channelName;
  String? number;
  Uint8List? logo;
  for (final bandType in _recordedChannelBandCandidates(
    title.channel?.broadcastingType,
  )) {
    final channels = switch (bandType) {
      terrestrialBroadcastingType =>
        container.read(channelsProvider(reg)).value ?? const <Channel>[],
      bsBroadcastingType =>
        container.read(bsChannelsProvider(reg)).value ?? const <Channel>[],
      csBroadcastingType =>
        container.read(csChannelsProvider(reg)).value ?? const <Channel>[],
      _ => const <Channel>[],
    };
    final logos = switch (bandType) {
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
    number ??= resolveRecordedChannelNumberLabel(
      serviceId: serviceId,
      channelName: channelName,
      channels: channels,
    );
    logo ??= resolveRecordedChannelLogoBytes(
      serviceId: serviceId,
      channelName: channelName,
      channels: channels,
      logos: logos,
    );
    if (number != null && logo != null) break;
  }
  return (number: number, logo: logo);
}

Future<({String? number, Uint8List? logo})> _loadRecordedChannelMetadata(
  ProviderContainer container,
  RegisteredNasne reg,
  RecordedTitle title,
) async {
  final serviceId = title.channel?.serviceId;
  final channelName = title.channelName;
  String? number;
  Uint8List? logo;
  for (final bandType in _recordedChannelBandCandidates(
    title.channel?.broadcastingType,
  )) {
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
    List<Channel> channels = const [];
    Map<int, List<int>> logos = const {};
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
            logos = await container
                .read(logoProvider.future)
                .timeout(const Duration(seconds: 6));
          } catch (_) {}
        }(),
    ]);
    number ??= resolveRecordedChannelNumberLabel(
      serviceId: serviceId,
      channelName: channelName,
      channels: channels,
    );
    logo ??= resolveRecordedChannelLogoBytes(
      serviceId: serviceId,
      channelName: channelName,
      channels: channels,
      logos: logos,
    );
    if (number != null && logo != null) break;
  }
  return (number: number, logo: logo);
}

Widget _buildRecordedPlayerScreen({
  required ProviderContainer container,
  required RegisteredNasne reg,
  required PlaybackEngine engine,
  required RecordedTitle title,
  required PlaybackSession session,
  required bool useMobile,
  required Duration? initialStart,
  required String? detailMeta,
  required String? detailBody,
  String? initialCornerNotice,
}) {
  final canSwitchQuality =
      title.originalRes != null &&
      title.mobileRes != null &&
      title.originalRes != title.mobileRes;
  final knownDuration =
      (useMobile ? title.mobileRes?.duration : title.originalRes?.duration) ??
      (title.scheduledDurationSeconds != null
          ? Duration(seconds: title.scheduledDurationSeconds!)
          : null);
  final recordedBroadcastTimeRange = title.scheduledStart != null
      ? formatRecordedBroadcastTimeRangeJst(
          title.scheduledStart!,
          title.scheduledDurationSeconds,
        )
      : null;
  final nextTarget = _resolveNextRecordedEpisode(
    container: container,
    currentReg: reg,
    currentTitle: title,
  );
  final initialChannelMeta = _resolveCachedRecordedChannelMetadata(
    container,
    reg,
    title,
  );
  return PlayerScreen(
    title: title.title,
    session: session,
    initialStart: initialStart,
    knownDuration: knownDuration,
    recordedChannelName: title.channelName,
    initialRecordedChannelNumber: initialChannelMeta.number,
    initialRecordedChannelLogo: initialChannelMeta.logo,
    loadRecordedChannelMetadata: () =>
        _loadRecordedChannelMetadata(container, reg, title),
    recordedBroadcastTimeRange: recordedBroadcastTimeRange,
    recordedScheduledStart: title.scheduledStart,
    recordedBroadcastingType: title.channel?.broadcastingType,
    recordedServiceId: title.channel?.serviceId,
    programDetailTitle: title.title,
    programDetailMeta: detailMeta,
    programDetailBody: detailBody,
    canSwitchQuality: canSwitchQuality,
    currentUseMobile: useMobile,
    initialCornerNotice: initialCornerNotice,
    nextEpisodeTitle: nextTarget?.title.title,
    onPlayNextEpisode: nextTarget != null
        ? (playerContext, stopCurrentSession) async {
            try {
              await _reportResumePositionWithContainer(
                container: container,
                reg: reg,
                titleId: title.id,
                position: Duration.zero,
              );
            } catch (_) {}
            await stopCurrentSession();
            final nextTitle = nextTarget.title;
            final nextReg = nextTarget.reg;
            final nextRes = useMobile
                ? (nextTitle.mobileRes ??
                      nextTitle.originalRes ??
                      nextTitle.res.first)
                : (nextTitle.originalRes ??
                      nextTitle.mobileRes ??
                      nextTitle.res.first);
            final PlaybackSession nextSession;
            try {
              nextSession = await engine.startPlayback(nextTitle, nextRes);
            } on NasneError {
              return null;
            }
            if (!playerContext.mounted) {
              await nextSession.stop();
              return null;
            }
            return _buildRecordedPlayerScreen(
              container: container,
              reg: nextReg,
              engine: engine,
              title: nextTitle,
              session: nextSession,
              useMobile: useMobile,
              initialStart: null,
              detailMeta: _formatRecordedDetailMeta(nextTitle),
              detailBody: formatProgramDetailBody(
                description: nextTitle.description,
                longDescription: nextTitle.longDescription,
              ),
              initialCornerNotice: '次のエピソードを再生します',
            );
          }
        : null,
    onSwitchQuality: canSwitchQuality
        ? (
            playerContext,
            nextUseMobile,
            currentPosition,
            stopCurrentSession,
          ) async {
            await stopCurrentSession();
            final nextRes = nextUseMobile
                ? title.mobileRes!
                : title.originalRes!;
            final prevRes = useMobile
                ? (title.mobileRes ?? title.originalRes ?? title.res.first)
                : (title.originalRes ?? title.mobileRes ?? title.res.first);
            var actualUseMobile = nextUseMobile;
            String? notice;
            PlaybackSession nextSession;
            try {
              nextSession = await engine.startPlayback(title, nextRes);
              notice = nextUseMobile ? 'モバイル画質に切り替えました' : '元画質に切り替えました';
            } on NasneError {
              actualUseMobile = useMobile;
              nextSession = await engine.startPlayback(title, prevRes);
              notice = '画質を切り替えられませんでした（元の画質で継続）';
            }
            if (!playerContext.mounted) {
              await nextSession.stop();
              return null;
            }
            return _buildRecordedPlayerScreen(
              container: container,
              reg: reg,
              engine: engine,
              title: title,
              session: nextSession,
              useMobile: actualUseMobile,
              initialStart:
                  currentPosition > Duration.zero ? currentPosition : null,
              detailMeta: detailMeta,
              detailBody: detailBody,
              initialCornerNotice: notice,
            );
          }
        : null,
    // Leaving the player reports where the viewing stopped (plan 102), so
    // the unit's resume point follows even after in-player quality switching.
    onResumePosition: (position) => _reportResumePositionWithContainer(
      container: container,
      reg: reg,
      titleId: title.id,
      position: position,
    ),
    // The chapter points load as the player opens (plan 112); the service
    // validates them against the listed duration.
    loadChapters: () => container
        .read(deviceServicesProvider(reg))
        .titles
        .fetchChapters(
          title.id,
          durationSeconds: title.scheduledDurationSeconds ?? 0,
        ),
  );
}

Future<void> _showDeleteRefusal(BuildContext context, String message) {
  return showDialog<void>(
    context: context,
    builder: (context) => AlertDialog(
      title: const Text('削除できません'),
      content: Text(message),
      actions: [
        TextButton(
          autofocus: true,
          onPressed: () => Navigator.of(context).pop(),
          child: const Text('閉じる'),
        ),
      ],
    ),
  );
}

class TitlesScreen extends ConsumerStatefulWidget {
  const TitlesScreen({super.key});

  @override
  ConsumerState<TitlesScreen> createState() => _TitlesScreenState();
}

class _TitlesScreenState extends ConsumerState<TitlesScreen> {
  String? _selectedKey;
  String? _selectedSourceId;
  final FocusNode _detailPlayFocusNode = FocusNode(debugLabel: 'titlePlay');

  @override
  void dispose() {
    _detailPlayFocusNode.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final reg = ref.watch(selectedRegistrationProvider);
    final regs =
        ref.watch(registrationsProvider).value ?? const <RegisteredNasne>[];
    final activeRegs = regs.length > 1
        ? regs
        : (reg != null ? [reg] : const <RegisteredNasne>[]);
    final dlnaServers = ref.watch(dlnaServersProvider);
    final hasNasne = reg != null;

    RegisteredDlnaServer? activeDlna;
    if (dlnaServers.isNotEmpty) {
      if (_selectedSourceId != null && _selectedSourceId!.startsWith('dlna:')) {
        final targetId = _selectedSourceId!.substring(5);
        for (final s in dlnaServers) {
          if (s.id == targetId) {
            activeDlna = s;
            break;
          }
        }
      }
      if (!hasNasne && activeDlna == null) {
        activeDlna = dlnaServers.first;
      }
    }

    final Widget nasneBody = reg == null
        ? NoDeviceView(
            onRegister: () =>
                ref.read(tabIndexProvider.notifier).select(AppTabs.settings),
          )
        : _TitleList(
            reg: reg,
            activeRegs: activeRegs,
            selectedKey: _selectedKey,
            detailPlayFocusNode: _detailPlayFocusNode,
            onSelect: (title, owner, showNasneName, twoPane) {
              if (twoPane) {
                setState(() => _selectedKey = ownedItemKey(owner, title.id));
                WidgetsBinding.instance.addPostFrameCallback((_) {
                  if (mounted && _detailPlayFocusNode.canRequestFocus) {
                    _detailPlayFocusNode.requestFocus();
                  }
                });
              } else {
                Navigator.of(context).push(
                  MaterialPageRoute(
                    builder: (_) => TitleDetailPage(
                      reg: owner,
                      titleId: title.id,
                      showNasneName: showNasneName,
                    ),
                  ),
                );
              }
            },
          );

    final Widget body;
    if (dlnaServers.isEmpty) {
      body = nasneBody;
    } else {
      body = Column(
        children: [
          SingleChildScrollView(
            scrollDirection: Axis.horizontal,
            padding: const EdgeInsets.fromLTRB(16, 8, 16, 4),
            child: Row(
              children: [
                if (hasNasne) ...[
                  ChoiceChip(
                    label: const Text('nasne 録画'),
                    selected: activeDlna == null,
                    onSelected: (_) => setState(() => _selectedSourceId = 'nasne'),
                  ),
                  const SizedBox(width: 8),
                ],
                for (final s in dlnaServers) ...[
                  ChoiceChip(
                    avatar: const Icon(Icons.dns_outlined, size: 16),
                    label: Text(s.friendlyName),
                    selected: activeDlna?.id == s.id,
                    onSelected: (_) =>
                        setState(() => _selectedSourceId = 'dlna:${s.id}'),
                  ),
                  const SizedBox(width: 8),
                ],
              ],
            ),
          ),
          Expanded(
            child: activeDlna != null
                ? DlnaBrowserView(server: activeDlna)
                : nasneBody,
          ),
        ],
      );
    }

    return Scaffold(
      appBar: AppBar(
        title: const Text('録画済み'),
        actions: [
          if (reg != null && activeDlna == null)
            IconButton(
              icon: const Icon(Icons.refresh),
              tooltip: '更新',
              onPressed: () {
                for (final r in activeRegs) {
                  ref.invalidate(titlesProvider(r));
                  ref.invalidate(titleCountsProvider(r));
                }
              },
            ),
        ],
      ),
      body: body,
    );
  }
}

class _TitleList extends ConsumerStatefulWidget {
  const _TitleList({
    required this.reg,
    required this.activeRegs,
    required this.selectedKey,
    required this.detailPlayFocusNode,
    required this.onSelect,
  });

  final RegisteredNasne reg;
  final List<RegisteredNasne> activeRegs;
  final String? selectedKey;
  final FocusNode detailPlayFocusNode;
  final void Function(
    RecordedTitle title,
    RegisteredNasne owner,
    bool showNasneName,
    bool twoPane,
  )
  onSelect;

  @override
  ConsumerState<_TitleList> createState() => _TitleListState();
}

class _TitleListState extends ConsumerState<_TitleList> {
  final _searchController = TextEditingController();
  String _query = '';
  TitleSortOrder _sort = TitleSortOrder.recordedNewest;
  String? _channelKey;
  String? _genre;
  bool _unwatchedOnly = false;
  String? _nasneHostFilter;
  final Set<String> _expandedGroups = {};

  @override
  void dispose() {
    _searchController.dispose();
    super.dispose();
  }

  void _clearFilters() {
    setState(() {
      _searchController.clear();
      _query = '';
      _channelKey = null;
      _genre = null;
      _unwatchedOnly = false;
      _nasneHostFilter = null;
    });
  }

  @override
  Widget build(BuildContext context) {
    final reg = widget.reg;
    final activeRegs = widget.activeRegs;
    final isMultiNasne = activeRegs.length > 1;

    final List<RecordedTitle> allTitles;
    final ownerByTitle = Map<RecordedTitle, RegisteredNasne>.identity();
    final List<RecordedTitle> visibleScopeTitles;
    final String? countsLabel;
    final bool stillLoading;
    final bool hasAnySnapshot;
    final bool loadFailed;
    final Object? firstError;
    final List<String> failedLabels;

    if (!isMultiNasne) {
      final progress = ref.watch(titlesProvider(reg));
      final counts = ref.watch(titleCountsProvider(reg)).value;
      final snapshot = progress.value;
      allTitles = snapshot?.titles ?? const <RecordedTitle>[];
      for (final t in allTitles) {
        ownerByTitle[t] = reg;
      }
      visibleScopeTitles = allTitles;
      countsLabel = counts != null
          ? '全 ${counts.count} 件 (上限 ${counts.max} 件)'
          : null;
      stillLoading =
          snapshot == null || !snapshot.complete || progress.isLoading;
      hasAnySnapshot = snapshot != null;
      loadFailed =
          progress.hasError && (snapshot == null || !snapshot.complete);
      firstError = progress.error;
      failedLabels = const [];
    } else {
      final combinedAll = <RecordedTitle>[];
      final combinedVisible = <RecordedTitle>[];
      final effectiveHostFilter =
          _nasneHostFilter != null &&
              activeRegs.any((r) => r.host == _nasneHostFilter)
          ? _nasneHostFilter
          : null;
      var totalCount = 0;
      var totalMax = 0;
      var countLoaded = 0;
      var anySnapshot = false;
      var anyLoading = false;
      Object? err;
      final failed = <String>[];

      for (final r in activeRegs) {
        final c = ref.watch(titleCountsProvider(r)).value;
        if (c != null) {
          totalCount += c.count;
          totalMax += c.max;
          countLoaded++;
        }
        final progress = ref.watch(titlesProvider(r));
        final snapshot = progress.value;
        if (snapshot != null) {
          anySnapshot = true;
          for (final t in snapshot.titles) {
            ownerByTitle[t] = r;
            combinedAll.add(t);
            if (effectiveHostFilter == null || r.host == effectiveHostFilter) {
              combinedVisible.add(t);
            }
          }
          if (!snapshot.complete && !progress.hasError) {
            anyLoading = true;
          }
        } else if (progress.hasError) {
          failed.add(nasneDisplayLabel(r));
          err ??= progress.error;
        }
        if (progress.isLoading && !progress.hasError) {
          anyLoading = true;
        }
      }

      allTitles = combinedAll;
      visibleScopeTitles = combinedVisible;
      countsLabel = countLoaded > 0
          ? '全 $totalCount 件（${activeRegs.length}台合計・上限 $totalMax 件）'
          : null;
      stillLoading = anyLoading;
      hasAnySnapshot = anySnapshot;
      loadFailed = !anySnapshot && !anyLoading && err != null;
      firstError = err;
      failedLabels = failed;
    }

    final nasneHostFilter =
        isMultiNasne &&
            _nasneHostFilter != null &&
            activeRegs.any((r) => r.host == _nasneHostFilter)
        ? _nasneHostFilter
        : null;
    final channelChoices = titleChannelChoices(visibleScopeTitles);
    final genreChoices = titleGenreChoices(visibleScopeTitles);
    // A chosen value can vanish when the list refreshes (its
    // last title was deleted, say); fall back to "all" instead
    // of filtering everything out behind the user's back.
    final channelKey =
        _channelKey != null && channelChoices.contains(_channelKey)
        ? _channelKey
        : null;
    final genre = _genre != null && genreChoices.contains(_genre)
        ? _genre
        : null;
    final filter = TitleListFilter(
      query: _query,
      channelKey: channelKey,
      genre: genre,
      unwatchedOnly: _unwatchedOnly,
    );
    final hasAnyFilter = filter.isActive || nasneHostFilter != null;
    final filteredCount = hasAnyFilter
        ? applyTitleListView(visibleScopeTitles, filter: filter, sort: _sort)
              .length
        : null;
    return Column(
      children: [
        if (countsLabel != null)
          Padding(
            padding: const EdgeInsets.fromLTRB(16, 12, 16, 0),
            child: Align(
              alignment: Alignment.centerLeft,
              child: Text(countsLabel),
            ),
          ),
        if (failedLabels.isNotEmpty)
          Padding(
            padding: const EdgeInsets.fromLTRB(16, 6, 16, 0),
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
        Padding(
          padding: const EdgeInsets.fromLTRB(16, 8, 16, 0),
          child: FireTvTextInputField(
            controller: _searchController,
            prefixIcon: Icons.search,
            hintText: 'タイトルで検索',
            dialogTitle: 'タイトルで検索',
            showClearButton: true,
            onChanged: (value) => setState(() => _query = value),
          ),
        ),
        Padding(
          padding: const EdgeInsets.fromLTRB(16, 8, 16, 0),
          child: Align(
            alignment: Alignment.centerLeft,
            child: Wrap(
              spacing: 12,
              runSpacing: 4,
              crossAxisAlignment: WrapCrossAlignment.center,
              children: [
                if (isMultiNasne)
                  DropdownButton<String?>(
                    value: nasneHostFilter,
                    items: [
                      const DropdownMenuItem<String?>(
                        value: null,
                        child: Text('全 nasne'),
                      ),
                      for (final r in activeRegs)
                        DropdownMenuItem<String?>(
                          value: r.host,
                          child: Text(nasneDisplayLabel(r)),
                        ),
                    ],
                    onChanged: (value) =>
                        setState(() => _nasneHostFilter = value),
                  ),
                DropdownButton<TitleSortOrder>(
                  value: _sort,
                  items: [
                    for (final order in TitleSortOrder.values)
                      DropdownMenuItem(value: order, child: Text(order.label)),
                  ],
                  onChanged: (value) {
                    if (value != null) setState(() => _sort = value);
                  },
                ),
                DropdownButton<String?>(
                  value: channelKey,
                  items: [
                    const DropdownMenuItem(value: null, child: Text('全チャンネル')),
                    for (final choice in channelChoices)
                      DropdownMenuItem(value: choice, child: Text(choice)),
                  ],
                  onChanged: (value) => setState(() => _channelKey = value),
                ),
                DropdownButton<String?>(
                  value: genre,
                  items: [
                    const DropdownMenuItem(value: null, child: Text('全ジャンル')),
                    for (final choice in genreChoices)
                      DropdownMenuItem(value: choice, child: Text(choice)),
                  ],
                  onChanged: (value) => setState(() => _genre = value),
                ),
                FilterChip(
                  label: const Text('未視聴のみ'),
                  selected: _unwatchedOnly,
                  onSelected: (value) => setState(() => _unwatchedOnly = value),
                ),
                FilterChip(
                  label: const Text('番組まとめ'),
                  selected: ref.watch(groupTitlesProvider),
                  onSelected: (value) {
                    ref.read(groupTitlesProvider.notifier).set(value);
                  },
                ),
                if (hasAnyFilter) ...[
                  TextButton(
                    onPressed: _clearFilters,
                    child: const Text('条件をクリア'),
                  ),
                  if (filteredCount != null && !stillLoading)
                    Text('条件に合うのは $filteredCount 件'),
                ],
                // While the load is incomplete (plan 100), the
                // counts beside the filters are provisional and
                // say so; the filtered count is phrased as "so
                // far" so it cannot read as the final answer.
                if (stillLoading) ...[
                  const SizedBox(
                    width: 14,
                    height: 14,
                    child: CircularProgressIndicator(strokeWidth: 2),
                  ),
                  Text(
                    filteredCount != null
                        ? '読み込み中… 条件に合うのは現在 $filteredCount 件'
                        : '読み込み中… ${allTitles.length} 件を表示',
                  ),
                ],
              ],
            ),
          ),
        ),
        Expanded(
          child: loadFailed
              ? Padding(
                  padding: const EdgeInsets.all(12),
                  child: ErrorView(
                    message: userMessageForError(firstError!),
                    onRetry: () {
                      for (final r in activeRegs) {
                        ref.invalidate(titlesProvider(r));
                      }
                    },
                  ),
                )
              : !hasAnySnapshot
              ? const Padding(
                  padding: EdgeInsets.all(24),
                  child: Center(child: CircularProgressIndicator()),
                )
              : _titleListBody(
                  reg: reg,
                  isMultiNasne: isMultiNasne,
                  list: visibleScopeTitles,
                  ownerByTitle: ownerByTitle,
                  stillLoading: stillLoading,
                  filter: filter,
                  hasAnyFilter: hasAnyFilter,
                ),
        ),
      ],
    );
  }

  /// The list itself, over one stage of the progressive load
  /// (plan 100). [stillLoading] separates "nothing (yet)" from
  /// "nothing, finally": an empty list or an empty filtered
  /// result while later pages are still coming shows as
  /// loading, not as the settled answer.
  Widget _titleListBody({
    required RegisteredNasne reg,
    required bool isMultiNasne,
    required List<RecordedTitle> list,
    required Map<RecordedTitle, RegisteredNasne> ownerByTitle,
    required bool stillLoading,
    required TitleListFilter filter,
    required bool hasAnyFilter,
  }) {
    if (list.isEmpty) {
      if (stillLoading) {
        return const Center(child: Text('読み込み中…'));
      }
      if (hasAnyFilter) {
        return Center(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              const Text('条件に合うタイトルがありません'),
              const SizedBox(height: 8),
              TextButton(
                onPressed: _clearFilters,
                child: const Text('条件をクリア'),
              ),
            ],
          ),
        );
      }
      return const Center(child: Text('録画済みのタイトルはありません'));
    }
    final view = applyTitleListView(list, filter: filter, sort: _sort);
    if (view.isEmpty) {
      if (stillLoading) {
        return const Center(child: Text('読み込み中…'));
      }
      return Center(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            const Text('条件に合うタイトルがありません'),
            const SizedBox(height: 8),
            TextButton(onPressed: _clearFilters, child: const Text('条件をクリア')),
          ],
        ),
      );
    }
    final groupTitles = ref.watch(groupTitlesProvider);
    final List<_TitleListEntry> entries;
    if (groupTitles) {
      final groups = groupRecordedTitles(view, sort: _sort);
      entries = [
        for (final group in groups)
          if (group.isFolder) ...[
            _FolderTitleEntry(group),
            if (_expandedGroups.contains(group.key))
              for (final child in group.titles)
                _ItemTitleEntry(child, indented: true),
          ] else
            _ItemTitleEntry(group.titles.first),
      ];
    } else {
      entries = [for (final t in view) _ItemTitleEntry(t)];
    }

    return LayoutBuilder(
      builder: (context, constraints) {
        final twoPane = constraints.maxWidth >= twoPaneBreakpoint;
        final listView = ListView.builder(
          itemCount: entries.length,
          itemBuilder: (context, i) {
            final entry = entries[i];
            switch (entry) {
              case _FolderTitleEntry(:final group):
                final expanded = _expandedGroups.contains(group.key);
                return _TitleGroupTile(
                  key: ValueKey('group:${group.key}'),
                  group: group,
                  expanded: expanded,
                  onTap: () {
                    setState(() {
                      if (!_expandedGroups.add(group.key)) {
                        _expandedGroups.remove(group.key);
                      }
                    });
                  },
                );
              case _ItemTitleEntry(:final title, :final indented):
                final t = title;
                final owner = ownerByTitle[t] ?? reg;
                final itemKey = ownedItemKey(owner, t.id);
                final ownerSuffix =
                    isMultiNasne ? ' · ${nasneDisplayLabel(owner)}' : '';
                final tile = ListTile(
                  key: indented ? null : ValueKey('title:$itemKey'),
                  selected: itemKey == widget.selectedKey,
                  leading: _TitleLeading(reg: owner, title: t),
                  title: BroadcastTitleLine(
                    rawTitle: t.title,
                    maxLines: 2,
                    darkSurface: Theme.of(context).brightness == Brightness.dark,
                  ),
                  subtitle: Text(
                    '${t.scheduledStart != null ? formatDateTimeJst(t.scheduledStart!) : ''}'
                    '${t.scheduledDurationSeconds != null ? ' (${formatDurationSeconds(t.scheduledDurationSeconds!)})' : ''}'
                    '${t.channelName != null ? ' ${t.channelName}' : ''}'
                    '$ownerSuffix',
                  ),
                  trailing: Row(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      if (t.protectFlag) const Icon(Icons.lock, size: 16),
                      if (t.newFlag)
                        const Padding(
                          padding: EdgeInsets.only(left: 4),
                          child: Icon(Icons.fiber_new, size: 18),
                        ),
                      if (t.copyCountRemaining != null)
                        Padding(
                          padding: const EdgeInsets.only(left: 6),
                          child: Text('残り ${t.copyCountRemaining} 回'),
                        ),
                    ],
                  ),
                  onTap: () => widget.onSelect(t, owner, isMultiNasne, twoPane),
                  onLongPress: () => deleteRecordedTitle(
                    context: context,
                    ref: ref,
                    reg: owner,
                    title: t,
                  ),
                );
                if (!indented) return tile;
                return Padding(
                  key: ValueKey('title:$itemKey'),
                  padding: const EdgeInsets.only(left: 20),
                  child: DecoratedBox(
                    decoration: BoxDecoration(
                      border: Border(
                        left: BorderSide(
                          color: Theme.of(context).colorScheme.outlineVariant,
                          width: 2,
                        ),
                      ),
                    ),
                    child: tile,
                  ),
                );
            }
          },
        );
        if (!twoPane) return listView;
        RecordedTitle? selected;
        RegisteredNasne? selectedOwner;
        for (final t in view) {
          final owner = ownerByTitle[t] ?? reg;
          if (ownedItemKey(owner, t.id) == widget.selectedKey) {
            selected = t;
            selectedOwner = owner;
            break;
          }
        }
        return Row(
          children: [
            Expanded(flex: 5, child: listView),
            const VerticalDivider(thickness: 1, width: 1),
            Expanded(
              flex: 6,
              child: selected == null || selectedOwner == null
                  ? const Center(child: Text('タイトルを選択してください'))
                  : TitleDetailView(
                      reg: selectedOwner,
                      title: selected,
                      showNasneName: isMultiNasne,
                      playFocusNode: widget.detailPlayFocusNode,
                    ),
            ),
          ],
        );
      },
    );
  }
}

/// A title's leading visual (plan 86.6): the thumbnail when the
/// unit provides one, else the movie icon. A title still being
/// recorded keeps the red recording icon — its state matters
/// more than a picture, and its thumbnail may not exist yet.
class _TitleLeading extends ConsumerWidget {
  const _TitleLeading({required this.reg, required this.title});

  final RegisteredNasne reg;
  final RecordedTitle title;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final fallback = Icon(
      title.recordingFlag ? Icons.fiber_manual_record : Icons.movie_outlined,
      color: title.recordingFlag ? Theme.of(context).colorScheme.error : null,
    );
    if (title.recordingFlag) return fallback;
    final bytes = ref
        .watch(titleThumbnailProvider((reg: reg, titleId: title.id)))
        .value;
    if (bytes == null) return fallback;
    return ClipRRect(
      borderRadius: BorderRadius.circular(4),
      child: Image.memory(
        bytes,
        width: 64,
        height: 36,
        fit: BoxFit.cover,
        errorBuilder: (_, _, _) => fallback,
      ),
    );
  }
}

/// Compact 16:9 thumbnail (or fallback visual) for the 1/4-width left
/// column in the Fire TV detail header.
class _TitleCompactThumbnail extends ConsumerWidget {
  const _TitleCompactThumbnail({required this.reg, required this.title});

  final RegisteredNasne reg;
  final RecordedTitle title;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final theme = Theme.of(context);
    if (title.recordingFlag) {
      return AspectRatio(
        aspectRatio: 16 / 9,
        child: Container(
          decoration: BoxDecoration(
            color: theme.colorScheme.errorContainer,
            borderRadius: BorderRadius.circular(8),
          ),
          alignment: Alignment.center,
          child: Icon(
            Icons.fiber_manual_record,
            size: 36,
            color: theme.colorScheme.error,
          ),
        ),
      );
    }
    final bytes = ref
        .watch(titleThumbnailProvider((reg: reg, titleId: title.id)))
        .value;
    final placeholder = AspectRatio(
      aspectRatio: 16 / 9,
      child: Container(
        decoration: BoxDecoration(
          color: theme.colorScheme.surfaceContainerHighest,
          borderRadius: BorderRadius.circular(8),
        ),
        alignment: Alignment.center,
        child: Icon(
          Icons.movie_outlined,
          size: 36,
          color: theme.colorScheme.onSurfaceVariant,
        ),
      ),
    );
    if (bytes == null) return placeholder;
    return ClipRRect(
      borderRadius: BorderRadius.circular(8),
      child: AspectRatio(
        aspectRatio: 16 / 9,
        child: Image.memory(
          bytes,
          fit: BoxFit.cover,
          errorBuilder: (_, _, _) => placeholder,
        ),
      ),
    );
  }
}

/// The protection row of the title detail (plan 98): the
/// state in the same label/value shape as the other rows,
/// plus the switch that flips it on the unit. [onChanged] is
/// null while an update is in flight, which disables the
/// switch.
class _ProtectionRow extends StatefulWidget {
  const _ProtectionRow({required this.protect, required this.onChanged});

  final bool protect;
  final ValueChanged<bool>? onChanged;

  @override
  State<_ProtectionRow> createState() => _ProtectionRowState();
}

class _ProtectionRowState extends State<_ProtectionRow> {
  bool _focused = false;

  @override
  Widget build(BuildContext context) {
    final isDark = Theme.of(context).brightness == Brightness.dark;
    final focusBorderColor = isDark ? Colors.amberAccent : Colors.amber;
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 3),
      child: InkWell(
        borderRadius: BorderRadius.circular(8),
        onFocusChange: (focused) {
          if (_focused != focused) setState(() => _focused = focused);
        },
        onTap: widget.onChanged == null
            ? null
            : () => widget.onChanged!(!widget.protect),
        child: Container(
          padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 2),
          decoration: BoxDecoration(
            borderRadius: BorderRadius.circular(8),
            border: Border.all(
              color: _focused ? focusBorderColor : Colors.transparent,
              width: 2.5,
            ),
          ),
          child: Row(
            children: [
              SizedBox(
                width: 98,
                child: Text(
                  '保護',
                  style: Theme.of(context).textTheme.bodyMedium?.copyWith(
                    color: Theme.of(context).colorScheme.onSurfaceVariant,
                  ),
                ),
              ),
              Expanded(child: Text(widget.protect ? '保護あり' : 'なし')),
              ExcludeFocus(
                child: Switch(
                  value: widget.protect,
                  onChanged: widget.onChanged,
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

/// Detail page for narrow layouts.
class TitleDetailPage extends ConsumerWidget {
  const TitleDetailPage({
    super.key,
    required this.reg,
    required this.titleId,
    this.showNasneName = false,
  });

  final RegisteredNasne reg;
  final String titleId;
  final bool showNasneName;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final progress = ref.watch(titlesProvider(reg));
    final regs =
        ref.watch(registrationsProvider).value ?? const <RegisteredNasne>[];
    final effectiveShowNasneName = showNasneName || regs.length > 1;
    return Scaffold(
      appBar: AppBar(title: const Text('タイトルの詳細')),
      body: asyncSection(progress.whenData((stage) => stage.titles), (list) {
        for (final t in list) {
          if (t.id == titleId) {
            return TitleDetailView(
              reg: reg,
              title: t,
              showNasneName: effectiveShowNasneName,
              autofocusPlay: true,
              onDeleted: () => Navigator.of(context).pop(),
            );
          }
        }
        return const Center(child: Text('タイトルが見つかりません'));
      }, onRetry: () => ref.invalidate(titlesProvider(reg))),
    );
  }
}

/// The title detail optimized for Fire TV D-pad navigation:
/// 1/4-width thumbnail + 3/4-width title & key metadata on top,
/// action buttons immediately underneath, and long programme text
/// truncated so buttons never scroll off-screen. Defaults to the
/// saved playback quality setting and allows per-visit override.
class TitleDetailView extends ConsumerStatefulWidget {
  const TitleDetailView({
    super.key,
    required this.reg,
    required this.title,
    this.showNasneName = false,
    this.onDeleted,
    this.playFocusNode,
    this.autofocusPlay = false,
  });

  final RegisteredNasne reg;
  final RecordedTitle title;
  final bool showNasneName;

  /// Runs after this title was deleted from the detail view
  /// (plan 86.3): the pushed detail page goes back to the list.
  /// Null in the two-pane layout, where the refreshed list
  /// simply stops resolving the selection.
  final VoidCallback? onDeleted;
  final FocusNode? playFocusNode;
  final bool autofocusPlay;

  @override
  ConsumerState<TitleDetailView> createState() => _TitleDetailViewState();
}

class _TitleDetailViewState extends ConsumerState<TitleDetailView> {
  /// Optional per-visit quality override (`false` = original, `true` = mobile).
  /// Null until changed on this detail screen; falls back to the saved
  /// settings default without overwriting it.
  bool? _useMobileChoice;

  /// A playback start is in flight (plan 35). Starting takes a
  /// second or more (credentials -> HEAD -> AKE -> proxy); the
  /// build-13 field log showed a second tap in that window
  /// starting a whole second session, whose player screen then
  /// shared — and dropped — the first one's wakelock. While a
  /// start is in flight the button is disabled and _play is
  /// re-entrancy-guarded.
  bool _starting = false;

  /// A protection update is in flight (plan 98). The switch is
  /// disabled meanwhile: a second flip would be built from the
  /// same listed document as the first, and the two updates
  /// have no order between them worth having.
  bool _protectBusy = false;

  RegisteredNasne get reg => widget.reg;
  RecordedTitle get title => widget.title;

  @override
  void didUpdateWidget(covariant TitleDetailView oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.title.id != widget.title.id ||
        oldWidget.reg.host != widget.reg.host) {
      _useMobileChoice = null;
    }
  }

  Future<void> _toggleProtection(bool protect) async {
    if (_protectBusy) return;
    setState(() => _protectBusy = true);
    try {
      await setRecordedTitleProtection(
        context: context,
        ref: ref,
        reg: reg,
        title: title,
        protect: protect,
      );
    } finally {
      if (mounted) setState(() => _protectBusy = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final t = title;
    final protectValue = t.protectFlag;
    final channels = ref.watch(channelsProvider(reg)).value;
    final credentialSummary = ref.watch(credentialSummaryProvider);
    final credentialsMissing =
        credentialSummary.hasValue && credentialSummary.value == null;
    final mobileRes = t.mobileRes;
    final originalRes = t.originalRes;
    final bool useMobile =
        _useMobileChoice ?? ref.watch(playbackQualityProvider);
    final originalLabel = originalRes?.quality == null
        ? '元画質'
        : '元画質 (${resQualityLabel(originalRes!.quality)})';
    final channelText = t.channelName ?? channelDisplayName(channels, t.channel);
    final metaParts = <String>[
      if (widget.showNasneName) nasneDisplayLabel(reg),
      if (t.scheduledStart != null)
        formatDateTimeWithWeekdayJst(t.scheduledStart!),
      if (t.scheduledDurationSeconds != null)
        formatDurationSeconds(t.scheduledDurationSeconds!),
      channelText,
      if (t.recordingFlag) '録画中',
    ];
    return ListView(
      padding: const EdgeInsets.all(16),
      children: [
        Row(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Expanded(
              flex: 1,
              child: _TitleCompactThumbnail(reg: reg, title: t),
            ),
            const SizedBox(width: 16),
            Expanded(
              flex: 3,
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  BroadcastTitleHeading(
                    rawTitle: t.title,
                    style: Theme.of(context).textTheme.titleLarge,
                    maxLines: 3,
                    darkSurface: Theme.of(context).brightness == Brightness.dark,
                  ),
                  const SizedBox(height: 6),
                  Text(
                    metaParts.join(' ・ '),
                    style: Theme.of(context).textTheme.bodyMedium?.copyWith(
                      color: Theme.of(context).colorScheme.onSurfaceVariant,
                    ),
                    maxLines: 2,
                    overflow: TextOverflow.ellipsis,
                  ),
                  if (t.resumePointSeconds != null &&
                      t.resumePointSeconds! > 0) ...[
                    const SizedBox(height: 4),
                    FieldRow(
                      label: '再開位置',
                      value: formatDurationSeconds(t.resumePointSeconds!),
                    ),
                  ],
                  if (t.recordingFlag)
                    FieldRow(
                      label: '保護',
                      value: t.protectFlag ? '保護あり' : 'なし',
                    )
                  else
                    _ProtectionRow(
                      protect: protectValue,
                      onChanged: _protectBusy ? null : _toggleProtection,
                    ),
                ],
              ),
            ),
          ],
        ),
        const SizedBox(height: 16),
        Wrap(
          spacing: 12,
          runSpacing: 8,
          crossAxisAlignment: WrapCrossAlignment.center,
          children: [
            FilledButton.icon(
              focusNode: widget.playFocusNode,
              autofocus: widget.autofocusPlay,
              onPressed: _starting ? null : () => _play(context, ref),
              icon: const Icon(Icons.play_arrow),
              label: const Text('再生'),
            ),
            OutlinedButton.icon(
              onPressed: () => deleteRecordedTitle(
                context: context,
                ref: ref,
                reg: reg,
                title: title,
                onDeleted: widget.onDeleted,
              ),
              icon: Icon(
                Icons.delete_outline,
                color: Theme.of(context).colorScheme.error,
              ),
              label: Text(
                'このタイトルを削除',
                style: TextStyle(color: Theme.of(context).colorScheme.error),
              ),
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
        if (credentialsMissing) ...[
          const SizedBox(height: 8),
          const Text('録画の再生には資格情報のインポートが必要です。'),
        ],
        if (t.description != null && t.description!.isNotEmpty) ...[
          const SizedBox(height: 12),
          Text(
            t.description!,
            maxLines: 2,
            overflow: TextOverflow.ellipsis,
            style: Theme.of(context).textTheme.bodySmall,
          ),
        ],
      ],
    );
  }

  Future<void> _play(BuildContext context, WidgetRef ref) async {
    if (_starting) return;
    final engine = ref.read(deviceServicesProvider(reg)).playback;
    if (!engine.isSupported) {
      await showPlaybackUnsupportedDialog(context, subject: '録画の再生');
      return;
    }
    if (title.res.isEmpty) {
      showSnack(context, '再生可能なコンテンツがありません');
      return;
    }
    final bool useMobile =
        _useMobileChoice ?? ref.read(playbackQualityProvider);
    final res = useMobile
        ? (title.mobileRes ?? title.originalRes ?? title.res.first)
        : (title.originalRes ?? title.mobileRes ?? title.res.first);
    setState(() => _starting = true);
    try {
      // Resume (plan 86): a title the viewer stopped midway offers
      // its recorded position. Ask before starting — beginning a
      // session is the expensive step, and the choice belongs
      // before it, not after.
      var initialStart = resumeStartOf(title);
      if (initialStart != null) {
        final resume = await showResumeChoiceDialog(context, initialStart);
        if (!context.mounted) return;
        if (resume == null) return;
        // Continuing opens a little before the recorded position:
        // the context rewind of resumeRewind (plan 98 / 102).
        initialStart = resume ? resumePlaybackStartOf(title) : null;
      }
      final detailMeta = _formatRecordedDetailMeta(title);
      final detailBody = formatProgramDetailBody(
        description: title.description,
        longDescription: title.longDescription,
      );
      final container = ProviderScope.containerOf(context, listen: false);
      await startPlaybackAndShowPlayer(
        context: context,
        ref: ref,
        start: () => engine.startPlayback(title, res),
        buildPlayer: (session) => _buildRecordedPlayerScreen(
          container: container,
          reg: reg,
          engine: engine,
          title: title,
          session: session,
          useMobile: useMobile,
          initialStart: initialStart,
          detailMeta: detailMeta,
          detailBody: detailBody,
        ),
        unsupportedSubject: '録画の再生',
      );
    } finally {
      if (mounted) setState(() => _starting = false);
    }
  }
}

sealed class _TitleListEntry {
  const _TitleListEntry();
}

final class _FolderTitleEntry extends _TitleListEntry {
  const _FolderTitleEntry(this.group);
  final TitleGroup group;
}

final class _ItemTitleEntry extends _TitleListEntry {
  const _ItemTitleEntry(this.title, {this.indented = false});
  final RecordedTitle title;
  final bool indented;
}

class _TitleGroupTile extends StatelessWidget {
  const _TitleGroupTile({
    super.key,
    required this.group,
    required this.expanded,
    required this.onTap,
  });

  final TitleGroup group;
  final bool expanded;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final colorScheme = Theme.of(context).colorScheme;
    final earliest = group.earliestStart;
    final latest = group.latestStart;
    final String? dateRange;
    if (earliest != null && latest != null) {
      final earliestText = formatDateJst(earliest);
      final latestText = formatDateJst(latest);
      dateRange = earliestText == latestText
          ? earliestText
          : '$earliestText 〜 $latestText';
    } else {
      dateRange = null;
    }

    return ListTile(
      leading: SizedBox(
        width: 48,
        height: 36,
        child: Center(
          child: Icon(
            expanded ? Icons.folder_open : Icons.folder,
            color: colorScheme.primary,
          ),
        ),
      ),
      title: Text(group.label, maxLines: 2, overflow: TextOverflow.ellipsis),
      subtitle: dateRange != null ? Text(dateRange) : null,
      trailing: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          if (group.allProtected)
            const Padding(
              padding: EdgeInsets.only(right: 4),
              child: Icon(Icons.lock, size: 16),
            ),
          if (group.hasUnwatched)
            const Padding(
              padding: EdgeInsets.only(right: 6),
              child: Icon(Icons.fiber_new, size: 18),
            ),
          Text('全 ${group.titles.length} 本'),
          const SizedBox(width: 4),
          Icon(expanded ? Icons.expand_less : Icons.expand_more),
        ],
      ),
      onTap: onTap,
    );
  }
}
