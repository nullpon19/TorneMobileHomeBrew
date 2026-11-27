/// Home / status screen (plan 5.6 item 1): a summary of the selected
/// nasne — device information, HDD usage, live status (now/next
/// programmes and CA/EMM messages), recording failures, network and
/// B-CAS information. Each section fetches independently and offers
/// its own retry; the app bar refresh reloads everything.
library;

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:material_ui/material_ui.dart';

import '../app/providers.dart';
import '../app/state.dart';
import '../core/core.dart';
import 'format.dart';
import 'multi_nasne_policy.dart';
import 'widgets.dart';

class HomeScreen extends ConsumerWidget {
  const HomeScreen({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final registrations = ref.watch(registrationsProvider);
    final selected = ref.watch(selectedRegistrationProvider);

    return Scaffold(
      appBar: AppBar(
        title: const Text('torne mobile HB'),
        actions: [
          if (selected != null)
            IconButton(
              icon: const Icon(Icons.refresh),
              tooltip: '更新',
              onPressed: () {
                final regs =
                    registrations.value ?? const <RegisteredNasne>[];
                if (regs.length > 1) {
                  for (final r in regs) {
                    invalidateDeviceData(ref, r);
                  }
                } else {
                  invalidateDeviceData(ref, selected);
                }
              },
            ),
        ],
      ),
      body: registrations.when(
        loading: () => const LoadingView(),
        error: (e, _) => ErrorView(
          message: '登録情報の読み込みに失敗しました。',
          onRetry: () => ref.read(registrationsProvider.notifier).reload(),
        ),
        data: (list) {
          if (selected == null) {
            return NoDeviceView(
              onRegister: () =>
                  ref.read(tabIndexProvider.notifier).select(AppTabs.settings),
            );
          }
          if (list.length <= 1) {
            return _StatusList(reg: selected);
          }
          return Column(
            children: [
              Padding(
                padding: const EdgeInsets.fromLTRB(12, 8, 12, 4),
                child: list.length <= 4
                    ? SegmentedButton<String>(
                        segments: [
                          for (final r in list)
                            ButtonSegment<String>(
                              value: r.host,
                              label: Text(nasneDisplayLabel(r)),
                            ),
                        ],
                        selected: {selected.host},
                        onSelectionChanged: (sel) => ref
                            .read(selectedHostProvider.notifier)
                            .select(sel.first),
                      )
                    : SingleChildScrollView(
                        scrollDirection: Axis.horizontal,
                        child: Row(
                          children: [
                            for (final r in list)
                              Padding(
                                padding: const EdgeInsets.only(right: 8),
                                child: ChoiceChip(
                                  label: Text(nasneDisplayLabel(r)),
                                  selected: r.host == selected.host,
                                  onSelected: (_) => ref
                                      .read(selectedHostProvider.notifier)
                                      .select(r.host),
                                ),
                              ),
                          ],
                        ),
                      ),
              ),
              Expanded(child: _StatusList(reg: selected)),
            ],
          );
        },
      ),
    );
  }
}

/// Width of the home body at or above which paired sections render side-by-side
/// in equal-height two-column rows (Fire TV / tablet). Narrow screens stack.
const double homeTwoColumnBreakpoint = 600;

class _StatusList extends ConsumerStatefulWidget {
  const _StatusList({required this.reg});

  final RegisteredNasne reg;

  @override
  ConsumerState<_StatusList> createState() => _StatusListState();
}

class _StatusListState extends ConsumerState<_StatusList> {
  final ScrollController _scrollController = ScrollController();

  @override
  void dispose() {
    _scrollController.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final reg = widget.reg;
    return RefreshIndicator(
      onRefresh: () async => invalidateDeviceData(ref, reg),
      child: LayoutBuilder(
        builder: (context, constraints) {
          final twoColumn = constraints.maxWidth >= homeTwoColumnBreakpoint;
          const leftMargin = EdgeInsets.fromLTRB(12, 6, 6, 6);
          const rightMargin = EdgeInsets.fromLTRB(6, 6, 12, 6);
          return ListView(
            controller: _scrollController,
            // Keep all six cards built so D-pad traversal can reach off-screen
            // bottom sections without skipping unbuilt rows.
            scrollCacheExtent: const ScrollCacheExtent.pixels(2000),
            physics: const AlwaysScrollableScrollPhysics(),
            children: [
              if (twoColumn)
                _PairedSectionRow(
                  left: _DeviceSection(
                    reg: reg,
                    margin: leftMargin,
                    scrollController: _scrollController,
                  ),
                  right: _HddSection(
                    reg: reg,
                    margin: rightMargin,
                    scrollController: _scrollController,
                  ),
                )
              else ...[
                _DeviceSection(reg: reg, scrollController: _scrollController),
                _HddSection(reg: reg, scrollController: _scrollController),
              ],
              _LiveSection(reg: reg, scrollController: _scrollController),
              _RecNgSection(reg: reg, scrollController: _scrollController),
              if (twoColumn)
                _PairedSectionRow(
                  left: _NetworkSection(
                    reg: reg,
                    margin: leftMargin,
                    scrollController: _scrollController,
                  ),
                  right: _BcasSection(
                    reg: reg,
                    margin: rightMargin,
                    scrollController: _scrollController,
                  ),
                )
              else ...[
                _NetworkSection(reg: reg, scrollController: _scrollController),
                _BcasSection(reg: reg, scrollController: _scrollController),
              ],
              const SizedBox(height: 12),
            ],
          );
        },
      ),
    );
  }
}

class _PairedSectionRow extends StatelessWidget {
  const _PairedSectionRow({required this.left, required this.right});

