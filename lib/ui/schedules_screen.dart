/// Schedules screen (plan 5.6 item 2): the reservation list in
/// chronological order, with create / edit / delete and conflict
/// warnings (via the form). On wide layouts the detail opens in a
/// second pane; on narrow layouts it is a pushed page (plan 12.7).
library;

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:material_ui/material_ui.dart';

import '../app/bs_epg_providers.dart';
import '../app/providers.dart';
import '../app/state.dart';
import '../core/core.dart';
import 'error_messages.dart';
import 'format.dart';
import 'multi_nasne_policy.dart';
import 'schedule_form.dart';
import 'widgets.dart';

/// Width at or above which list and detail sit side by side.
const double twoPaneBreakpoint = 1000;

enum _SchedulesViewMode { schedules, failures }

class SchedulesScreen extends ConsumerStatefulWidget {
  const SchedulesScreen({super.key});

  @override
  ConsumerState<SchedulesScreen> createState() => _SchedulesScreenState();
}

class _SchedulesScreenState extends ConsumerState<SchedulesScreen> {
  _SchedulesViewMode _mode = _SchedulesViewMode.schedules;
  String? _selectedKey;
  String? _selectedFailureKey;

  Future<void> _confirmDismissOneFailure(
    BuildContext context,
    OwnedRecNgItem owned, {
    VoidCallback? onDismissed,
  }) async {
    final title = owned.item.title ?? '(タイトルなし)';
    final ok = await confirmDialog(
      context,
      title: '録画失敗履歴を削除',
      message:
          '「$title」をこのアプリの録画失敗一覧から削除しますか？\n'
          '（nasne 本体の履歴は仕様上消去されないため、再インストール時には再表示されます）',
    );
    if (!ok) return;
    await ref.read(dismissedRecNgKeysProvider.notifier).dismiss(owned.dismissKey);
    onDismissed?.call();
    if (context.mounted) {
      showSnack(context, '録画失敗履歴を削除しました');
    }
  }

  Future<void> _confirmDismissAllFailures(
    BuildContext context,
    List<OwnedRecNgItem> items,
  ) async {
    if (items.isEmpty) return;
    final ok = await confirmDialog(
      context,
      title: '録画失敗履歴をすべて削除',
      message:
          '表示中の録画失敗履歴 ${items.length} 件をすべてこのアプリから削除しますか？\n'
          '（nasne 本体の履歴は仕様上消去されないため、再インストール時には再表示されます）',
      confirmLabel: 'すべて削除',
    );
    if (!ok) return;
    await ref
        .read(dismissedRecNgKeysProvider.notifier)
        .dismissAll([for (final o in items) o.dismissKey]);
    if (mounted) {
      setState(() => _selectedFailureKey = null);
    }
    if (context.mounted) {
      showSnack(context, '録画失敗履歴をすべて削除しました');
    }
  }

