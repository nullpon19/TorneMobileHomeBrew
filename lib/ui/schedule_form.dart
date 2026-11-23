/// Reservation create / edit forms (plan 5.6 item 2, 12.5, 12.7).
///
/// The forms encode the measured device contract (plan 11.7, 13.6,
/// 13.7):
///  * create sends the full torne template (built by the core from
///    [NewRecordSchedule]); before creating, the candidate is checked
///    with `X_GetConflictList` and conflicts are shown as a warning
///    the user can accept or cancel;
///  * edit is a sparse update: `priorityFlag` is always sent and at
///    least one change field is included (the three changeable fields
///    are always submitted with their control values);
///  * start time and duration cannot be updated, so a time change is
///    modelled as create-then-delete of the original reservation.
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
import 'schedule_channel_selection.dart';
import 'schedule_destination.dart';
import 'widgets.dart';

enum ScheduleFormMode { create, edit, timeChange }

/// Programme data prefilled into the create form from the EPG
/// (plan 28): the event's service, start, duration and texts. The
/// create itself goes through the same XSRS path as a manual
/// reservation; the event id is carried into the candidate's
/// desiredMatchingID, like torne's own EPG reservations.
class SchedulePrefill {
  const SchedulePrefill({
    required this.channel,
    required this.start,
    required this.durationSeconds,
    required this.eventId,
    this.title,
    this.description,
  });

  final Channel channel;
  final DateTime start;
  final int durationSeconds;
  final int eventId;
  final String? title;
  final String? description;
}

class ScheduleFormPage extends ConsumerStatefulWidget {
  const ScheduleFormPage({
    super.key,
    required this.reg,
    required this.mode,
    this.original,
    this.prefill,
  });

  factory ScheduleFormPage.create(RegisteredNasne reg) =>
      ScheduleFormPage(reg: reg, mode: ScheduleFormMode.create);

  /// Create form prefilled from a programme-guide event (plan 28).
  factory ScheduleFormPage.fromEpg(
    RegisteredNasne reg, {
    required Channel channel,
    required EpgEvent event,
  }) => ScheduleFormPage(
    reg: reg,
    mode: ScheduleFormMode.create,
    prefill: SchedulePrefill(
      channel: channel,
      start: event.start,
      durationSeconds: event.duration.inSeconds,
      eventId: event.eventId,
      title: event.title,
      description: event.description ?? event.shortText,
    ),
  );

  factory ScheduleFormPage.edit(RegisteredNasne reg, RecordSchedule original) =>
      ScheduleFormPage(
        reg: reg,
        mode: ScheduleFormMode.edit,
        original: original,
      );

  factory ScheduleFormPage.timeChange(
    RegisteredNasne reg,
    RecordSchedule original,
  ) => ScheduleFormPage(
    reg: reg,
    mode: ScheduleFormMode.timeChange,
    original: original,
  );

  final RegisteredNasne reg;
  final ScheduleFormMode mode;
  final RecordSchedule? original;

  /// EPG prefill for the create form (plan 28); null for the
  /// manual create / edit / time-change forms.
  final SchedulePrefill? prefill;

  @override
  ConsumerState<ScheduleFormPage> createState() => _ScheduleFormPageState();
}

class _ScheduleFormPageState extends ConsumerState<ScheduleFormPage> {
  // create / timeChange fields
  int _selectedBand = terrestrialBroadcastingType;
  String? _selectedChannelKey;
  late DateTime _date; // JST wall date (fields only)
  late TimeOfDay _time;
  final _durationMinutes = TextEditingController(text: '60');
  // shared fields
  late int _quality;
  late bool _priority;
  String _destinationId = recordDestinationInternal;
  // edit fields
  final _condition = TextEditingController();
  final _destination = TextEditingController();
  // multi-nasne target host (create mode only; null = auto)
  String? _targetHost;

  bool _saving = false;

  bool get _isEdit => widget.mode == ScheduleFormMode.edit;

