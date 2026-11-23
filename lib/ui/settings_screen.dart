/// Settings screen (plan 5.6 item 4): registration management only —
/// SSDP discovery, manual address registration (both verified by
/// PINVerify through the RegistrationService), re-verification, and
/// unregistration. Device settings themselves are out of the v1
/// scope (plan 1.2).
library;

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:material_ui/material_ui.dart';

import '../app/debug_log.dart';
import '../app/log_folder.dart';
import '../app/log_share.dart';
import '../app/providers.dart';
import '../app/state.dart';
import '../app/store_directory.dart';
import '../core/core.dart';
import 'dtcp_credential_screen.dart';
import 'epg_hidden_genres_screen.dart';
import 'error_messages.dart';
import 'format.dart';
import 'player_cache_policy.dart';
import 'widgets.dart';

class SettingsScreen extends ConsumerStatefulWidget {
  const SettingsScreen({super.key});

  @override
  ConsumerState<SettingsScreen> createState() => _SettingsScreenState();
}

class _SettingsScreenState extends ConsumerState<SettingsScreen> {
  bool _searching = false;
  List<NasneDevice>? _found;
  String? _searchError;
  bool _registering = false;
  bool _sharingLogs = false;
  bool _openingLogFolder = false;
  final _manualHost = TextEditingController();