  @override
  Widget build(BuildContext context) {
    final reg = ref.watch(selectedRegistrationProvider);
    final regs =
        ref.watch(registrationsProvider).value ?? const <RegisteredNasne>[];
    final activeRegs = regs.length > 1
        ? regs
        : (reg != null ? [reg] : const <RegisteredNasne>[]);
    final dismissedFailureKeys = ref.watch(dismissedRecNgKeysProvider);
    final recNgSources = <({RegisteredNasne reg, List<RecNgItem> items})>[];
    final recNgFailedLabels = <String>[];
    var recNgLoading = false;
    Object? recNgFirstError;
    for (final r in activeRegs) {
      final async = ref.watch(recNgProvider(r));
      final value = async.value;
      if (value != null) {
        recNgSources.add((reg: r, items: value));
      } else if (async.hasError) {
        recNgFailedLabels.add(nasneDisplayLabel(r));
        recNgFirstError ??= async.error;
      } else if (async.isLoading) {
        recNgLoading = true;
      }
    }
    final visibleFailures = mergeAndFilterRecNgItems(
      sources: recNgSources,
      dismissedKeys: dismissedFailureKeys,
    );
    return Scaffold(
      appBar: AppBar(
        title: const Text('予約'),
        actions: [
          if (reg != null) ...[
            if (_mode == _SchedulesViewMode.schedules)
              Padding(
                padding: const EdgeInsets.only(right: 4),
                child: FilledButton.tonalIcon(
                  style: FilledButton.styleFrom(
                    padding: const EdgeInsets.symmetric(horizontal: 10),
                    visualDensity: VisualDensity.compact,
                  ),
                  onPressed: () => Navigator.of(context).push(
                    MaterialPageRoute(
                      builder: (_) => ScheduleFormPage.create(reg),
                    ),
                  ),
                  icon: const Icon(Icons.add, size: 18),
                  label: const Text('新規予約'),
                ),
              )
            else if (visibleFailures.isNotEmpty)
              Padding(
                padding: const EdgeInsets.only(right: 4),
                child: OutlinedButton.icon(
                  style: OutlinedButton.styleFrom(
                    padding: const EdgeInsets.symmetric(horizontal: 10),
                    visualDensity: VisualDensity.compact,
                  ),
                  onPressed: () =>
                      _confirmDismissAllFailures(context, visibleFailures),
                  icon: const Icon(Icons.delete_sweep_outlined, size: 18),
                  label: const Text('すべて削除'),
                ),
              ),
            IconButton(
              icon: const Icon(Icons.refresh),
              tooltip: '更新',
              onPressed: () {
                for (final r in activeRegs) {
                  ref.invalidate(schedulesProvider(r));
                  ref.invalidate(recNgProvider(r));
                }
              },
            ),
          ],
        ],
      ),
      body: reg == null
          ? NoDeviceView(
              onRegister: () =>
                  ref.read(tabIndexProvider.notifier).select(AppTabs.settings),
            )
          : Column(
              children: [
                Padding(
                  padding: const EdgeInsets.fromLTRB(16, 10, 16, 6),
                  child: Align(
                    alignment: Alignment.centerLeft,
                    child: SegmentedButton<_SchedulesViewMode>(
                      segments: [
                        const ButtonSegment(
                          value: _SchedulesViewMode.schedules,
                          icon: Icon(Icons.event_note_outlined, size: 18),
                          label: Text('予約一覧'),
                        ),
                        ButtonSegment(
                          value: _SchedulesViewMode.failures,
                          icon: const Icon(
                            Icons.videocam_off_outlined,
                            size: 18,
                          ),
                          label: Text(
                            visibleFailures.isEmpty
                                ? '録画失敗'
                                : '録画失敗 (${visibleFailures.length})',
                          ),
                        ),
                      ],
                      selected: {_mode},
                      onSelectionChanged: (selection) =>
                          setState(() => _mode = selection.first),
                    ),
                  ),
                ),
                const Divider(height: 1),
                Expanded(
                  child: _mode == _SchedulesViewMode.schedules
                      ? _ScheduleList(
                          reg: reg,
                          activeRegs: activeRegs,
                          selectedKey: _selectedKey,
                          onSelect: (owned, showNasneName, twoPane) {
                            if (twoPane) {
                              setState(() => _selectedKey = owned.compositeKey);
                            } else {
                              Navigator.of(context).push(
                                MaterialPageRoute(
                                  builder: (_) => ScheduleDetailPage(
                                    reg: owned.reg,
                                    scheduleId: owned.schedule.id,
                                    showNasneName: showNasneName,
                                    autofocusEdit: true,
                                  ),
                                ),
                              );
                            }
                          },
                        )
                      : _RecNgList(
                          activeRegs: activeRegs,
                          sources: recNgSources,
                          items: visibleFailures,
                          failedLabels: recNgFailedLabels,
                          isLoading: recNgLoading,
                          firstError: recNgFirstError,
                          selectedKey: _selectedFailureKey,
                          onSelect: (owned, showNasneName, twoPane) {
                            if (twoPane) {
                              setState(
                                () => _selectedFailureKey = owned.dismissKey,
                              );
                            } else {
                              Navigator.of(context).push(
                                MaterialPageRoute(
                                  builder: (_) => _RecNgDetailPage(
                                    owned: owned,
                                    showNasneName: showNasneName,
                                  ),
                                ),
                              );
                            }
                          },
                          onDismissOne: (owned, {onDismissed}) =>
                              _confirmDismissOneFailure(
                                context,
                                owned,
                                onDismissed: () {
                                  if (_selectedFailureKey == owned.dismissKey) {
                                    setState(() => _selectedFailureKey = null);
                                  }
                                  onDismissed?.call();
                                },
                              ),
                          onRetry: () {
                            for (final r in activeRegs) {
                              ref.invalidate(recNgProvider(r));
                            }
                          },
                        ),
                ),
              ],
            ),
    );
  }
}