  @override
  void initState() {
    super.initState();
    final original = widget.original;
    if (original != null) {
      _quality = original.desiredQualityMode;
      _priority = original.priorityFlag != 0;
      _condition.text = original.conditionId;
      _destination.text = original.recordDestinationId;
      _destinationId = original.recordDestinationId == recordDestinationExternal
          ? recordDestinationExternal
          : recordDestinationInternal;
      final wall = jstWallClock(original.start);
      _date = DateTime(wall.year, wall.month, wall.day);
      _time = TimeOfDay(hour: wall.hour, minute: wall.minute);
      _durationMinutes.text = '${original.durationSeconds ~/ 60}';
      _selectedBand = original.channel.broadcastingType;
    } else {
      _quality = 100;
      _priority = false;
      final prefill = widget.prefill;
      if (prefill != null) {
        // EPG prefill (plan 28): service, start and duration come
        // from the event; the quality stays the user's choice.
        _selectedBand = prefill.channel.broadcastingType;
        _selectedChannelKey = scheduleChannelKey(prefill.channel);
        final wall = jstWallClock(prefill.start);
        _date = DateTime(wall.year, wall.month, wall.day);
        _time = TimeOfDay(hour: wall.hour, minute: wall.minute);
        final minutes = (prefill.durationSeconds / 60).round();
        _durationMinutes.text = '${minutes < 1 ? 1 : minutes}';
      } else {
        final wall = jstWallClock(DateTime.now().add(const Duration(hours: 1)));
        _date = DateTime(wall.year, wall.month, wall.day);
        _time = TimeOfDay(hour: wall.hour, minute: 0);
      }
    }
  }

  @override
  void dispose() {
    _durationMinutes.dispose();
    _condition.dispose();
    _destination.dispose();
    super.dispose();
  }