  final Widget left;
  final Widget right;

  @override
  Widget build(BuildContext context) {
    return IntrinsicHeight(
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Expanded(child: left),
          Expanded(child: right),
        ],
      ),
    );
  }
}

class _DeviceSection extends ConsumerWidget {
  const _DeviceSection({
    required this.reg,
    this.margin,
    this.scrollController,
  });

  final RegisteredNasne reg;
  final EdgeInsetsGeometry? margin;
  final ScrollController? scrollController;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final info = ref.watch(deviceInfoProvider(reg));
    final softwareUpdate =
        info.value?.updateExists ??
        ref.watch(softwareUpdateAvailableProvider(reg)).value;
    return SectionCard(
      title: '本体情報',
      icon: Icons.router_outlined,
      margin: margin ?? SectionCard.defaultMargin,
      focusable: true,
      scrollController: scrollController,
      child: asyncSection(
        info,
        (d) => Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            FieldRow(label: '名称', value: d.name),
            FieldRow(
              label: 'ソフトウェア',
              value: softwareVersionLabel(d.softwareVersion),
            ),
            if (d.currDate != null) FieldRow(label: '本体時刻', value: d.currDate!),
            if (d.pref != null || d.areaIdentifierCode != null)
              FieldRow(
                label: '地域',
                value: areaLabel(d.areaIdentifierCode, d.pref),
              ),
            FieldRow(label: 'アドレス', value: reg.host),
            if (d.updateExists == true ||
                (d.updateExists == null && softwareUpdate == true))
              const FieldRow(label: '更新', value: 'ソフトウェア更新があります'),
          ],
        ),
        onRetry: () {
          ref.invalidate(deviceInfoProvider(reg));
          ref.invalidate(softwareUpdateAvailableProvider(reg));
        },
      ),
    );
  }
}

class _HddSection extends ConsumerWidget {
  const _HddSection({required this.reg, this.margin, this.scrollController});

  final RegisteredNasne reg;
  final EdgeInsetsGeometry? margin;
  final ScrollController? scrollController;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final hdds = ref.watch(hddDetailsProvider(reg));
    return SectionCard(
      title: 'HDD',
      icon: Icons.storage_outlined,
      margin: margin ?? SectionCard.defaultMargin,
      focusable: true,
      scrollController: scrollController,
      child: asyncSection(
        hdds,
        (list) => Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            for (final detail in list) _HddTile(detail: detail),
            if (list.isEmpty) const Text('HDD が見つかりません'),
          ],
        ),
        onRetry: () => ref.invalidate(hddDetailsProvider(reg)),
      ),
    );
  }
}

class _HddTile extends StatelessWidget {
  const _HddTile({required this.detail});

  final HddDetail detail;

  @override
  Widget build(BuildContext context) {
    final entry = detail.entry;
    final info = detail.info;
    // Drives are told apart by id (id 0 is internal): the list
    // response's internalFlag is inverted from its name, so
    // HddEntry.internal must not drive this label (plan 89.8/116).
    final label = entry.id == 0 ? '内蔵 HDD' : '外付け HDD';
    // An external entry that is not mounted or not registered is
    // shown as not connected, like the official UI, instead of
    // as a detail fetch failure (plan 116).
    if (entry.id != 0 && (!entry.mounted || !entry.registered)) {
      return const Padding(
        padding: EdgeInsets.symmetric(vertical: 4),
        child: Text('外付け HDD (未接続)'),
      );
    }
    if (info == null) {
      return Padding(
        padding: const EdgeInsets.symmetric(vertical: 4),
        child: Text('$label (詳細を取得できませんでした)'),
      );
    }
    final ratio = info.totalBytes > 0 ? info.usedBytes / info.totalBytes : 0.0;
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 6),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(
            info.name.isEmpty ? label : '$label: ${info.name}',
            style: Theme.of(context).textTheme.titleSmall,
          ),
          const SizedBox(height: 6),
          LinearProgressIndicator(value: ratio.clamp(0.0, 1.0)),
          const SizedBox(height: 6),
          Text(
            '空き ${formatBytes(info.freeBytes)} / 全体 ${formatBytes(info.totalBytes)}'
            ' (使用 ${formatBytes(info.usedBytes)})',
          ),
        ],
      ),
    );
  }
}