class _ScheduleList extends ConsumerWidget {
  const _ScheduleList({
    required this.reg,
    required this.activeRegs,
    required this.selectedKey,
    required this.onSelect,
  });

  final RegisteredNasne reg;
  final List<RegisteredNasne> activeRegs;
  final String? selectedKey;
  final void Function(
    OwnedRecordSchedule owned,
    bool showNasneName,
    bool twoPane,
  )
  onSelect;

  List<Channel> _channelsFor(WidgetRef ref, RegisteredNasne owner) {
    final terrestrial =
        ref.watch(channelsProvider(owner)).value ?? const <Channel>[];
    final schedules = ref.watch(schedulesProvider(owner)).value;
    final needsBs =
        schedules?.any(
          (s) => s.channel.broadcastingType == bsBroadcastingType,
        ) ??
        false;
    final needsCs =
        schedules?.any(
          (s) => s.channel.broadcastingType == csBroadcastingType,
        ) ??
        false;
    final bs = needsBs
        ? (ref.watch(bsChannelsProvider(owner)).value ?? const <Channel>[])
        : const <Channel>[];
    final cs = needsCs
        ? (ref.watch(csChannelsProvider(owner)).value ?? const <Channel>[])
        : const <Channel>[];
    return [...terrestrial, ...bs, ...cs];
  }

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    if (activeRegs.length <= 1) {
      final schedules = ref.watch(schedulesProvider(reg));
      final channels = _channelsFor(ref, reg);
      return asyncSection(schedules, (list) {
        if (list.isEmpty) {
          return const Center(child: Text('予約はありません'));
        }
        return LayoutBuilder(
          builder: (context, constraints) {
            final twoPane = constraints.maxWidth >= twoPaneBreakpoint;
            final listView = ListView.builder(
              itemCount: list.length,
              itemBuilder: (context, i) {
                final s = list[i];
                final owned = OwnedRecordSchedule(reg: reg, schedule: s);
                return ListTile(
                  selected: owned.compositeKey == selectedKey,
                  leading: const Icon(Icons.event_note_outlined),
                  title: Text(
                    '${formatDateTimeWithWeekdayJst(s.start)} '
                    '${channelDisplayName(channels, s.channel)}',
                  ),
                  subtitle: Text(
                    '${formatTimeJst(s.start)}〜${formatTimeJst(s.end)}'
                    ' (${formatDurationSeconds(s.durationSeconds)})'
                    ' 画質 ${qualityModeLabel(s.desiredQualityMode)}'
                    '${s.title != null ? ' ${s.title}' : ''}',
                  ),
                  trailing: s.priorityFlag != 0
                      ? const Icon(Icons.priority_high, size: 18)
                      : null,
                  onTap: () => onSelect(owned, false, twoPane),
                );
              },
            );
            if (!twoPane) return listView;
            RecordSchedule? selected;
            for (final s in list) {
              if (ownedItemKey(reg, s.id) == selectedKey) selected = s;
            }
            return Row(
              children: [
                Expanded(flex: 5, child: listView),
                const VerticalDivider(thickness: 1, width: 1),
                Expanded(
                  flex: 6,
                  child: selected == null
                      ? const Center(child: Text('予約を選択してください'))
                      : ScheduleDetailView(reg: reg, schedule: selected),
                ),
              ],
            );
          },
        );
      }, onRetry: () => ref.invalidate(schedulesProvider(reg)));
    }

    // Multi-nasne merged reservation list.
    final loadedSources =
        <({RegisteredNasne reg, List<RecordSchedule> schedules})>[];
    final failedLabels = <String>[];
    final channelsByHost = <String, List<Channel>>{};
    var anyLoading = false;
    Object? firstError;

    for (final r in activeRegs) {
      channelsByHost[r.host] = _channelsFor(ref, r);
      final async = ref.watch(schedulesProvider(r));
      final value = async.value;
      if (value != null) {
        loadedSources.add((reg: r, schedules: value));
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
            : '予約一覧を取得できませんでした',
        onRetry: () {
          for (final r in activeRegs) {
            ref.invalidate(schedulesProvider(r));
          }
        },
      );
    }

