/// Folder browser & DTCP-IP playback view for generic DLNA MediaServers
/// (home-LAN viewing-only support for non-nasne DLNA recorders).
library;

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:material_ui/material_ui.dart';

import '../app/providers.dart';
import '../app/state.dart';
import '../core/core.dart';
import 'app_shell.dart';
import 'epg_title_badges.dart';
import 'error_messages.dart';
import 'format.dart';
import 'playback_launcher.dart';
import 'player_screen.dart';
import 'schedules_screen.dart' show twoPaneBreakpoint;
import 'widgets.dart';

/// Dedicated Settings sub-screen for discovering, manually adding, verifying,
/// and removing generic home-LAN DLNA / DTCP-IP MediaServers.
class DlnaServerSettingsScreen extends ConsumerStatefulWidget {
  const DlnaServerSettingsScreen({super.key});

  @override
  ConsumerState<DlnaServerSettingsScreen> createState() =>
      _DlnaServerSettingsScreenState();
}

class _DlnaServerSettingsScreenState
    extends ConsumerState<DlnaServerSettingsScreen> {
  bool _searching = false;
  List<NasneDevice>? _found;
  String? _searchError;
  bool _registering = false;
  final _manualAddress = TextEditingController();

  @override
  void dispose() {
    _manualAddress.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final dlnaServers = ref.watch(dlnaServersProvider);
    return Scaffold(
      appBar: AppBar(title: const Text('汎用 DLNA / DTCP-IP レコーダー')),
      body: ListView(
        keyboardDismissBehavior: ScrollViewKeyboardDismissBehavior.onDrag,
        padding: const EdgeInsets.all(16),
        children: [
          Text(
            'nasne 以外の DLNA / DTCP-IP 対応レコーダーやメディアサーバーを登録すると、'
            '「録画済み」タブからフォルダ階層をたどって視聴できます（ARIB 字幕・ニコニコ実況過去ログ対応）。\n'
            '※DTCP-IP の 7ms 応答制限のため自宅 LAN 内でご利用ください（視聴専用）。',
            style: Theme.of(context).textTheme.bodySmall,
          ),
          const SizedBox(height: 16),
          Text(
            '登録済みサーバー',
            style: Theme.of(context).textTheme.titleSmall?.copyWith(
              color: Theme.of(context).colorScheme.primary,
            ),
          ),
          const SizedBox(height: 4),
          if (dlnaServers.isEmpty)
            const Padding(
              padding: EdgeInsets.symmetric(vertical: 8),
              child: Text('登録済みの汎用 DLNA レコーダーはありません。'),
            )
          else
            for (final server in dlnaServers)
              ListTile(
                contentPadding: EdgeInsets.zero,
                leading: const Icon(Icons.dns_outlined),
                title: Text(server.friendlyName),
                subtitle: Text(
                  server.modelName.isNotEmpty
                      ? '${server.host} ・ ${server.modelName}'
                      : server.host,
                ),
                trailing: const Icon(Icons.chevron_right),
                onTap: () => _showServerActions(server),
              ),
          const Divider(),
          Text(
            'LAN 内から探す',
            style: Theme.of(context).textTheme.titleSmall?.copyWith(
              color: Theme.of(context).colorScheme.primary,
            ),
          ),
          const SizedBox(height: 8),
          Align(
            alignment: Alignment.centerLeft,
            child: FilledButton.icon(
              onPressed: _searching ? null : _discover,
              icon: const Icon(Icons.search),
              label: Text(
                _searching ? '検索中…' : 'LAN 内の DLNA レコーダーを探す',
              ),
            ),
          ),
          if (_searchError != null) ...[
            const SizedBox(height: 8),
            Text(_searchError!),
          ],
          if (_found != null) ...[
            const SizedBox(height: 8),
            if (_found!.isEmpty)
              const Text('見つかりませんでした。下のアドレス指定をお試しください。')
            else
              for (final device in _found!)
                ListTile(
                  contentPadding: EdgeInsets.zero,
                  leading: const Icon(Icons.router_outlined),
                  title: Text(
                    device.friendlyName.isNotEmpty
                        ? device.friendlyName
                        : device.host,
                  ),
                  subtitle: Text(
                    device.modelName.isNotEmpty
                        ? '${device.host} ・ ${device.modelName}'
                        : device.host,
                  ),
                  trailing: FilledButton.tonal(
                    onPressed: _registering
                        ? null
                        : () => _registerDevice(device),
                    child: const Text('登録'),
                  ),
                ),
          ],
          const Divider(),
          Text(
            '手動登録',
            style: Theme.of(context).textTheme.titleSmall?.copyWith(
              color: Theme.of(context).colorScheme.primary,
            ),
          ),
          const SizedBox(height: 8),
          FireTvTextInputField(
            controller: _manualAddress,
            labelText: 'レコーダーの IP アドレス / 説明 XML URL',
            hintText: '192.168.0.100 または http://...:20003/description.xml',
            dialogTitle: 'DLNA レコーダーのアドレス',
            keyboardType: TextInputType.url,
          ),
          const SizedBox(height: 8),
          Align(
            alignment: Alignment.centerLeft,
            child: FilledButton.tonalIcon(
              onPressed: _registering ? null : _registerManual,
              icon: const Icon(Icons.add),
              label: const Text('DLNA レコーダーを登録'),
            ),
          ),
        ],
      ),
    );
  }

  Future<void> _discover() async {
    setState(() {
      _searching = true;
      _searchError = null;
    });
    try {
      final found = await ref
          .read(dlnaDiscoveryProvider)
          .discoverDlnaServers();
      if (!mounted) return;
      setState(() {
        _searching = false;
        _found = found;
      });
    } on NasneError catch (e) {
      if (!mounted) return;
      setState(() {
        _searching = false;
        _searchError = userMessageForError(e);
      });
    } catch (e) {
      if (!mounted) return;
      setState(() {
        _searching = false;
        _searchError = '検索できませんでした: $e';
      });
    }
  }

  Future<void> _registerDevice(NasneDevice device) async {
    setState(() => _registering = true);
    try {
      final server = RegisteredDlnaServer.fromDevice(device);
      await ref.read(dlnaServersProvider.notifier).addOrReplace(server);
      if (!mounted) return;
      showSnack(context, '登録しました: ${server.friendlyName}');
    } catch (e) {
      if (!mounted) return;
      showSnack(context, '登録できませんでした: $e');
    } finally {
      if (mounted) setState(() => _registering = false);
    }
  }

  Future<void> _registerManual() async {
    FocusScope.of(context).unfocus();
    final input = _manualAddress.text.trim();
    if (input.isEmpty) {
      showSnack(context, 'アドレスを入力してください');
      return;
    }
    setState(() => _registering = true);
    try {
      final device = await ref
          .read(dlnaDiscoveryProvider)
          .probeDlnaServerAddress(input);
      if (!mounted) return;
      final server = RegisteredDlnaServer.fromDevice(device);
      await ref.read(dlnaServersProvider.notifier).addOrReplace(server);
      if (!mounted) return;
      _manualAddress.clear();
      showSnack(context, '登録しました: ${server.friendlyName}');
    } on NasneError catch (e) {
      if (!mounted) return;
      showSnack(context, userMessageForError(e));
    } catch (e) {
      if (!mounted) return;
      showSnack(context, '登録できませんでした: $e');
    } finally {
      if (mounted) setState(() => _registering = false);
    }
  }

  Future<void> _showServerActions(RegisteredDlnaServer server) async {
    final action = await showDialog<String>(
      context: context,
      builder: (dialogContext) => AlertDialog(
        title: Text(server.friendlyName),
        contentPadding: const EdgeInsets.fromLTRB(12, 12, 12, 4),
        content: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            ListTile(
              autofocus: true,
              leading: const Icon(Icons.verified_outlined),
              title: const Text('接続を確認'),
              onTap: () => Navigator.of(dialogContext).pop('verify'),
            ),
            ListTile(
              leading: const Icon(Icons.delete_outline),
              title: const Text('登録を解除'),
              onTap: () => Navigator.of(dialogContext).pop('remove'),
            ),
          ],
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(dialogContext).pop(),
            child: const Text('閉じる'),
          ),
        ],
      ),
    );
    if (!mounted || action == null) return;
    switch (action) {
      case 'verify':
        try {
          final doc = await DlnaMetadataService(
            soap: SoapTransport(client: ref.read(httpClientProvider)),
            controlUrl: Uri.parse(server.contentDirectoryControlUrl),
          ).browse('0');
          if (!mounted) return;
          showSnack(
            context,
            '接続 OK: ${doc.containers.length} フォルダ / ${doc.items.length} 件',
          );
        } on NasneError catch (e) {
          if (!mounted) return;
          showSnack(context, userMessageForError(e));
        } catch (e) {
          if (!mounted) return;
          showSnack(context, '接続できませんでした: $e');
        }
      case 'remove':
        final ok = await confirmDialog(
          context,
          title: '登録を解除',
          message: '${server.friendlyName} (${server.host}) の登録を解除しますか？',
          confirmLabel: '解除',
        );
        if (!ok || !mounted) return;
        await ref.read(dlnaServersProvider.notifier).remove(server.id);
        if (!mounted) return;
        showSnack(context, '登録を解除しました');
    }
  }
}