  @override
  void dispose() {
    _manualHost.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final registrations = ref.watch(registrationsProvider);
    final selected = ref.watch(selectedRegistrationProvider);
    final debugSettings = ref.watch(debugSettingsProvider);
    final storeDir = ref.watch(storeDirectoryProvider);
    final recordedBufferSeconds = ref.watch(recordedBufferSecondsProvider);
    final liveBufferSeconds = ref.watch(liveBufferSecondsProvider);
    return Scaffold(
      appBar: AppBar(title: const Text('設定')),
      body: ListView(
        keyboardDismissBehavior: ScrollViewKeyboardDismissBehavior.onDrag,
        children: [
          _sectionTitle(context, '登録済み nasne'),
          registrations.when(
            loading: () => const Padding(
              padding: EdgeInsets.all(24),
              child: Center(child: CircularProgressIndicator()),
            ),
            error: (e, _) => Padding(
              padding: const EdgeInsets.all(16),
              child: Text(userMessageForError(e)),
            ),
            data: (list) => Column(
              children: [
                if (list.isEmpty)
                  const Padding(
                    padding: EdgeInsets.all(16),
                    child: Text('登録済みの nasne はありません。下の「探す」か手動登録で追加してください。'),
                  ),
                for (final reg in list)
                  ListTile(
                    leading: Icon(
                      selected?.host == reg.host
                          ? Icons.radio_button_checked
                          : Icons.radio_button_unchecked,
                    ),
                    title: Text(reg.friendlyName),
                    subtitle: Text('${reg.host}\nMAC ${maskMac(reg.macAddr)}'),
                    isThreeLine: true,
                    trailing: PopupMenuButton<String>(
                      onSelected: (action) =>
                          _onRegistrationAction(action, reg),
                      itemBuilder: (context) => [
                        if (selected?.host != reg.host)
                          const PopupMenuItem(
                            value: 'select',
                            child: Text('この nasne を使う'),
                          ),
                        const PopupMenuItem(
                          value: 'verify',
                          child: Text('登録を検証'),
                        ),
                        const PopupMenuItem(
                          value: 'remove',
                          child: Text('登録を解除'),
                        ),
                      ],
                    ),
                  ),
              ],
            ),
          ),
          const Divider(),
          _sectionTitle(context, 'nasne を探す'),
          Padding(
            padding: const EdgeInsets.symmetric(horizontal: 16),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                FilledButton.icon(
                  onPressed: _searching ? null : _discover,
                  icon: const Icon(Icons.search),
                  label: Text(_searching ? '検索中…' : 'LAN 内の nasne を探す'),
                ),
                if (_searchError != null) ...[
                  const SizedBox(height: 8),
                  Text(_searchError!),
                  const SizedBox(height: 12),
                  const DiscoveryChecklist(),
                ],
                if (_found != null) ...[
                  const SizedBox(height: 8),
                  if (_found!.isEmpty)
                    Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        const Text('見つかりませんでした。'),
                        const SizedBox(height: 12),
                        const DiscoveryChecklist(),
                        const SizedBox(height: 12),
                        FilledButton.tonal(
                          onPressed: _searching ? null : _discover,
                          child: const Text('もう一度探す'),
                        ),
                        const SizedBox(height: 8),
                        const Text('それでも見つからない場合は、下の手動登録も使えます。'),
                      ],
                    )
                  else
                    for (final device in _found!)
                      ListTile(
                        contentPadding: EdgeInsets.zero,
                        leading: const Icon(Icons.tv_outlined),
                        title: Text(device.friendlyName),
                        subtitle: Text(device.host),
                        trailing: FilledButton.tonal(
                          onPressed: _registering
                              ? null
                              : () => _registerDevice(device),
                          child: const Text('登録'),
                        ),
                      ),
                ],
              ],
            ),
          ),
          const Divider(),
          _sectionTitle(context, '手動登録'),
          Padding(
            padding: const EdgeInsets.symmetric(horizontal: 16),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                TextField(
                  controller: _manualHost,
                  decoration: const InputDecoration(
                    labelText: 'IP アドレス / ホスト名',
                    hintText: '192.168.11.129',
                  ),
                  keyboardType: TextInputType.url,
                  textInputAction: TextInputAction.done,
                  onSubmitted: (_) => FocusScope.of(context).unfocus(),
                ),
                const SizedBox(height: 8),
                FilledButton.icon(
                  onPressed: _registering ? null : _registerManual,
                  icon: const Icon(Icons.add),
                  label: const Text('登録'),
                ),
              ],
            ),
          ),
          const Divider(),
          _sectionTitle(context, '番組表'),
          SwitchListTile(
            title: const Text('サブチャンネルを表示'),
            subtitle: const Text('番組表にサブチャンネル (2 / 3 チャンネル) を含めます'),
            value: ref.watch(showSubchannelsProvider),
            onChanged: (value) =>
                ref.read(showSubchannelsProvider.notifier).set(value),
          ),
          ListTile(
            title: const Text('見ないジャンル'),
            subtitle: const Text('選んだジャンルの番組は番組表で空白表示になります'),
            trailing: const Icon(Icons.chevron_right),
            onTap: () => Navigator.push(
              context,
              MaterialPageRoute<void>(
                builder: (_) => const EpgHiddenGenresScreen(),
              ),
            ),
          ),
          const Divider(),
          _sectionTitle(context, '再生'),
          Padding(
            padding: const EdgeInsets.symmetric(horizontal: 16),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  '再生画質: モバイル固定',
                  style: Theme.of(context).textTheme.titleSmall,
                ),
                const SizedBox(height: 6),
                Text(
                  'Fire TV 版では安定再生のため、TV 視聴・録画再生ともに常にモバイル画質を使用します'
                  '（モバイル画質が存在しない番組のみ元画質にフォールバックします）。',
                  style: Theme.of(context).textTheme.bodySmall,
                ),
              ],
            ),
          ),
          const SizedBox(height: 8),
          ListTile(
            title: const Text('録画のバッファ時間（先読み）'),
            subtitle: Text(
              '設定: ${formatBufferDurationLabel(recordedBufferSeconds)} '
              '（1分以上は内蔵ストレージ一時キャッシュを使用・最大60分。'
              '30〜60分はモバイル回線のギガ消費にご注意ください）',
            ),
            trailing: Row(
              mainAxisSize: MainAxisSize.min,
              children: [
                Text(
                  formatBufferDurationLabel(recordedBufferSeconds),
                  style: Theme.of(context).textTheme.labelLarge,
                ),
                const SizedBox(width: 4),
                const Icon(Icons.chevron_right),
              ],
            ),
            onTap: () => _pickBufferDuration(
              title: '録画のバッファ時間（先読み）',
              description:
                  '再生をすぐ始めつつ、裏で設定時間分まで先読みします（1分以上はストレージ一時保存、最低512MB空き残存）。',
              options: recordedBufferOptionsSeconds,
              current: recordedBufferSeconds,
              recommendedSeconds: defaultRecordedBufferSeconds,
              onSelected: (value) =>
                  ref.read(recordedBufferSecondsProvider.notifier).set(value),
            ),
          ),
          ListTile(
            title: const Text('Live のバッファ時間（遅延再生）'),
            subtitle: Text(
              '設定: ${formatBufferDurationLabel(liveBufferSeconds)} '
              '（開始前に設定秒数分を蓄積して途切れを防ぎます。'
              '15秒以上では副音声切替が効きにくくなる場合があります）',
            ),
            trailing: Row(
              mainAxisSize: MainAxisSize.min,
              children: [
                Text(
                  formatBufferDurationLabel(liveBufferSeconds),
                  style: Theme.of(context).textTheme.labelLarge,
                ),
                const SizedBox(width: 4),
                const Icon(Icons.chevron_right),
              ],
            ),
            onTap: () => _pickBufferDuration(
              title: 'Live のバッファ時間（遅延再生）',
              description:
                  'radiko のように再生開始前に指定時間分を貯めてから流し、トンネルや短い圏外での途切れを防ぎます。',
              options: liveBufferOptionsSeconds,
              current: liveBufferSeconds,
              onSelected: (value) =>
                  ref.read(liveBufferSecondsProvider.notifier).set(value),
            ),
          ),
          const Divider(),
          _sectionTitle(context, '録画再生 (DTCP-IP)'),
          ListTile(
            title: const Text('DTCP-IP 資格情報'),
            subtitle: Text(
              ref
                  .watch(credentialSummaryProvider)
                  .when(
                    data: (summary) =>
                        summary == null ? '未インポート (再生には資格情報が必要です)' : 'インポート済み',
                    loading: () => '確認中…',
                    error: (_, _) => '読み込みエラー',
                  ),
            ),
            trailing: const Icon(Icons.chevron_right),
            onTap: () => Navigator.push(
              context,
              MaterialPageRoute<void>(
                builder: (_) => const DtcpCredentialScreen(),
              ),
            ),
          ),
          const Divider(),
          _sectionTitle(context, 'デバッグ'),
          SwitchListTile(
            title: const Text('デバッグモード'),
            subtitle: const Text(
              '診断ログを端末内のファイルに保存します (ステージ遷移・応答コード・所要時間のみ。'
              '資格情報やセッション鍵は記録されません)',
            ),
            value: debugSettings.master,
            onChanged: (value) =>
                ref.read(debugSettingsProvider.notifier).setMaster(value),
          ),
          if (debugSettings.master) ...[
            for (final category in DiagCategory.values)
              SwitchListTile(
                title: Text(diagCategoryLabel(category)),
                value: debugSettings.categories.contains(category),
                onChanged: (value) => ref
                    .read(debugSettingsProvider.notifier)
                    .setCategory(category, value),
              ),
            if (storeDir != null)
              Padding(
                padding: const EdgeInsets.fromLTRB(16, 4, 16, 8),
                child: Text(
                  '保存先: ${storeDir.path}/debug_logs/',
                  style: Theme.of(context).textTheme.bodySmall,
                ),
              ),
          ],
          // Sharing stays available with the master switch off:
          // the logs that matter are usually already recorded by
          // the time the user comes here to send them (plan 46).
          // Desktop has no share sheet to send them through;
          // there the same slot opens the log folder in the file
          // manager instead (plan 71).
          if (storeDir != null)
            if (isDesktopStorePlatform)
              ListTile(
                leading: const Icon(Icons.folder_open),
                title: const Text('ログフォルダを開く'),
                subtitle: const Text('保存済みの診断ログのフォルダをファイルマネージャで開きます'),
                enabled: !_openingLogFolder,
                onTap: _openingLogFolder ? null : _openLogFolder,
              )
            else
              Builder(
                builder: (tileContext) => ListTile(
                  leading: const Icon(Icons.share),
                  title: const Text('デバッグログを共有'),
                  subtitle: const Text('保存済みの診断ログファイルを共有シートで送ります'),
                  enabled: !_sharingLogs,
                  onTap: _sharingLogs
                      ? null
                      : () => _shareDebugLogs(tileContext),
                ),
              ),
          const Divider(),
          const Padding(
            padding: EdgeInsets.all(16),
            child: Text(
              '発見にはローカルネットワークへのアクセス許可が必要です (iOS では許可ダイアログが'
              '表示される場合があります)。発見できない環境では手動登録を使ってください。\n\n'
              'torne mobile HB $appVersionLabel',
            ),
          ),
        ],
      ),
    );
  }

  Widget _sectionTitle(BuildContext context, String text) {
    return Padding(
      padding: const EdgeInsets.fromLTRB(16, 16, 16, 4),
      child: Text(text, style: Theme.of(context).textTheme.titleMedium),
    );
  }

  /// Shares the recorded debug logs via the OS share sheet
  /// (plan 46). The tile's global rect anchors the iPad popover
  /// presentation; Android ignores it.
  Future<void> _shareDebugLogs(BuildContext tileContext) async {
    final sharer = ref.read(debugLogSharerProvider);
    if (sharer == null || _sharingLogs) return;
    Rect? origin;
    final renderObject = tileContext.findRenderObject();
    if (renderObject is RenderBox && renderObject.hasSize) {
      origin = renderObject.localToGlobal(Offset.zero) & renderObject.size;
    }
    setState(() => _sharingLogs = true);
    try {
      final outcome = await sharer.share(origin: origin);
      ref.read(diagLogProvider)(
        DiagCategory.ui,
        'debug log share: outcome=${outcome.name}',
      );
      if (!mounted) return;
      final message = switch (outcome) {
        DebugLogShareOutcome.noLogs => '共有できるログがありません',
        DebugLogShareOutcome.unsupported => 'このプラットフォームではログを共有できません',
        DebugLogShareOutcome.shared => null,
      };
      if (message != null) {
        ScaffoldMessenger.of(context)
            .showSnackBar(SnackBar(content: Text(message)));
      }
    } catch (_) {
      if (!mounted) return;
      ScaffoldMessenger.of(context)
          .showSnackBar(const SnackBar(content: Text('ログの共有に失敗しました')));
    } finally {
      if (mounted) setState(() => _sharingLogs = false);
    }
  }

  /// Opens the debug log folder in the desktop file manager
  /// (plan 71), the desktop counterpart of the share action.
  /// Failures are shown, not swallowed: a tap that silently does
  /// nothing is exactly how the picker failure in plan 69
  /// presented itself.
  Future<void> _openLogFolder() async {
    final opener = ref.read(debugLogFolderOpenerProvider);
    if (opener == null || _openingLogFolder) return;
    setState(() => _openingLogFolder = true);
    try {
      final outcome = await opener.open();
      ref.read(diagLogProvider)(
        DiagCategory.ui,
        'debug log folder open: outcome=${outcome.name}',
      );
      if (!mounted) return;
      if (outcome == DebugLogFolderOpenOutcome.unsupported) {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(content: Text('このプラットフォームではログフォルダを開けません')),
        );
      }
    } catch (e) {
      ref.read(diagLogProvider)(
        DiagCategory.ui,
        'debug log folder open failed: $e',
      );
      if (!mounted) return;
      ScaffoldMessenger.of(context)
          .showSnackBar(const SnackBar(content: Text('ログフォルダを開けませんでした')));
    } finally {
      if (mounted) setState(() => _openingLogFolder = false);
    }
  }

  Future<void> _discover() async {
    setState(() {
      _searching = true;
      _searchError = null;
    });
    try {
      final found = await ref.read(discoveryServiceProvider).discover();
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
    }
  }

  Future<void> _registerDevice(NasneDevice device) async {
    setState(() => _registering = true);
    try {
      final registration = await ref
          .read(registrationServiceProvider)
          .register(device);
      await ref.read(registrationsProvider.notifier).add(registration);
      await ref.read(selectedHostProvider.notifier).select(registration.host);
      if (!mounted) return;
      showSnack(context, '登録しました: ${registration.host}');
    } on NasneError catch (e) {
      if (!mounted) return;
      showSnack(context, userMessageForError(e));
    } finally {
      if (mounted) setState(() => _registering = false);
    }
  }

  Future<void> _registerManual() async {
    FocusScope.of(context).unfocus();
    final host = _manualHost.text.trim();
    if (host.isEmpty) {
      showSnack(context, 'アドレスを入力してください');
      return;
    }
    setState(() => _registering = true);
    NasneDevice device;
    try {
      device = await ref
          .read(discoveryServiceProvider)
          .describe(Uri(scheme: 'http', host: host, port: 58888, path: '/'));
    } catch (_) {
      // The description may be unreachable while the device itself is
      // fine; registration re-verifies against the device directly.
      device = NasneDevice.direct(host);
    }
    if (!mounted) return;
    await _registerDevice(device);
  }

  Future<void> _pickBufferDuration({
    required String title,
    required String description,
    required List<int> options,
    required int current,
    int? recommendedSeconds,
    required Future<void> Function(int value) onSelected,
  }) async {
    final chosen = await showDialog<int>(
      context: context,
      builder: (dialogContext) => SimpleDialog(
        title: Text(title),
        children: [
          Padding(
            padding: const EdgeInsets.fromLTRB(24, 0, 24, 8),
            child: Text(
              description,
              style: Theme.of(dialogContext).textTheme.bodySmall,
            ),
          ),
          for (final opt in options)
            SimpleDialogOption(
              onPressed: () => Navigator.of(dialogContext).pop(opt),
              child: Focus(
                autofocus: opt == current,
                child: Builder(
                  builder: (focusContext) {
                    final focused = Focus.of(focusContext).hasFocus;
                    final label = formatBufferDurationLabel(opt);
                    final suffix =
                        recommendedSeconds != null && opt == recommendedSeconds
                        ? '（車載おすすめ）'
                        : '';
                    return Container(
                      padding: const EdgeInsets.symmetric(
                        horizontal: 8,
                        vertical: 6,
                      ),
                      decoration: BoxDecoration(
                        borderRadius: BorderRadius.circular(6),
                        border: focused
                            ? Border.all(color: Colors.amber, width: 2)
                            : null,
                      ),
                      child: Row(
                        children: [
                          Icon(
                            opt == current
                                ? Icons.check_circle
                                : Icons.radio_button_unchecked,
                            size: 20,
                          ),
                          const SizedBox(width: 12),
                          Expanded(child: Text('$label$suffix')),
                        ],
                      ),
                    );
                  },
                ),
              ),
            ),
        ],
      ),
    );
    if (chosen != null) {
      await onSelected(chosen);
    }
  }

  Future<void> _onRegistrationAction(String action, RegisteredNasne reg) async {
    switch (action) {
      case 'select':
        await ref.read(selectedHostProvider.notifier).select(reg.host);
      case 'verify':
        try {
          final ok = await ref.read(registrationServiceProvider).verify(reg);
          if (!mounted) return;
          showSnack(
            context,
            ok ? '検証 OK: ${reg.host}' : '検証に失敗しました: ${reg.host}',
          );
        } on NasneError catch (e) {
          if (!mounted) return;
          showSnack(context, userMessageForError(e));
        }
      case 'remove':
        final ok = await confirmDialog(
          context,
          title: '登録を解除',
          message: '${reg.friendlyName} (${reg.host}) の登録を解除しますか？',
          confirmLabel: '解除',
        );
        if (!ok) return;
        await ref.read(registrationsProvider.notifier).remove(reg.host);
        if (ref.read(selectedHostProvider) == reg.host) {
          await ref.read(selectedHostProvider.notifier).select(null);
        }
        if (!mounted) return;
        showSnack(context, '登録を解除しました');
    }
  }
}