  String get _title => switch (widget.mode) {
    ScheduleFormMode.create => widget.prefill != null ? '番組を予約' : '新規予約',
    ScheduleFormMode.edit => '予約の編集',
    ScheduleFormMode.timeChange => '予約時刻の変更',
  };

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: Text(_title)),
      body: _isEdit ? _buildEditForm(context) : _buildCreateForm(context),
    );
  }

  // -------------------------------------------------------------------------
  // Create / time-change form
  // -------------------------------------------------------------------------

  Widget _buildCreateForm(BuildContext context) {
    final regs =
        ref.watch(registrationsProvider).value ?? const <RegisteredNasne>[];
    final showMultiTarget =
        widget.mode == ScheduleFormMode.create && regs.length > 1;
    final activeHost = _targetHost != null &&
            regs.any((r) => r.host == _targetHost)
        ? _targetHost
        : null;
    final targetReg = activeHost != null
        ? regs.firstWhere((r) => r.host == activeHost, orElse: () => widget.reg)
        : widget.reg;
    final channels = _selectedBand == bsBroadcastingType
        ? ref.watch(bsChannelsProvider(targetReg))
        : ref.watch(channelsProvider(targetReg));
    final hddDetails = ref.watch(hddDetailsProvider(targetReg)).value;
    final externalAvailable =
        hddDetails != null &&
        externalDestinationAvailable([for (final d in hddDetails) d.entry]);
    return ListView(
      padding: const EdgeInsets.all(16),
      children: [
        if (widget.prefill != null) ...[
          // The programme being reserved (plan 28): shown for
          // confirmation; the fields below start from its values
          // and stay editable.
          Text(
            widget.prefill!.title ?? '番組情報なし',
            style: Theme.of(context).textTheme.titleMedium,
          ),
          const SizedBox(height: 4),
          Text(
            '${widget.prefill!.channel.serviceName} / '
            '${formatDateTimeWithWeekdayJst(widget.prefill!.start)} 〜 '
            '${formatTimeJst(widget.prefill!.start.add(Duration(seconds: widget.prefill!.durationSeconds)))}',
          ),
          if (widget.prefill!.description != null &&
              widget.prefill!.description!.isNotEmpty) ...[
            const SizedBox(height: 8),
            Text(widget.prefill!.description!),
          ],
          const SizedBox(height: 16),
        ],
        if (widget.mode == ScheduleFormMode.timeChange)
          const Padding(
            padding: EdgeInsets.only(bottom: 12),
            child: Text('時刻の変更は、元の予約を削除して新しい予約を作成することで行います。'),
          ),
        if (showMultiTarget) ...[
          DropdownButtonFormField<String?>(
            key: ValueKey('schedule-nasne-$activeHost'),
            initialValue: activeHost,
            decoration: const InputDecoration(labelText: '録画する nasne'),
            items: [
              const DropdownMenuItem<String?>(
                value: null,
                child: Text('自動選択（空きチューナー・空き容量優先）'),
              ),
              for (final r in regs)
                DropdownMenuItem<String?>(
                  value: r.host,
                  child: Text(nasneDisplayLabel(r)),
                ),
            ],
            onChanged: (value) => setState(() => _targetHost = value),
          ),
          const SizedBox(height: 12),
        ],
        SegmentedButton<int>(
          segments: const [
            ButtonSegment<int>(
              value: terrestrialBroadcastingType,
              label: Text('地デジ'),
            ),
            ButtonSegment<int>(value: bsBroadcastingType, label: Text('BS')),
          ],
          selected: {_selectedBand},
          onSelectionChanged: (values) => setState(() {
            final nextBand = values.first;
            if (nextBand != _selectedBand) {
              _selectedBand = nextBand;
              _selectedChannelKey = null;
            }
          }),
        ),
        const SizedBox(height: 12),
        asyncSection(
          channels,
          (list) {
            final choices = [
              for (final c in list)
                if (c.broadcastingType == _selectedBand && c.serviceType == 1)
                  c,
            ];
            if (choices.isEmpty) {
              return const Text('選択できるテレビ局がありません');
            }
            final value = initialScheduleChannelKey(
              choices,
              _selectedBand,
              _selectedChannelKey,
              prefill: widget.prefill?.channel,
              original: widget.original?.channel,
              defaultToFirst: widget.prefill == null && widget.original == null,
            );
            return DropdownButtonFormField<String>(
              key: ValueKey('schedule-channel-$_selectedBand-$value'),
              initialValue: value,
              hint: const Text('チャンネルを選択'),
              decoration: const InputDecoration(labelText: 'チャンネル'),
              items: [
                for (final c in choices)
                  DropdownMenuItem(
                    value: scheduleChannelKey(c),
                    child: Text(c.serviceName),
                  ),
              ],
              onChanged: (v) => setState(() => _selectedChannelKey = v),
            );
          },
          onRetry: () {
            if (_selectedBand == bsBroadcastingType) {
              ref.invalidate(bsChannelsProvider(targetReg));
            } else {
              ref.invalidate(channelsProvider(targetReg));
            }
          },
        ),
        const SizedBox(height: 16),
        Row(
          children: [
            Expanded(
              child: Text(
                '日付: ${formatDateJst(instantFromJstWall(_date))} '
                '(${formatWeekdayJst(instantFromJstWall(_date))})',
              ),
            ),
            TextButton(onPressed: _pickDate, child: const Text('日付を選択')),
          ],
        ),
        Row(
          children: [
            Expanded(child: Text('開始時刻: ${_time.format(context)}')),
            TextButton(onPressed: _pickTime, child: const Text('時刻を選択')),
          ],
        ),
        const SizedBox(height: 8),
        FireTvTextInputField(
          controller: _durationMinutes,
          labelText: '長さ (分)',
          hintText: '分数を入力',
          suffixText: '分',
          keyboardType: TextInputType.number,
        ),
        const SizedBox(height: 16),
        _qualityField(),
        if (externalAvailable) ...[
          const SizedBox(height: 16),
          _destinationField(),
        ],
        SwitchListTile(
          title: const Text('優先フラグ'),
          value: _priority,
          onChanged: (v) => setState(() => _priority = v),
        ),
        const SizedBox(height: 24),
        FilledButton(
          onPressed: _saving ? null : _saveCreate,
          child: Text(_saving ? '送信中…' : '予約を作成'),
        ),
      ],
    );
  }

  Future<void> _pickDate() async {
    final picked = await showDatePicker(
      context: context,
      initialDate: _date,
      firstDate: DateTime(_date.year - 1),
      lastDate: DateTime(_date.year + 2),
    );
    if (picked != null) {
      setState(() => _date = DateTime(picked.year, picked.month, picked.day));
    }
  }

  Future<void> _pickTime() async {
    final picked = await showDialog<TimeOfDay>(
      context: context,
      builder: (_) => FireTvTimePickerDialog(initialTime: _time),
    );
    if (picked != null) setState(() => _time = picked);
  }

  Widget _qualityField() {
    // The measured torne values in the XSRS space (plan 28):
    // 100 = DR, 230 = 3倍. An existing reservation's own value is
    // always offered as well, so editing never silently rewrites
    // an unlisted value.
    final options = <int>{
      100,
      230,
      if (widget.original != null) widget.original!.desiredQualityMode,
    }.toList()..sort();
    return DropdownButtonFormField<int>(
      initialValue: _quality,
      decoration: const InputDecoration(labelText: '画質モード'),
      items: [
        for (final q in options)
          DropdownMenuItem(value: q, child: Text(qualityModeLabel(q))),
      ],
      onChanged: (v) => setState(() => _quality = v ?? _quality),
    );
  }

  Widget _destinationField() {
    // Offered only while an external HDD is registered and
    // mounted; without one the form stays internal-only, as
    // before (see externalDestinationAvailable).
    return DropdownButtonFormField<String>(
      initialValue: _destinationId,
      decoration: const InputDecoration(labelText: '録画先'),
      items: [
        for (final id in const [
          recordDestinationInternal,
          recordDestinationExternal,
        ])
          DropdownMenuItem(value: id, child: Text(recordDestinationLabel(id))),
      ],
      onChanged: (v) => setState(() => _destinationId = v ?? _destinationId),
    );
  }

  /// Whether an external HDD is currently known to be registered
  /// and mounted; false while the HDD list is loading or failed.
  bool _externalAvailableFor(RegisteredNasne target) {
    final details = ref.read(hddDetailsProvider(target)).value;
    if (details == null) return false;
    return externalDestinationAvailable([for (final d in details) d.entry]);
  }

  Future<void> _saveCreate() async {
    FocusScope.of(context).unfocus();
    final regs =
        ref.read(registrationsProvider).value ?? const <RegisteredNasne>[];
    final isMultiAuto =
        widget.mode == ScheduleFormMode.create &&
        regs.length > 1 &&
        (_targetHost == null || !regs.any((r) => r.host == _targetHost));
    final explicitTargetReg =
        widget.mode == ScheduleFormMode.create &&
            regs.length > 1 &&
            _targetHost != null
        ? regs.firstWhere(
            (r) => r.host == _targetHost,
            orElse: () => widget.reg,
          )
        : widget.reg;

    final channels =
        (_selectedBand == bsBroadcastingType
                ? ref.read(bsChannelsProvider(explicitTargetReg))
                : ref.read(channelsProvider(explicitTargetReg)))
            .value;
    final choices = <Channel>[
      for (final c in channels ?? const <Channel>[])
        if (c.broadcastingType == _selectedBand && c.serviceType == 1) c,
    ];
    final selectedKey = initialScheduleChannelKey(
      choices,
      _selectedBand,
      _selectedChannelKey,
      prefill: widget.prefill?.channel,
      original: widget.original?.channel,
      defaultToFirst: widget.prefill == null && widget.original == null,
    );
    final channel = resolveScheduleChannel(choices, _selectedBand, selectedKey);
    if (channel == null) {
      showSnack(context, 'チャンネルを選択してください');
      return;
    }
    final minutes = int.tryParse(_durationMinutes.text.trim());
    if (minutes == null || minutes < 1 || minutes > 1440) {
      showSnack(context, '長さは 1〜1440 分で入力してください');
      return;
    }
    final start = instantFromJstWall(
      DateTime(_date.year, _date.month, _date.day, _time.hour, _time.minute),
    );
    NewRecordSchedule buildCandidate(RegisteredNasne target) =>
        NewRecordSchedule(
          start: start,
          durationSeconds: minutes * 60,
          channel: ScheduleChannel(
            broadcastingType: channel.broadcastingType,
            channelType: channel.broadcastingType,
            serviceId: channel.serviceId,
          ),
          networkId: channel.networkId,
          // Never associate an EPG event with a different selected channel.
          eventId:
              widget.prefill != null &&
                  scheduleChannelKey(widget.prefill!.channel) ==
                      scheduleChannelKey(channel)
              ? widget.prefill!.eventId
              : 0,
          desiredQualityMode: _quality,
          priorityFlag: _priority ? 1 : 0,
          recordDestinationId: effectiveRecordDestination(
            _destinationId,
            externalAvailable: _externalAvailableFor(target),
          ),
        );

    setState(() => _saving = true);

    if (isMultiAuto) {
      final candidate = buildCandidate(widget.reg);
      final reachableRegs = <RegisteredNasne>[];
      final hasConflictByHost = <String, bool>{};
      final freeBytesByHost = <String, int>{};
      final allConflicts = <RecordSchedule>[];
      Object? firstError;

      final results = await Future.wait([
        for (final r in regs)
          () async {
            try {
              final svc = ref.read(deviceServicesProvider(r));
              final conflicts = await svc.schedules.checkConflicts(candidate);
              var hdds = ref.read(hddDetailsProvider(r)).value;
              if (hdds == null) {
                try {
                  hdds = await ref
                      .read(hddDetailsProvider(r).future)
                      .timeout(const Duration(seconds: 3));
                } catch (_) {
                  hdds = null;
                }
              }
              return (
                reg: r,
                conflicts: conflicts,
                freeBytes: totalFreeBytesForHdds(hdds),
                error: null as Object?,
              );
            } catch (e) {
              return (
                reg: r,
                conflicts: const <RecordSchedule>[],
                freeBytes: -1,
                error: e,
              );
            }
          }(),
      ]);

      for (final res in results) {
        if (res.error != null) {
          firstError ??= res.error;
          continue;
        }
        reachableRegs.add(res.reg);
        hasConflictByHost[res.reg.host] = res.conflicts.isNotEmpty;
        freeBytesByHost[res.reg.host] = res.freeBytes;
        allConflicts.addAll(res.conflicts);
      }

      if (!mounted) return;
      if (reachableRegs.isEmpty) {
        setState(() => _saving = false);
        showSnack(
          context,
          firstError != null ? userMessageForError(firstError) : '予約を作成できませんでした',
        );
        return;
      }

      var target = selectAutoScheduleNasne(
        candidates: reachableRegs,
        hasConflictByHost: hasConflictByHost,
        freeBytesByHost: freeBytesByHost,
        preferredReg: widget.reg,
      );

      if (target == null) {
        final otherChannels = _selectedBand == bsBroadcastingType
            ? (ref.read(channelsProvider(widget.reg)).value ??
                  const <Channel>[])
            : (ref.read(bsChannelsProvider(widget.reg)).value ??
                  const <Channel>[]);
        final proceed = await _showConflictWarning(allConflicts, [
          ...choices,
          ...otherChannels,
        ]);
        if (proceed != true) {
          if (mounted) setState(() => _saving = false);
          return;
        }
        target = reachableRegs.any((r) => r.host == widget.reg.host)
            ? widget.reg
            : reachableRegs.first;
      }

      try {
        await ref
            .read(deviceServicesProvider(target))
            .schedules
            .createSchedule(buildCandidate(target));
      } on NasneError catch (e) {
        if (!mounted) return;
        setState(() => _saving = false);
        showSnack(context, userMessageForError(e));
        return;
      }
      ref.invalidate(schedulesProvider(target));
      if (!mounted) return;
      Navigator.of(context).pop();
      showSnack(context, '予約を作成しました（${nasneDisplayLabel(target)}）');
      return;
    }

    final candidate = buildCandidate(explicitTargetReg);
    final services = ref.read(deviceServicesProvider(explicitTargetReg));
    try {
      var conflicts = await services.schedules.checkConflicts(candidate);
      final original = widget.original;
      if (widget.mode == ScheduleFormMode.timeChange && original != null) {
        // The reservation being replaced always overlaps itself; it is
        // not a conflict for this flow (plan 12.7 time-change model).
        conflicts = [
          for (final c in conflicts)
            if (c.id != original.id) c,
        ];
      }
      if (conflicts.isNotEmpty) {
        if (!mounted) return;
        final otherChannels = _selectedBand == bsBroadcastingType
            ? (ref.read(channelsProvider(explicitTargetReg)).value ??
                  const <Channel>[])
            : (ref.read(bsChannelsProvider(explicitTargetReg)).value ??
                  const <Channel>[]);
        final proceed = await _showConflictWarning(conflicts, [
          ...choices,
          ...otherChannels,
        ]);
        if (proceed != true) {
          setState(() => _saving = false);
          return;
        }
      }
      await services.schedules.createSchedule(candidate);
      if (widget.mode == ScheduleFormMode.timeChange && original != null) {
        await services.schedules.deleteSchedule(original.id);
      }
    } on NasneError catch (e) {
      if (!mounted) return;
      setState(() => _saving = false);
      showSnack(context, userMessageForError(e));
      return;
    }
    ref.invalidate(schedulesProvider(explicitTargetReg));
    if (!mounted) return;
    Navigator.of(context).pop();
    showSnack(
      context,
      regs.length > 1
          ? '予約を作成しました（${nasneDisplayLabel(explicitTargetReg)}）'
          : '予約を作成しました',
    );
  }

  Future<bool?> _showConflictWarning(
    List<RecordSchedule> conflicts,
    List<Channel>? channels,
  ) {
    return showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('競合する予約があります'),
        content: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            const Text('次の既存予約と時間が重なります:'),
            const SizedBox(height: 8),
            for (final c in conflicts)
              Text(
                '・${formatDateTimeJst(c.start)} '
                '${channelDisplayName(channels, c.channel)} '
                '(${formatDurationSeconds(c.durationSeconds)})',
              ),
          ],
        ),
        actions: [
          TextButton(
            autofocus: true,
            onPressed: () => Navigator.of(context).pop(false),
            child: const Text('キャンセル'),
          ),
          FilledButton(
            onPressed: () => Navigator.of(context).pop(true),
            child: const Text('このまま作成'),
          ),
        ],
      ),
    );
  }

  // -------------------------------------------------------------------------
  // Edit (sparse update) form
  // -------------------------------------------------------------------------

  Widget _buildEditForm(BuildContext context) {
    final original = widget.original!;
    return ListView(
      padding: const EdgeInsets.all(16),
      children: [
        FieldRow(
          label: '開始',
          value: formatDateTimeWithWeekdayJst(original.start),
        ),
        FieldRow(
          label: '長さ',
          value: formatDurationSeconds(original.durationSeconds),
        ),
        const Padding(
          padding: EdgeInsets.symmetric(vertical: 8),
          child: Text('開始時刻と長さは編集では変更できません。「時刻を変更」から行ってください。'),
        ),
        const SizedBox(height: 8),
        _qualityField(),
        SwitchListTile(
          title: const Text('優先フラグ'),
          value: _priority,
          onChanged: (v) => setState(() => _priority = v),
        ),
        FireTvTextInputField(
          controller: _condition,
          labelText: '条件 ID',
          hintText: '決定キーで入力',
        ),
        const SizedBox(height: 16),
        FireTvTextInputField(
          controller: _destination,
          labelText: '録画先',
          hintText: '決定キーで入力',
        ),
        const SizedBox(height: 24),
        FilledButton(
          onPressed: _saving ? null : _saveEdit,
          child: Text(_saving ? '送信中…' : '更新する'),
        ),
      ],
    );
  }

  Future<void> _saveEdit() async {
    FocusScope.of(context).unfocus();
    final original = widget.original!;
    final condition = _condition.text.trim();
    final destination = _destination.text.trim();
    final priority = _priority ? 1 : 0;
    final changed =
        _quality != original.desiredQualityMode ||
        priority != original.priorityFlag ||
        condition != original.conditionId ||
        destination != original.recordDestinationId;
    if (!changed) {
      showSnack(context, '変更がありません');
      return;
    }
    if (destination.isEmpty) {
      showSnack(context, '録画先を入力してください');
      return;
    }
    // Measured contract (plan 13.7): priorityFlag is mandatory and at
    // least one change field must accompany it. All three changeable
    // fields are always submitted, so the contract holds by shape.
    final update = ScheduleUpdate(
      id: original.id,
      priorityFlag: priority,
      conditionId: condition,
      desiredQualityMode: _quality,
      recordDestinationId: destination,
    );
    setState(() => _saving = true);
    try {
      await ref
          .read(deviceServicesProvider(widget.reg))
          .schedules
          .updateSchedule(update);
    } on NasneError catch (e) {
      if (!mounted) return;
      setState(() => _saving = false);
      showSnack(context, userMessageForError(e));
      return;
    }
    // After an update the re-read value is the truth (plan 12.5).
    ref.invalidate(schedulesProvider(widget.reg));
    if (!mounted) return;
    Navigator.of(context).pop();
    showSnack(context, '更新しました');
  }
}