    final merged = mergeOwnedSchedules(loadedSources);
    if (merged.isEmpty) {
      return Column(
        children: [
          if (failedLabels.isNotEmpty)
            Padding(
              padding: const EdgeInsets.fromLTRB(12, 8, 12, 0),
              child: Text(
                '一部の nasne に接続できませんでした（${failedLabels.join('、')}）',
                style: Theme.of(context).textTheme.bodySmall?.copyWith(
                  color: Theme.of(context).colorScheme.error,
                ),
              ),
            ),
          const Expanded(child: Center(child: Text('予約はありません'))),
        ],
      );
    }

    return LayoutBuilder(
      builder: (context, constraints) {
        final twoPane = constraints.maxWidth >= twoPaneBreakpoint;
        final listView = Column(
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
            Expanded(
              child: ListView.builder(
                itemCount: merged.length,
                itemBuilder: (context, i) {
                  final owned = merged[i];
                  final s = owned.schedule;
                  final channels = channelsByHost[owned.reg.host];
                  final ownerLabel = nasneDisplayLabel(owned.reg);
                  return ListTile(
                    key: ValueKey('schedule:${owned.compositeKey}'),
                    selected: owned.compositeKey == selectedKey,
                    leading: const Icon(Icons.event_note_outlined),
                    title: Text(
                      '${formatDateTimeWithWeekdayJst(s.start)} '
                      '${channelDisplayName(channels, s.channel)}',
                    ),
                    subtitle: Text(
                      '[$ownerLabel] ${formatTimeJst(s.start)}〜${formatTimeJst(s.end)}'
                      ' (${formatDurationSeconds(s.durationSeconds)})'
                      ' 画質 ${qualityModeLabel(s.desiredQualityMode)}'
                      '${s.title != null ? ' ${s.title}' : ''}',
                    ),
                    trailing: s.priorityFlag != 0
                        ? const Icon(Icons.priority_high, size: 18)
                        : null,
                    onTap: () => onSelect(owned, true, twoPane),
                  );
                },
              ),
            ),
          ],
        );
        if (!twoPane) return listView;
        OwnedRecordSchedule? selected;
        for (final owned in merged) {
          if (owned.compositeKey == selectedKey) selected = owned;
        }
        return Row(
          children: [
            Expanded(flex: 5, child: listView),
            const VerticalDivider(thickness: 1, width: 1),
            Expanded(
              flex: 6,
              child: selected == null
                  ? const Center(child: Text('予約を選択してください'))
                  : ScheduleDetailView(
                      reg: selected.reg,
                      schedule: selected.schedule,
                      showNasneName: true,
                    ),
            ),
          ],
        );
      },
    );
  }
}

/// Detail page for narrow layouts; resolves the reservation from the
/// list provider so edits are reflected when the form returns.
class ScheduleDetailPage extends ConsumerWidget {
  const ScheduleDetailPage({
    super.key,
    required this.reg,
    required this.scheduleId,
    this.showNasneName = false,
    this.autofocusEdit = false,
  });

  final RegisteredNasne reg;
  final String scheduleId;
  final bool showNasneName;
  final bool autofocusEdit;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final schedules = ref.watch(schedulesProvider(reg));
    final regs =
        ref.watch(registrationsProvider).value ?? const <RegisteredNasne>[];
    final effectiveShowNasneName = showNasneName || regs.length > 1;
    return Scaffold(
      appBar: AppBar(title: const Text('予約の詳細')),
      body: asyncSection(schedules, (list) {
        for (final s in list) {
          if (s.id == scheduleId) {
            return ScheduleDetailView(
              reg: reg,
              schedule: s,
              showNasneName: effectiveShowNasneName,
              autofocusEdit: autofocusEdit,
            );
          }
        }
        return const Center(child: Text('予約が見つかりません'));
      }, onRetry: () => ref.invalidate(schedulesProvider(reg))),
    );
  }
}

/// The reservation detail: fields plus edit / time-change / delete
/// actions implementing the plan 12.5 operation semantics.
class ScheduleDetailView extends ConsumerWidget {
  const ScheduleDetailView({
    super.key,
    required this.reg,
    required this.schedule,
    this.showNasneName = false,
    this.autofocusEdit = false,
    this.onDeleted,
  });

