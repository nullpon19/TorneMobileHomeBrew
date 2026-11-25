/// Programme search screen (plan 86, plan 85 item 8):
/// keyword and genre search over the EPG dataset the guide
/// providers already hold. Each hit leads to the same event
/// detail dialog — and from there the same reservation
/// form — as a tap on the guide grid (see
/// [showEpgEventDetail]).
///
/// Both bands are searched together: the viewer thinks in
/// programmes, not in broadcasting types, and the
/// terrestrial / BS split is a guide-grid concern. A band
/// whose guide is still loading or failed to load simply
/// contributes nothing yet; the other band's hits are
/// shown. The search runs over the full dataset, including
/// subchannels the guide grid may be set to hide — finding
/// a programme is the point of searching for it.
///
/// Plan 98: the search runs over an [EpgSearchIndex] built
/// once per dataset (see epg_search.dart), and keystrokes
/// are debounced — a burst of typing applies one search
/// when it settles, not a full rescan per character.
library;

import 'dart:async';

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:material_ui/material_ui.dart';

import '../app/bs_epg_providers.dart';
import '../app/state.dart';
import '../core/core.dart';
import 'epg_screen.dart';
import 'epg_search.dart';
import 'epg_title_badges.dart';
import 'format.dart';
import 'live_screen.dart';
import 'multi_nasne_policy.dart';
import 'widgets.dart';

class EpgSearchScreen extends ConsumerStatefulWidget {
  const EpgSearchScreen({super.key, required this.reg});

  final RegisteredNasne reg;

  @override
  ConsumerState<EpgSearchScreen> createState() => _EpgSearchScreenState();
}

class _EpgSearchScreenState extends ConsumerState<EpgSearchScreen> {
  final _queryController = TextEditingController();

  /// The query the results actually reflect (plan 98):
  /// keystrokes land here only once typing settles for
  /// [queryDebounce], so a burst of input runs one search.
  String _appliedQuery = '';
  Timer? _debounce;
  int? _genreLevel1;

  /// The search index over the current dataset, rebuilt
  /// only when a band's guide object is replaced (a reload),
  /// never per keystroke or per rebuild.
  EpgSearchIndex? _index;
  EpgGuide? _indexedTerrestrial;
  EpgGuide? _indexedBs;

  /// How long typing may pause before its search runs.
  static const Duration queryDebounce = Duration(milliseconds: 200);

  @override
  void dispose() {
    _debounce?.cancel();
    _queryController.dispose();
    super.dispose();
  }

  void _onQueryChanged(String value) {
    _debounce?.cancel();
    _debounce = Timer(queryDebounce, () {
      if (mounted) setState(() => _appliedQuery = value);
    });
  }

  void _clearQuery() {
    _debounce?.cancel();
    _queryController.clear();
    setState(() => _appliedQuery = '');
  }

  EpgSearchIndex _indexFor(EpgGuide? terrestrial, EpgGuide? bs) {
    if (_index == null ||
        !identical(terrestrial, _indexedTerrestrial) ||
        !identical(bs, _indexedBs)) {
      _index = EpgSearchIndex.fromGuides([?terrestrial, ?bs]);
      _indexedTerrestrial = terrestrial;
      _indexedBs = bs;
    }
    return _index!;
  }