class _LiveSection extends ConsumerWidget {
  const _LiveSection({required this.reg, this.scrollController});

  final RegisteredNasne reg;
  final ScrollController? scrollController;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final live = ref.watch(liveStatusProvider(reg));
    return SectionCard(
      title: 'ライブ状態',
      icon: Icons.live_tv_outlined,
      focusable: true,
      scrollController: scrollController,
      child: asyncSection(live, (status) {
        final eit = status.eitPf;
        final messages = [...status.caMessages, ...status.emmMessages];
        return Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            if (eit.populated) ...[
              if (eit.present != null)
                FieldRow(label: '現在の番組', value: _programText(eit.present!)),
              if (eit.following != null)
                FieldRow(label: '次の番組', value: _programText(eit.following!)),
            ] else
              const Text('現在・次の番組情報は取得できませんでした'),
            const SizedBox(height: 4),
            if (messages.isEmpty)
              const Text('メッセージはありません')
            else
              for (final m in messages)
                Padding(
                  padding: const EdgeInsets.symmetric(vertical: 2),
                  child: Row(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      const Icon(Icons.warning_amber_outlined, size: 18),
                      const SizedBox(width: 6),
                      Expanded(child: Text(m)),
                    ],
                  ),
                ),
          ],
        );
      }, onRetry: () => ref.invalidate(liveStatusProvider(reg))),
    );
  }

  String _programText(ProgramInfo p) {
    final title = p.title ?? '(番組名なし)';
    if (p.startTime == null) return title;
    return '$title (${formatTimeJst(p.startTime!)})';
  }
}

class _RecNgSection extends ConsumerWidget {
  const _RecNgSection({required this.reg, this.scrollController});

  final RegisteredNasne reg;
  final ScrollController? scrollController;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final recNg = ref.watch(recNgProvider(reg));
    final dismissedKeys = ref.watch(dismissedRecNgKeysProvider);
    return SectionCard(
      title: '録画失敗',
      icon: Icons.videocam_off_outlined,
      focusable: true,
      scrollController: scrollController,
      child: asyncSection(
        recNg,
        (items) {
          final visible = [
            for (final item in items)
              if (!dismissedKeys.contains(recNgDismissKey(reg, item))) item,
          ];
          return visible.isEmpty
              ? const Text('録画失敗はありません')
              : Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    for (final item in visible)
                      Padding(
                        padding: const EdgeInsets.symmetric(vertical: 2),
                        child: Text(
                          '${item.startTime != null ? formatDateTimeJst(item.startTime!) : ''}'
                          ' ${item.title ?? '(タイトルなし)'}',
                        ),
                      ),
                  ],
                );
        },
        onRetry: () => ref.invalidate(recNgProvider(reg)),
      ),
    );
  }
}

class _NetworkSection extends ConsumerWidget {
  const _NetworkSection({
    required this.reg,
    this.margin,
    this.scrollController,
  });

  final RegisteredNasne reg;
  final EdgeInsetsGeometry? margin;
  final ScrollController? scrollController;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final network = ref.watch(networkInfoProvider(reg));
    return SectionCard(
      title: 'ネットワーク',
      icon: Icons.lan_outlined,
      margin: margin ?? SectionCard.defaultMargin,
      focusable: true,
      scrollController: scrollController,
      child: asyncSection(
        network,
        (n) => Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            FieldRow(label: 'IP アドレス', value: n.ipv4Addr),
            if (n.gateway != null) FieldRow(label: 'ゲートウェイ', value: n.gateway!),
            FieldRow(label: 'DHCP', value: n.dhcpEnabled ? '有効' : '無効'),
            FieldRow(label: 'MAC アドレス', value: maskMac(n.macAddr)),
          ],
        ),
        onRetry: () => ref.invalidate(networkInfoProvider(reg)),
      ),
    );
  }
}

class _BcasSection extends ConsumerWidget {
  const _BcasSection({required this.reg, this.margin, this.scrollController});

  final RegisteredNasne reg;
  final EdgeInsetsGeometry? margin;
  final ScrollController? scrollController;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final bcas = ref.watch(bcasInfoProvider(reg));
    return SectionCard(
      title: 'B-CAS',
      icon: Icons.badge_outlined,
      margin: margin ?? SectionCard.defaultMargin,
      focusable: true,
      scrollController: scrollController,
      child: asyncSection(
        bcas,
        (b) => Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            if (b.cardId != null)
              FieldRow(label: 'カード ID', value: maskTail(b.cardId!)),
            if (b.status != null) FieldRow(label: '状態', value: b.status!),
            if (b.info != null) FieldRow(label: '情報', value: b.info!),
            if (b.cardId == null && b.status == null && b.info == null)
              const Text('B-CAS 情報を取得できませんでした'),
          ],
        ),
        onRetry: () => ref.invalidate(bcasInfoProvider(reg)),
      ),
    );
  }
}