  final RegisteredNasne reg;
  final RecordSchedule schedule;
  final bool showNasneName;
  final bool autofocusEdit;

  /// Called after a successful delete (wide layouts clear the pane).
  final VoidCallback? onDeleted;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final s = schedule;
    final channels = switch (s.channel.broadcastingType) {
      bsBroadcastingType => ref.watch(bsChannelsProvider(reg)).value,
      csBroadcastingType => ref.watch(csChannelsProvider(reg)).value,
      _ => ref.watch(channelsProvider(reg)).value,
    };
    return ListView(
      padding: const EdgeInsets.all(16),
      children: [
        if (s.title != null)
          Padding(
            padding: const EdgeInsets.only(bottom: 8),
            child: Text(
              s.title!,
              style: Theme.of(context).textTheme.titleMedium,
            ),
          ),
        if (showNasneName)
          FieldRow(label: '録画機器', value: nasneDisplayLabel(reg)),
        FieldRow(
          label: 'チャンネル',
          value: channelDisplayName(channels, s.channel),
        ),
        FieldRow(label: '開始', value: formatDateTimeWithWeekdayJst(s.start)),
        FieldRow(label: '終了', value: formatDateTimeWithWeekdayJst(s.end)),
        FieldRow(label: '長さ', value: formatDurationSeconds(s.durationSeconds)),
        FieldRow(label: '画質モード', value: qualityModeLabel(s.desiredQualityMode)),
        FieldRow(label: '優先フラグ', value: '${s.priorityFlag}'),
        FieldRow(label: '条件 ID', value: s.conditionId),
        // recordDestinationId is deliberately not shown (plan 28):
        // on a reservation it is the creator's desired/template
        // value, not the physical destination — torne's 3倍
        // template carries 'USBHDD' while the recording lands on
        // the internal HDD (the resulting title reports 'HDD').
        // Presenting it as 録画先 would state something the device
        // itself contradicts. It stays editable in the edit form,
        // which is a raw-field editor.
        const SizedBox(height: 24),
        Wrap(
          spacing: 8,
          runSpacing: 8,
          children: [
            FilledButton.icon(
              autofocus: autofocusEdit,
              onPressed: () => Navigator.of(context).push(
                MaterialPageRoute(
                  builder: (_) => ScheduleFormPage.edit(reg, s),
                ),
              ),
              icon: const Icon(Icons.edit_outlined),
              label: const Text('編集'),
            ),
            OutlinedButton.icon(
              onPressed: () => Navigator.of(context).push(
                MaterialPageRoute(
                  builder: (_) => ScheduleFormPage.timeChange(reg, s),
                ),
              ),
              icon: const Icon(Icons.schedule),
              label: const Text('時刻を変更'),
            ),
            OutlinedButton.icon(
              onPressed: () => _delete(context, ref),
              icon: const Icon(Icons.delete_outline),
              label: const Text('削除'),
            ),
          ],
        ),
      ],
    );
  }

  Future<void> _delete(BuildContext context, WidgetRef ref) async {
    final s = schedule;
    final ok = await confirmDialog(
      context,
      title: '予約を削除',
      message: '${formatDateTimeWithWeekdayJst(s.start)} の予約を削除しますか？',
    );
    if (!ok) return;
    try {
      await ref
          .read(deviceServicesProvider(reg))
          .schedules
          .deleteSchedule(s.id);
    } on NasneError catch (e) {
      if (context.mounted) showSnack(context, userMessageForError(e));
      return;
    }
    ref.invalidate(schedulesProvider(reg));
    onDeleted?.call();
    if (context.mounted) {
      showSnack(context, '予約を削除しました');
      if (Navigator.of(context).canPop()) Navigator.of(context).pop();
    }
  }
}

ScheduleChannel? _recNgChannelRef(RecNgItem item) {
  final serviceId = item.serviceId;
  if (serviceId == null) return null;
  return ScheduleChannel(
    broadcastingType: item.broadcastingType ?? terrestrialBroadcastingType,
    channelType: 2,
    serviceId: serviceId,
  );
}

