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

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:material_ui/material_ui.dart';

import '../app/providers.dart';
import '../app/state.dart';
import '../core/core.dart';
import 'error_messages.dart';
import 'format.dart';
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

Future<void> _showDeleteRefusal(BuildContext context, String message) {
  return showDialog<void>(
    context: context,
    builder: (context) => AlertDialog(
      title: const Text('削除できません'),
      content: Text(message),
      actions: [
        TextButton(
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
  String? _selectedId;
  final FocusNode _detailPlayFocusNode = FocusNode(debugLabel: 'titlePlay');

  @override
  void dispose() {
    _detailPlayFocusNode.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final reg = ref.watch(selectedRegistrationProvider);
    return Scaffold(
      appBar: AppBar(
        title: const Text('録画済み'),
        actions: [
          if (reg != null)
            IconButton(
              icon: const Icon(Icons.refresh),
              tooltip: '更新',
              onPressed: () {
                ref.invalidate(titlesProvider(reg));
                ref.invalidate(titleCountsProvider(reg));
              },
            ),
        ],
      ),
      body: reg == null
          ? NoDeviceView(
              onRegister: () =>
                  ref.read(tabIndexProvider.notifier).select(AppTabs.settings),
            )
          : _TitleList(
              reg: reg,
              selectedId: _selectedId,
              detailPlayFocusNode: _detailPlayFocusNode,
              onSelect: (title, twoPane) {
                if (twoPane) {
                  setState(() => _selectedId = title.id);
                  WidgetsBinding.instance.addPostFrameCallback((_) {
                    if (mounted && _detailPlayFocusNode.canRequestFocus) {
                      _detailPlayFocusNode.requestFocus();
                    }
                  });
                } else {
                  Navigator.of(context).push(
                    MaterialPageRoute(
                      builder: (_) =>
                          TitleDetailPage(reg: reg, titleId: title.id),
                    ),
                  );
                }
              },
            ),
    );
  }
}

class _TitleList extends ConsumerStatefulWidget {
  const _TitleList({
    required this.reg,
    required this.selectedId,
    required this.detailPlayFocusNode,
    required this.onSelect,
  });

  final RegisteredNasne reg;
  final String? selectedId;
  final FocusNode detailPlayFocusNode;
  final void Function(RecordedTitle title, bool twoPane) onSelect;

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
    });
  }

  @override
  Widget build(BuildContext context) {
    final reg = widget.reg;
    final progress = ref.watch(titlesProvider(reg));
    final counts = ref.watch(titleCountsProvider(reg)).value;
    // The latest stage of the progressive load (plan 100). A
    // stage is provisional until it is marked complete; during
    // a refresh the previous stage stays on screen, with the
    // loading state saying a newer one is on its way.
    final snapshot = progress.value;
    final allTitles = snapshot?.titles ?? const <RecordedTitle>[];
    final stillLoading =
        snapshot == null || !snapshot.complete || progress.isLoading;
    // A load that failed before completing has nothing sound
    // to show — the error view takes over, as it did when the
    // whole list was one future. A failed *refresh* keeps the
    // complete stage it already had.
    final loadFailed =
        progress.hasError && (snapshot == null || !snapshot.complete);
    final channelChoices = titleChannelChoices(allTitles);
    final genreChoices = titleGenreChoices(allTitles);
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
    final filteredCount = filter.isActive
        ? applyTitleListView(allTitles, filter: filter, sort: _sort).length
        : null;
    return Column(
      children: [
        if (counts != null)
          Padding(
            padding: const EdgeInsets.fromLTRB(16, 12, 16, 0),
            child: Align(
              alignment: Alignment.centerLeft,
              child: Text('全 ${counts.count} 件 (上限 ${counts.max} 件)'),
            ),
          ),
        Padding(
          padding: const EdgeInsets.fromLTRB(16, 8, 16, 0),
          child: TextField(
            controller: _searchController,
            decoration: InputDecoration(
              prefixIcon: const Icon(Icons.search),
              hintText: 'タイトルで検索',
              suffixIcon: _query.isEmpty
                  ? null
                  : IconButton(
                      icon: const Icon(Icons.clear),
                      tooltip: '検索をクリア',
                      onPressed: () => setState(() {
                        _searchController.clear();
                        _query = '';
                      }),
                    ),
            ),
            textInputAction: TextInputAction.search,
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
                if (filter.isActive) ...[
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
                    message: userMessageForError(progress.error!),
                    onRetry: () => ref.invalidate(titlesProvider(reg)),
                  ),
                )
              : snapshot == null
              ? const Padding(
                  padding: EdgeInsets.all(24),
                  child: Center(child: CircularProgressIndicator()),
                )
              : _titleListBody(
                  reg: reg,
                  list: snapshot.titles,
                  stillLoading: stillLoading,
                  filter: filter,
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
    required List<RecordedTitle> list,
    required bool stillLoading,
    required TitleListFilter filter,
  }) {
    if (list.isEmpty) {
      if (stillLoading) {
        return const Center(child: Text('読み込み中…'));
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
    return LayoutBuilder(
      builder: (context, constraints) {
        // The tap behaviour and the pane layout must agree
        // on what "wide" means, so both read the same
        // width: the one this list actually gets. The tap
        // once read the MediaQuery window width while the
        // layout read these constraints, which the shell's
        // navigation rail narrows; in the band between the
        // two (a 1024-wide iPad in landscape, a Split View
        // or Stage Manager window) a tap only updated the
        // selection state — no detail page was pushed and
        // no detail pane existed to show it — so selecting
        // a title appeared to do nothing at all.
        final twoPane = constraints.maxWidth >= twoPaneBreakpoint;
        final listView = ListView.builder(
          itemCount: view.length,
          itemBuilder: (context, i) {
            final t = view[i];
            return ListTile(
              selected: t.id == widget.selectedId,
              leading: _TitleLeading(reg: reg, title: t),
              title: Text(t.title),
              subtitle: Text(
                '${t.scheduledStart != null ? formatDateTimeJst(t.scheduledStart!) : ''}'
                '${t.scheduledDurationSeconds != null ? ' (${formatDurationSeconds(t.scheduledDurationSeconds!)})' : ''}'
                '${t.channelName != null ? ' ${t.channelName}' : ''}',
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
              onTap: () => widget.onSelect(t, twoPane),
              onLongPress: () => deleteRecordedTitle(
                context: context,
                ref: ref,
                reg: reg,
                title: t,
              ),
            );
          },
        );
        if (!twoPane) return listView;
        RecordedTitle? selected;
        for (final t in view) {
          if (t.id == widget.selectedId) selected = t;
        }
        return Row(
          children: [
            Expanded(flex: 5, child: listView),
            const VerticalDivider(thickness: 1, width: 1),
            Expanded(
              flex: 6,
              child: selected == null
                  ? const Center(child: Text('タイトルを選択してください'))
                  : TitleDetailView(
                      reg: reg,
                      title: selected,
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
class _ProtectionRow extends StatelessWidget {
  const _ProtectionRow({required this.protect, required this.onChanged});

  final bool protect;
  final ValueChanged<bool>? onChanged;

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 3),
      child: Row(
        children: [
          SizedBox(
            width: 104,
            child: Text(
              '保護',
              style: Theme.of(context).textTheme.bodyMedium?.copyWith(
                color: Theme.of(context).colorScheme.onSurfaceVariant,
              ),
            ),
          ),
          Expanded(child: Text(protect ? '保護あり' : 'なし')),
          Switch(value: protect, onChanged: onChanged),
        ],
      ),
    );
  }
}

/// Detail page for narrow layouts.
class TitleDetailPage extends ConsumerWidget {
  const TitleDetailPage({super.key, required this.reg, required this.titleId});

  final RegisteredNasne reg;
  final String titleId;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final progress = ref.watch(titlesProvider(reg));
    return Scaffold(
      appBar: AppBar(title: const Text('タイトルの詳細')),
      body: asyncSection(progress.whenData((stage) => stage.titles), (list) {
        for (final t in list) {
          if (t.id == titleId) {
            return TitleDetailView(
              reg: reg,
              title: t,
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
/// truncated so buttons never scroll off-screen. Playback quality is
/// fixed to mobile (falling back when a title has no mobile res).
class TitleDetailView extends ConsumerStatefulWidget {
  const TitleDetailView({
    super.key,
    required this.reg,
    required this.title,
    this.onDeleted,
    this.playFocusNode,
    this.autofocusPlay = false,
  });

  final RegisteredNasne reg;
  final RecordedTitle title;

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

  Future<void> _toggleProtection(bool protect) async {
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
    final channelText = t.channelName ?? channelDisplayName(channels, t.channel);
    final metaParts = <String>[
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
                  Text(
                    t.title,
                    style: Theme.of(context).textTheme.titleLarge,
                    maxLines: 3,
                    overflow: TextOverflow.ellipsis,
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
              Text(
                '画質: モバイル固定',
                style: Theme.of(context).textTheme.bodySmall,
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
    // Always prefer mobile quality on Fire TV.
    final res = title.mobileRes ?? title.originalRes ?? title.res.first;
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
    setState(() => _starting = true);
    try {
      await startPlaybackAndShowPlayer(
        context: context,
        ref: ref,
        start: () => engine.startPlayback(title, res),
        buildPlayer: (session) => PlayerScreen(
          title: title.title,
          session: session,
          initialStart: initialStart,
          // Leaving the player reports where the viewing
          // stopped (plan 102), so the unit's resume point is
          // there for the next viewing — in this app or in
          // the official client — and the loaded list follows
          // the report at once (plan 104 follow-up).
          onResumePosition: (position) => reportResumePosition(
            ref: ref,
            reg: reg,
            titleId: title.id,
            position: position,
          ),
          // The chapter points load as the player opens
          // (plan 112); the service validates them against
          // the listed duration, and an empty answer leaves
          // the player without chapter controls.
          loadChapters: () => ref
              .read(deviceServicesProvider(reg))
              .titles
              .fetchChapters(
                title.id,
                durationSeconds: title.scheduledDurationSeconds ?? 0,
              ),
        ),
        unsupportedSubject: '録画の再生',
      );
    } finally {
      if (mounted) setState(() => _starting = false);
    }
  }
}