class _DlnaFolderCrumb {
  const _DlnaFolderCrumb({required this.id, required this.title});

  final String id;
  final String title;
}

class DlnaBrowserView extends ConsumerStatefulWidget {
  const DlnaBrowserView({
    super.key,
    required this.server,
    this.enableTabBackHandler = true,
  });

  final RegisteredDlnaServer server;
  final bool enableTabBackHandler;

  @override
  ConsumerState<DlnaBrowserView> createState() => _DlnaBrowserViewState();
}

class _DlnaBrowserViewState extends ConsumerState<DlnaBrowserView> {
  late List<_DlnaFolderCrumb> _stack;
  DidlItem? _selectedItem;
  late final Map<int, bool Function()> _tabBackHandlers;

  @override
  void initState() {
    super.initState();
    _stack = [
      _DlnaFolderCrumb(id: '0', title: widget.server.friendlyName),
    ];
    _tabBackHandlers = ref.read(tabBackHandlersProvider);
    if (widget.enableTabBackHandler) {
      _tabBackHandlers[AppTabs.titles] = _handleBackKey;
    }
  }

  @override
  void didUpdateWidget(covariant DlnaBrowserView oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.server.id != widget.server.id) {
      _stack = [
        _DlnaFolderCrumb(id: '0', title: widget.server.friendlyName),
      ];
      _selectedItem = null;
    }
  }

  @override
  void dispose() {
    if (widget.enableTabBackHandler &&
        identical(_tabBackHandlers[AppTabs.titles], _handleBackKey)) {
      _tabBackHandlers.remove(AppTabs.titles);
    }
    super.dispose();
  }

  bool _handleBackKey() {
    if (_stack.length <= 1) return false;
    _popFolder();
    return true;
  }

  void _enterFolder(DidlContainer folder) {
    setState(() {
      _stack = [
        ..._stack,
        _DlnaFolderCrumb(
          id: folder.id,
          title: folder.title.isEmpty ? folder.id : folder.title,
        ),
      ];
      _selectedItem = null;
    });
  }

  void _popFolder() {
    if (_stack.length <= 1) return;
    setState(() {
      _stack = _stack.sublist(0, _stack.length - 1);
      _selectedItem = null;
    });
  }

  void _popToIndex(int index) {
    if (index < 0 || index >= _stack.length) return;
    setState(() {
      _stack = _stack.sublist(0, index + 1);
      _selectedItem = null;
    });
  }

  @override
  Widget build(BuildContext context) {
    final current = _stack.last;
    final req = (
      controlUrl: widget.server.contentDirectoryControlUrl,
      objectId: current.id,
    );
    final browseAsync = ref.watch(dlnaBrowseProvider(req));
    final width = MediaQuery.sizeOf(context).width;
    final twoPane = width >= twoPaneBreakpoint;

    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Padding(
          padding: const EdgeInsets.fromLTRB(16, 8, 12, 4),
          child: Row(
            children: [
              if (_stack.length > 1)
                IconButton(
                  icon: const Icon(Icons.arrow_back),
                  tooltip: '一つ上のフォルダへ',
                  onPressed: _popFolder,
                ),
              Expanded(
                child: SingleChildScrollView(
                  scrollDirection: Axis.horizontal,
                  child: Row(
                    children: [
                      for (var i = 0; i < _stack.length; i++) ...[
                        if (i > 0)
                          const Icon(
                            Icons.chevron_right,
                            size: 16,
                            color: Colors.grey,
                          ),
                        TextButton(
                          onPressed: i < _stack.length - 1
                              ? () => _popToIndex(i)
                              : null,
                          child: Text(
                            _stack[i].title,
                            style: TextStyle(
                              fontWeight: i == _stack.length - 1
                                  ? FontWeight.bold
                                  : FontWeight.normal,
                            ),
                          ),
                        ),
                      ],
                    ],
                  ),
                ),
              ),
              IconButton(
                icon: const Icon(Icons.refresh),
                tooltip: 'このフォルダを更新',
                onPressed: () => ref.invalidate(dlnaBrowseProvider(req)),
              ),
            ],
          ),
        ),
        const Divider(height: 1),
        Expanded(
          child: browseAsync.when(
            loading: () => const Center(child: CircularProgressIndicator()),
            error: (e, _) => ErrorView(
              message: userMessageForError(e),
              onRetry: () => ref.invalidate(dlnaBrowseProvider(req)),
            ),
            data: (doc) {
              final playableItems = [
                for (final item in doc.items)
                  if (item.res.any(isPlayableVideoRes)) item,
              ];
              if (doc.containers.isEmpty && playableItems.isEmpty) {
                return Center(
                  child: Padding(
                    padding: const EdgeInsets.all(24),
                    child: Column(
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        const Icon(Icons.folder_open_outlined, size: 48),
                        const SizedBox(height: 12),
                        const Text('このフォルダには再生可能な番組がありません'),
                        if (_stack.length > 1) ...[
                          const SizedBox(height: 12),
                          FilledButton.tonalIcon(
                            onPressed: _popFolder,
                            icon: const Icon(Icons.arrow_upward),
                            label: const Text('一つ上へ'),
                          ),
                        ],
                      ],
                    ),
                  ),
                );
              }

              final list = RefreshIndicator(
                onRefresh: () async {
                  ref.invalidate(dlnaBrowseProvider(req));
                  await ref.read(dlnaBrowseProvider(req).future);
                },
                child: ListView(
                  children: [
                    for (final c in doc.containers)
                      ListTile(
                        leading: Icon(
                          Icons.folder,
                          color: Theme.of(context).colorScheme.primary,
                        ),
                        title: Text(c.title.isEmpty ? c.id : c.title),
                        trailing: Row(
                          mainAxisSize: MainAxisSize.min,
                          children: [
                            if (c.childCount != null)
                              Text(
                                '${c.childCount} 件',
                                style: Theme.of(context).textTheme.bodySmall,
                              ),
                            const SizedBox(width: 4),
                            const Icon(Icons.chevron_right),
                          ],
                        ),
                        onTap: () => _enterFolder(c),
                      ),
                    for (final item in playableItems)
                      _DlnaItemTile(
                        item: item,
                        selected: twoPane && _selectedItem?.id == item.id,
                        onTap: () {
                          if (twoPane) {
                            setState(() => _selectedItem = item);
                          } else {
                            Navigator.of(context).push(
                              MaterialPageRoute<void>(
                                builder: (_) => _DlnaItemDetailPage(
                                  server: widget.server,
                                  item: item,
                                ),
                              ),
                            );
                          }
                        },
                      ),
                  ],
                ),
              );

              if (!twoPane) return list;
              final active =
                  _selectedItem != null &&
                      playableItems.any((i) => i.id == _selectedItem!.id)
                  ? _selectedItem!
                  : (playableItems.isNotEmpty ? playableItems.first : null);
              return Row(
                children: [
                  Expanded(flex: 3, child: list),
                  const VerticalDivider(width: 1),
                  Expanded(
                    flex: 4,
                    child: active == null
                        ? const Center(child: Text('フォルダまたは番組を選択してください'))
                        : _DlnaItemDetailBody(
                            server: widget.server,
                            item: active,
                          ),
                  ),
                ],
              );
            },
          ),
        ),
      ],
    );
  }
}