List<Channel> _channelsForOwner(WidgetRef ref, RegisteredNasne owner) {
  final terrestrial =
      ref.watch(channelsProvider(owner)).value ?? const <Channel>[];
  final bs = ref.watch(bsChannelsProvider(owner)).value ?? const <Channel>[];
  return [...terrestrial, ...bs];
}

class _RecNgList extends ConsumerWidget {
  const _RecNgList({
    required this.activeRegs,
    required this.sources,
    required this.items,
    required this.failedLabels,
    required this.isLoading,
    required this.firstError,
    required this.selectedKey,
    required this.onSelect,
    required this.onDismissOne,
    required this.onRetry,
  });

  final List<RegisteredNasne> activeRegs;
  final List<({RegisteredNasne reg, List<RecNgItem> items})> sources;
  final List<OwnedRecNgItem> items;
  final List<String> failedLabels;
  final bool isLoading;
  final Object? firstError;
  final String? selectedKey;
  final void Function(OwnedRecNgItem owned, bool showNasneName, bool twoPane)
  onSelect;
  final Future<void> Function(OwnedRecNgItem owned, {VoidCallback? onDismissed})
  onDismissOne;
  final VoidCallback onRetry;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final isMultiNasne = activeRegs.length > 1;
    if (sources.isEmpty) {
      if (isLoading) return const LoadingView();
      if (firstError != null) {
        return ErrorView(
          message: userMessageForError(firstError!),
          onRetry: onRetry,
        );
      }
    }
    if (items.isEmpty) {
      return Column(
        children: [
          if (failedLabels.isNotEmpty)
            Padding(
              padding: const EdgeInsets.fromLTRB(12, 8, 12, 0),
              child: Text(
                '一部の nasne から取得できませんでした（${failedLabels.join('、')}）',
                style: Theme.of(context).textTheme.bodySmall?.copyWith(
                  color: Theme.of(context).colorScheme.error,
                ),
              ),
            ),
          const Expanded(child: Center(child: Text('録画失敗はありません'))),
        ],
      );
    }

    final channelsByHost = <String, List<Channel>>{
      for (final r in activeRegs) r.host: _channelsForOwner(ref, r),
    };

    return LayoutBuilder(
      builder: (context, constraints) {
        final twoPane = constraints.maxWidth >= twoPaneBreakpoint;
        final listView = Column(
          children: [
            if (failedLabels.isNotEmpty)
              Padding(
                padding: const EdgeInsets.fromLTRB(12, 8, 12, 0),
                child: Align(
                  alignment: Alignment.centerLeft,
                  child: Text(
                    '一部の nasne から取得できませんでした（${failedLabels.join('、')}）',
                    style: Theme.of(context).textTheme.bodySmall?.copyWith(
                      color: Theme.of(context).colorScheme.error,
                    ),
                  ),
                ),
              ),
            Expanded(
              child: ListView.builder(
                itemCount: items.length,
                itemBuilder: (context, i) {
                  final owned = items[i];
                  final item = owned.item;
                  final chRef = _recNgChannelRef(item);
                  final chLabel = chRef != null
                      ? channelDisplayName(channelsByHost[owned.reg.host], chRef)
                      : null;
                  final ownerPrefix = isMultiNasne
                      ? '[${nasneDisplayLabel(owned.reg)}] '
                      : '';
                  final when = item.startTime != null
                      ? formatDateTimeWithWeekdayJst(item.startTime!)
                      : '日時不明';
                  final durText = item.durationSeconds != null
                      ? ' (${formatDurationSeconds(item.durationSeconds!)})'
                      : '';
                  final qualityText = item.desiredQualityMode != null
                      ? ' 画質 ${recNgQualityModeLabel(item.desiredQualityMode!)}'
                      : '';
                  return ListTile(
                    key: ValueKey('recng:${owned.dismissKey}'),
                    selected: owned.dismissKey == selectedKey,
                    leading: const Icon(Icons.videocam_off_outlined),
                    title: Text(item.title ?? '(タイトルなし)'),
                    subtitle: Text(
                      '$ownerPrefix$when'
                      '${chLabel != null ? ' / $chLabel' : ''}'
                      '$durText$qualityText',
                    ),
                    trailing: item.ngId != null
                        ? Text(
                            'NG:${item.ngId}',
                            style: Theme.of(context).textTheme.labelSmall,
                          )
                        : null,
                    onTap: () => onSelect(owned, isMultiNasne, twoPane),
                  );
                },
              ),
            ),
          ],
        );
        if (!twoPane) return listView;
        OwnedRecNgItem? selected;
        for (final owned in items) {
          if (owned.dismissKey == selectedKey) {
            selected = owned;
            break;
          }
        }
        return Row(
          children: [
            Expanded(flex: 5, child: listView),
            const VerticalDivider(thickness: 1, width: 1),
            Expanded(
              flex: 6,
              child: selected == null
                  ? const Center(child: Text('録画失敗を選択してください'))
                  : _RecNgDetailView(
                      owned: selected,
                      showNasneName: isMultiNasne,
                      onDismiss: () => onDismissOne(selected!),
                    ),
            ),
          ],
        );
      },
    );
  }
}