/// Fire TV D-pad friendly time picker dialog replacing Material's analog
/// clock dial with straightforward step buttons.
class FireTvTimePickerDialog extends StatefulWidget {
  const FireTvTimePickerDialog({super.key, required this.initialTime});

  final TimeOfDay initialTime;

  @override
  State<FireTvTimePickerDialog> createState() => _FireTvTimePickerDialogState();
}

class _FireTvTimePickerDialogState extends State<FireTvTimePickerDialog> {
  late int _hour = widget.initialTime.hour;
  late int _minute = widget.initialTime.minute;

  void _addHours(int delta) => setState(() => _hour = (_hour + delta + 24) % 24);

  void _addMinutes(int delta) =>
      setState(() => _minute = (_minute + delta + 60) % 60);

  @override
  Widget build(BuildContext context) {
    final formatted =
        '${_hour.toString().padLeft(2, '0')}:${_minute.toString().padLeft(2, '0')}';
    return AlertDialog(
      title: const Text('開始時刻を選択'),
      content: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          Text(
            formatted,
            style: Theme.of(context).textTheme.displaySmall?.copyWith(
              fontWeight: FontWeight.bold,
            ),
          ),
          const SizedBox(height: 16),
          Wrap(
            spacing: 8,
            runSpacing: 8,
            alignment: WrapAlignment.center,
            children: [
              OutlinedButton(
                onPressed: () => _addHours(-1),
                child: const Text('-1時間'),
              ),
              OutlinedButton(
                autofocus: true,
                onPressed: () => _addHours(1),
                child: const Text('+1時間'),
              ),
            ],
          ),
          const SizedBox(height: 8),
          Wrap(
            spacing: 8,
            runSpacing: 8,
            alignment: WrapAlignment.center,
            children: [
              OutlinedButton(
                onPressed: () => _addMinutes(-10),
                child: const Text('-10分'),
              ),
              OutlinedButton(
                onPressed: () => _addMinutes(-1),
                child: const Text('-1分'),
              ),
              OutlinedButton(
                onPressed: () => _addMinutes(1),
                child: const Text('+1分'),
              ),
              OutlinedButton(
                onPressed: () => _addMinutes(10),
                child: const Text('+10分'),
              ),
            ],
          ),
        ],
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.of(context).pop(),
          child: const Text('キャンセル'),
        ),
        FilledButton(
          onPressed: () =>
              Navigator.of(context).pop(TimeOfDay(hour: _hour, minute: _minute)),
          child: const Text('決定'),
        ),
      ],
    );
  }
}