  @override
  Widget build(BuildContext context) {
    final terrestrial = ref.watch(epgGuideProvider(widget.reg)).value;
    final bs = ref.watch(bsEpgGuideProvider(widget.reg)).value;
    final guides = <EpgGuide>[?terrestrial, ?bs];
    final index = _indexFor(terrestrial, bs);
    final genreValues = index.genreValues;
    // A genre picked before the data (re)loaded may not
    // exist in the current dataset; fall back to "all"
    // rather than filtering everything away behind the
    // viewer's back.
    final genre = genreValues.contains(_genreLevel1) ? _genreLevel1 : null;
    final searched = _appliedQuery.trim().isNotEmpty || genre != null;
    final hits = searched
        ? index.search(query: _appliedQuery, genreLevel1: genre)
        : const <EpgSearchHit>[];

    return Scaffold(
      appBar: AppBar(title: const Text('番組検索')),
      body: Column(
        children: [
          Padding(
            padding: const EdgeInsets.fromLTRB(16, 12, 16, 4),
            child: FireTvTextInputField(
              controller: _queryController,
              labelText: 'キーワード',
              hintText: '番組名・内容・出演者など',
              dialogTitle: 'キーワードを入力',
              prefixIcon: Icons.search,
              showClearButton: true,
              autofocus: true,
              onChanged: (v) => v.isEmpty ? _clearQuery() : _onQueryChanged(v),
            ),
          ),
          Padding(
            padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 4),
            child: Row(
              children: [
                const Text('ジャンル'),
                const SizedBox(width: 12),
                Expanded(
                  child: DropdownButton<int?>(
                    value: genre,
                    isExpanded: true,
                    items: [
                      const DropdownMenuItem<int?>(
                        value: null,
                        child: Text('すべて'),
                      ),
                      for (final value in genreValues)
                        DropdownMenuItem<int?>(
                          value: value,
                          child: Text(epgSearchGenreLabel(value)),
                        ),
                    ],
                    onChanged: (value) => setState(() => _genreLevel1 = value),
                  ),
                ),
              ],
            ),
          ),
          const Divider(height: 1),
          Expanded(child: _buildResults(guides, searched, hits)),
        ],
      ),
    );
  }

  Widget _buildResults(
    List<EpgGuide> guides,
    bool searched,
    List<EpgSearchHit> hits,
  ) {
    if (guides.isEmpty) return const LoadingView();
    if (!searched) {
      return const Center(
        child: Padding(
          padding: EdgeInsets.all(24),
          child: Text(
            'キーワードを入力するか、ジャンルを選ぶと、'
            '番組表から番組を探せます。',
            textAlign: TextAlign.center,
          ),
        ),
      );
    }
    if (hits.isEmpty) {
      return const Center(child: Text('見つかりませんでした。'));
    }
    final regs =
        ref.watch(registrationsProvider).value ?? const <RegisteredNasne>[];
    final activeRegs = regs.length > 1
        ? regs
        : <RegisteredNasne>[widget.reg];
    final isMultiNasne = activeRegs.length > 1;
    final ownedSchedules = <OwnedRecordSchedule>[
      for (final r in activeRegs)
        for (final s
            in (ref.watch(schedulesProvider(r)).value ??
                const <RecordSchedule>[]))
          OwnedRecordSchedule(reg: r, schedule: s),
    ];
    final isDark = Theme.of(context).brightness == Brightness.dark;
    final reservedColor = isDark
        ? Colors.redAccent
        : const Color(0xFFD32F2F);
    return ListView.builder(
      itemCount: hits.length,
      itemBuilder: (context, index) {
        final hit = hits[index];
        final event = hit.event;
        final matched = findMatchingOwnedSchedule(
          ownedSchedules,
          hit.channel,
          event,
        );
        return ListTile(
          title: BroadcastTitleLine(
            rawTitle: event.title ?? '番組情報なし',
            maxLines: 2,
            darkSurface: isDark,
          ),
          subtitle: Text(
            '${hit.channelName}\n'
            '${formatDateTimeWithWeekdayJst(event.start)} 〜 '
            '${formatTimeJst(event.end)}',
          ),
          isThreeLine: true,
          trailing: matched != null
              ? Icon(Icons.fiber_manual_record, size: 12, color: reservedColor)
              : null,
          onTap: () => showEpgEventDetail(
            context,
            reg: widget.reg,
            channel: hit.channel,
            channelName: hit.channelName,
            event: event,
            existingSchedule: matched?.schedule,
            existingScheduleReg: matched?.reg,
            reservedNasneName: isMultiNasne && matched != null
                ? nasneDisplayLabel(matched.reg)
                : null,
            onWatch: () => openLiveChannelForEpg(
              context,
              ref,
              reg: widget.reg,
              channel: hit.channel,
            ),
          ),
        );
      },
    );
  }
}