class _DlnaItemTile extends StatelessWidget {
  const _DlnaItemTile({
    required this.item,
    required this.selected,
    required this.onTap,
  });

  final DidlItem item;
  final bool selected;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final recorded = dlnaItemToRecordedTitle(item);
    final metaParts = <String>[
      if (recorded.scheduledStart != null)
        formatDateTimeJst(recorded.scheduledStart!),
      if (recorded.scheduledDurationSeconds != null)
        formatDurationSeconds(recorded.scheduledDurationSeconds!),
      if (recorded.channelName != null && recorded.channelName!.isNotEmpty)
        recorded.channelName!,
    ];
    return ListTile(
      selected: selected,
      leading: const Icon(Icons.play_circle_outline),
      title: BroadcastTitleLine(
        rawTitle: recorded.title.isEmpty ? item.id : recorded.title,
        maxLines: 2,
      ),
      subtitle: metaParts.isNotEmpty ? Text(metaParts.join(' ・ ')) : null,
      trailing: const Icon(Icons.chevron_right),
      onTap: onTap,
    );
  }
}

class _DlnaItemDetailPage extends StatelessWidget {
  const _DlnaItemDetailPage({required this.server, required this.item});

  final RegisteredDlnaServer server;
  final DidlItem item;

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: Text(server.friendlyName)),
      body: _DlnaItemDetailBody(server: server, item: item),
    );
  }
}