class _RecNgDetailPage extends ConsumerWidget {
  const _RecNgDetailPage({required this.owned, required this.showNasneName});

  final OwnedRecNgItem owned;
  final bool showNasneName;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final dismissed = ref.watch(dismissedRecNgKeysProvider);
    final stillVisible = !dismissed.contains(owned.dismissKey);
    return Scaffold(
      appBar: AppBar(title: const Text('録画失敗の詳細')),
      body: stillVisible
          ? _RecNgDetailView(
              owned: owned,
              showNasneName: showNasneName,
              autofocusDelete: true,
              onDismiss: () async {
                final title = owned.item.title ?? '(タイトルなし)';
                final ok = await confirmDialog(
                  context,
                  title: '録画失敗履歴を削除',
                  message:
                      '「$title」をこのアプリの録画失敗一覧から削除しますか？\n'
                      '（nasne 本体の履歴は仕様上消去されないため、再インストール時には再表示されます）',
                );
                if (!ok) return;
                await ref
                    .read(dismissedRecNgKeysProvider.notifier)
                    .dismiss(owned.dismissKey);
                if (context.mounted) {
                  showSnack(context, '録画失敗履歴を削除しました');
                  if (Navigator.of(context).canPop()) Navigator.of(context).pop();
                }
              },
            )
          : const Center(child: Text('削除済みの履歴です')),
    );
  }
}

class _RecNgDetailView extends ConsumerWidget {
  const _RecNgDetailView({
    required this.owned,
    required this.showNasneName,
    this.autofocusDelete = false,
    required this.onDismiss,
  });

  final OwnedRecNgItem owned;
  final bool showNasneName;
  final bool autofocusDelete;
  final VoidCallback onDismiss;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final item = owned.item;
    final channels = _channelsForOwner(ref, owned.reg);
    final chRef = _recNgChannelRef(item);
    return ListView(
      padding: const EdgeInsets.all(16),
      children: [
        Text(
          item.title ?? '(タイトルなし)',
          style: Theme.of(context).textTheme.titleMedium,
        ),
        const SizedBox(height: 12),
        if (showNasneName)
          FieldRow(label: '録画機器', value: nasneDisplayLabel(owned.reg)),
        if (chRef != null)
          FieldRow(
            label: 'チャンネル',
            value: channelDisplayName(channels, chRef),
          ),
        if (item.startTime != null)
          FieldRow(
            label: '予定日時',
            value: formatDateTimeWithWeekdayJst(item.startTime!),
          ),
        if (item.durationSeconds != null)
          FieldRow(
            label: '長さ',
            value: formatDurationSeconds(item.durationSeconds!),
          ),
        if (item.desiredQualityMode != null)
          FieldRow(
            label: '画質モード',
            value: recNgQualityModeLabel(item.desiredQualityMode!),
          ),
        if (item.ngId != null)
          FieldRow(label: '失敗コード', value: 'ngID=${item.ngId}'),
        const SizedBox(height: 16),
        Text(
          '※ nasne 本体の仕様上、本体側失敗履歴を直接消去する機能はないため、'
          'このアプリの一覧からの非表示削除として管理します。',
          style: Theme.of(context).textTheme.bodySmall,
        ),
        const SizedBox(height: 20),
        Align(
          alignment: Alignment.centerLeft,
          child: FilledButton.icon(
            autofocus: autofocusDelete,
            onPressed: onDismiss,
            icon: const Icon(Icons.delete_outline),
            label: const Text('この履歴を削除'),
          ),
        ),
      ],
    );
  }
}
