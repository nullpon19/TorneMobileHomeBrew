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

class SchedulesScreen extends ConsumerStatefulWidget {
  const SchedulesScreen({super.key});

  @override
  ConsumerState<SchedulesScreen> createState() => _SchedulesScreenState();
}

class _SchedulesScreenState extends ConsumerState<SchedulesScreen> {
  String? _selectedKey;

  @override
  Widget build(BuildContext context) {
    final reg = ref.watch(selectedRegistrationProvider);
    final regs =
        ref.watch(registrationsProvider).value ?? const <RegisteredNasne>[];
    final activeRegs = regs.length > 1
        ? regs
        : (reg != null ? [reg] : const <RegisteredNasne>[]);
    return Scaffold(
      appBar: AppBar(
        title: const Text('予約'),
        actions: [
          if (reg != null) ...[
            Padding(
              padding: const EdgeInsets.only(right: 4),
              child: FilledButton.tonalIcon(
                style: FilledButton.styleFrom(
                  padding: const EdgeInsets.symmetric(horizontal: 10),
                  visualDensity: VisualDensity.compact,
                ),
                onPressed: () => Navigator.of(context).push(
                  MaterialPageRoute(builder: (_) => ScheduleFormPage.create(reg)),
                ),
                icon: const Icon(Icons.add, size: 18),
                label: const Text('新規予約'),
              ),
            ),
            IconButton(
              icon: const Icon(Icons.refresh),
              tooltip: '更新',
              onPressed: () {
                for (final r in activeRegs) {
                  ref.invalidate(schedulesProvider(r));
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
          : _ScheduleList(
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
    final needsBs =
        ref
            .watch(schedulesProvider(owner))
            .value
            ?.any((s) => s.channel.broadcastingType == bsBroadcastingType) ??
        false;
    final bs = needsBs
        ? (ref.watch(bsChannelsProvider(owner)).value ?? const <Channel>[])
        : const <Channel>[];
    return [...terrestrial, ...bs];
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
    final channels = s.channel.broadcastingType == bsBroadcastingType
        ? ref.watch(bsChannelsProvider(reg)).value
        : ref.watch(channelsProvider(reg)).value;
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