class _DlnaItemDetailBody extends ConsumerStatefulWidget {
  const _DlnaItemDetailBody({required this.server, required this.item});

  final RegisteredDlnaServer server;
  final DidlItem item;

  @override
  ConsumerState<_DlnaItemDetailBody> createState() =>
      _DlnaItemDetailBodyState();
}

class _DlnaItemDetailBodyState extends ConsumerState<_DlnaItemDetailBody> {
  int _selectedResIndex = 0;
  bool _starting = false;

  @override
  void didUpdateWidget(covariant _DlnaItemDetailBody oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.item.id != widget.item.id) {
      _selectedResIndex = 0;
    }
  }

  @override
  Widget build(BuildContext context) {
    final title = dlnaItemToRecordedTitle(widget.item);
    final resources = title.res;
    final resIdx = _selectedResIndex.clamp(0, resources.length - 1);
    final detailBody = formatProgramDetailBody(
      description: title.description,
      longDescription: title.longDescription,
    );
    final metaParts = <String>[
      if (title.scheduledStart != null)
        formatDateTimeWithWeekdayJst(title.scheduledStart!),
      if (title.scheduledDurationSeconds != null)
        formatDurationSeconds(title.scheduledDurationSeconds!),
      if (title.channelName != null && title.channelName!.isNotEmpty)
        title.channelName!,
      if (title.genre != null && title.genre!.isNotEmpty) title.genre!,
    ];

    return SingleChildScrollView(
      padding: const EdgeInsets.all(20),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          BroadcastTitleLine(
            rawTitle: title.title,
            maxLines: 3,
            style: Theme.of(context).textTheme.headlineSmall,
          ),
          if (metaParts.isNotEmpty) ...[
            const SizedBox(height: 8),
            Text(
              metaParts.join(' ・ '),
              style: Theme.of(context).textTheme.bodyMedium?.copyWith(
                color: Theme.of(context).colorScheme.onSurfaceVariant,
              ),
            ),
          ],
          if (resources.length > 1) ...[
            const SizedBox(height: 12),
            Wrap(
              spacing: 8,
              runSpacing: 8,
              children: [
                for (var i = 0; i < resources.length; i++)
                  ChoiceChip(
                    label: Text(
                      resources[i].quality != null &&
                              resources[i].quality!.isNotEmpty
                          ? resources[i].quality!
                          : 'ストリーム ${i + 1}',
                    ),
                    selected: i == resIdx,
                    onSelected: (_) => setState(() => _selectedResIndex = i),
                  ),
              ],
            ),
          ],
          const SizedBox(height: 16),
          FilledButton.icon(
            autofocus: true,
            onPressed: _starting || resources.isEmpty
                ? null
                : () => _play(title, resources[resIdx]),
            icon: Icon(_starting ? Icons.hourglass_top : Icons.play_arrow),
            label: Text(_starting ? '再生準備中…' : '再生'),
          ),
          if (detailBody != null && detailBody.isNotEmpty) ...[
            const SizedBox(height: 20),
            const Divider(),
            const SizedBox(height: 12),
            Text(detailBody, style: Theme.of(context).textTheme.bodyMedium),
          ],
        ],
      ),
    );
  }

  Future<void> _play(RecordedTitle title, TitleRes res) async {
    if (_starting) return;
    final engine = ref.read(playbackEngineProvider);
    final metaParts = <String>[
      if (title.scheduledStart != null)
        formatDateTimeWithWeekdayJst(title.scheduledStart!),
      if (title.scheduledDurationSeconds != null)
        formatDurationSeconds(title.scheduledDurationSeconds!),
      if (title.channelName != null && title.channelName!.isNotEmpty)
        title.channelName!,
      if (title.genre != null && title.genre!.isNotEmpty) title.genre!,
    ];
    final detailMeta = metaParts.isEmpty ? null : metaParts.join(' ・ ');
    final detailBody = formatProgramDetailBody(
      description: title.description,
      longDescription: title.longDescription,
    );
    final broadcastRange = title.scheduledStart != null
        ? formatRecordedBroadcastTimeRangeJst(
            title.scheduledStart!,
            title.scheduledDurationSeconds,
          )
        : null;

    setState(() => _starting = true);
    try {
      await startPlaybackAndShowPlayer(
        context: context,
        ref: ref,
        start: () => engine.startPlayback(title, res),
        buildPlayer: (session) => PlayerScreen(
          title: title.title,
          session: session,
          knownDuration:
              res.duration ??
              (title.scheduledDurationSeconds != null
                  ? Duration(seconds: title.scheduledDurationSeconds!)
                  : null),
          recordedChannelName: title.channelName,
          recordedBroadcastTimeRange: broadcastRange,
          recordedScheduledStart: title.scheduledStart,
          recordedBroadcastingType: title.channel?.broadcastingType,
          programDetailTitle: title.title,
          programDetailMeta: detailMeta,
          programDetailBody: detailBody,
          currentUseMobile: res.quality == 'mobile',
        ),
        unsupportedSubject: '録画の再生',
      );
    } finally {
      if (mounted) setState(() => _starting = false);
    }
  }
}
