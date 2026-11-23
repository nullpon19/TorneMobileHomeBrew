/// DTCP-IP credential import screen (Phase 5, plan 26.4).
///
/// The user imports their own device pair (DTLA certificate 88
/// bytes + private key 20 bytes) obtained from their own equipment.
/// The pair is validated, then stored only in the OS vault. The
/// bytes are never shown after entry, never logged, and the text
/// fields are cleared as soon as the import completes.
///
/// Since plan 67 the pair can also be imported from a pydtcpip-style
/// credentials.env file; that path feeds the same validation + save
/// as the manual entry kept below it.
///
/// Since plan 84 a failed file pick is logged and shown as an
/// error instead of escaping silently (the plan 69.5 leftover).
///
/// Plan 86.2 (plan 85 item 2): the surface speaks plainly. The
/// internal facts a viewer never acts on — byte counts, the
/// certificate's SHA-1, the device ID in hex, the env file's
/// variable names — are gone from the text; what remains is
/// what to prepare, in which order, and what to do when
/// something fails. Failures are shown as a plain sentence plus
/// the next action; the raw error goes to the diagnostics log
/// only. The validation itself is unchanged.
library;

import 'dart:convert';
import 'dart:typed_data';

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:material_ui/material_ui.dart';

import '../app/firetv_helper.dart';
import '../app/firetv_preset.dart';
import '../app/providers.dart';
import '../core/core.dart';
import 'widgets.dart';

class DtcpCredentialScreen extends ConsumerStatefulWidget {
  const DtcpCredentialScreen({super.key});

  @override
  ConsumerState<DtcpCredentialScreen> createState() =>
      _DtcpCredentialScreenState();
}

class _DtcpCredentialScreenState extends ConsumerState<DtcpCredentialScreen> {
  final _certText = TextEditingController();
  final _keyText = TextEditingController();
  Uint8List? _certFileBytes;
  Uint8List? _keyFileBytes;
  String? _error;
  bool _busy = false;

  @override
  void dispose() {
    _certText.dispose();
    _keyText.dispose();
    super.dispose();
  }

  /// Decodes pasted input: hex (whitespace tolerant) or base64.
  static Uint8List _decodePasted(String text) {
    final compact = text.replaceAll(RegExp(r'\s+'), '');
    if (compact.isEmpty) {
      throw NasneError.validation('dtcp:import', '入力が空です');
    }
    if (RegExp(r'^[0-9a-fA-F]+$').hasMatch(compact) && compact.length.isEven) {
      return hexToBytes(compact.toLowerCase());
    }
    try {
      return base64Decode(compact);
    } on FormatException {
      throw NasneError.validation(
        'dtcp:import',
        'hex または base64 として解釈できませんでした',
      );
    }
  }

  /// Picks a file. On Android / Fire TV, opens an in-app file chooser that
  /// lists candidate files in Download / Documents / app-private storage so
  /// Fire OS 8 devices without DocumentsUI can select credentials with a
  /// D-pad remote. On other platforms (or if the user chooses the system
  /// picker fallback), falls back to [FileBytesPicker].
  Future<Uint8List?> _pickFile() async {
    final helper = ref.read(fireTvHelperProvider);
    if (helper.isAndroid) {
      final result = await showDialog<_FireTvPickResult>(
        context: context,
        builder: (_) => _FireTvFilePickerDialog(helper: helper),
      );
      if (result == null) return null;
      if (result.useSystemPicker) {
        return _pickWithSystemPicker();
      }
      return result.bytes;
    }
    return _pickWithSystemPicker();
  }

  Future<Uint8List?> _pickWithSystemPicker() async {
    try {
      return await ref.read(fileBytesPickerProvider).pick();
    } catch (e) {
      ref.read(diagLogProvider)(
        DiagCategory.ui,
        'credential file pick failed: $e',
      );
      if (mounted) {
        setState(() => _error = 'ファイル選択に失敗しました。もう一度お試しください。');
      }
      return null;
    }
  }

  /// Imports from a credentials.env file (plan 67): picking the
  /// file is all the user does — the parsed pair goes through
  /// the exact same validation + vault save as the manual entry
  /// below. A file that does not yield a pair is reported in
  /// plain words (plan 86.2), with the parse failure itself
  /// recorded in the diagnostics log.
  Future<void> _importFromEnvFile() async {
    final bytes = await _pickFile();
    if (bytes == null) return;
    final String text;
    try {
      text = utf8.decode(bytes);
    } on FormatException {
      setState(
        () => _error = 'ファイルを読み取れませんでした。'
            '資格情報ファイル (credentials.env) かどうか確認してください。',
      );
      return;
    }
    final CredentialsEnv env;
    try {
      env = parseCredentialsEnv(text);
    } catch (e) {
      ref.read(diagLogProvider)(
        DiagCategory.ui,
        'credentials.env parse failed: $e',
      );
      if (mounted) {
        setState(
          () => _error = 'ファイルから証明書と秘密鍵を取り出せませんでした。'
              '資格情報ファイル (credentials.env) かどうか確認してください。',
        );
      }
      return;
    }
    await _import(certificate: env.certificate, privateKey: env.privateKey);
  }

  Future<void> _import({Uint8List? certificate, Uint8List? privateKey}) async {
    FocusScope.of(context).unfocus();
    setState(() {
      _busy = true;
      _error = null;
    });
    try {
      final Uint8List certificateBytes;
      final Uint8List privateKeyBytes;
      try {
        certificateBytes =
            certificate ?? _certFileBytes ?? _decodePasted(_certText.text);
        privateKeyBytes =
            privateKey ?? _keyFileBytes ?? _decodePasted(_keyText.text);
      } on NasneError catch (e) {
        ref.read(diagLogProvider)(
          DiagCategory.ui,
          'credential entry decode failed: $e',
        );
        setState(
          () => _error = '貼り付けた内容を読み取れませんでした。'
              '証明書・秘密鍵の内容がそのまま入っているか確認してください。',
        );
        return;
      }
      try {
        await ref
            .read(credentialStoreProvider)
            .save(certificate: certificateBytes, privateKey: privateKeyBytes);
      } catch (e) {
        ref.read(diagLogProvider)(
          DiagCategory.ui,
          'credential pair validation failed: $e',
        );
        setState(
          () => _error = '証明書と秘密鍵のペアとして確認できませんでした。'
              '同じ機器から取り出したペアになっているか、'
              '内容が欠けていないか確認してください。',
        );
        return;
      }
      // Clear the entry surfaces immediately; the pair now lives
      // only in the vault.
      _certText.clear();
      _keyText.clear();
      _certFileBytes = null;
      _keyFileBytes = null;
      ref.invalidate(credentialSummaryProvider);
      if (mounted) {
        ScaffoldMessenger.of(context)
            .showSnackBar(const SnackBar(content: Text('資格情報を保存しました')));
      }
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  Future<void> _importFromPreset(FireTvPreset preset) async {
    try {
      await _import(
        certificate: hexToBytes(preset.certHex.trim().toLowerCase()),
        privateKey: hexToBytes(preset.keyHex.trim().toLowerCase()),
      );
    } catch (e) {
      ref.read(diagLogProvider)(
        DiagCategory.ui,
        'preset credential decode failed',
      );
      if (mounted) {
        setState(() => _error = '内蔵プリセットの読み込みに失敗しました。');
      }
    }
  }

  Future<void> _delete() async {
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('資格情報を削除'),
        content: const Text('保存済みの証明書と秘密鍵を端末の金庫から削除します。削除すると録画の再生はできなくなります。'),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context, false),
            child: const Text('キャンセル'),
          ),
          TextButton(
            onPressed: () => Navigator.pop(context, true),
            child: const Text('削除'),
          ),
        ],
      ),
    );
    if (confirmed != true) return;
    await ref.read(credentialStoreProvider).delete();
    ref.invalidate(credentialSummaryProvider);
    if (mounted) {
      ScaffoldMessenger.of(context)
          .showSnackBar(const SnackBar(content: Text('資格情報を削除しました')));
    }
  }

  @override
  Widget build(BuildContext context) {
    final summary = ref.watch(credentialSummaryProvider);
    final preset = ref.watch(fireTvPresetProvider);
    final theme = Theme.of(context);
    return Scaffold(
      appBar: AppBar(title: const Text('DTCP-IP 資格情報')),
      body: ListView(
        keyboardDismissBehavior: ScrollViewKeyboardDismissBehavior.onDrag,
        padding: const EdgeInsets.all(16),
        children: [
          summary.when(
            data: (value) => value == null
                ? const ListTile(
                    dense: true,
                    contentPadding: EdgeInsets.zero,
                    leading: Icon(Icons.info_outline),
                    title: Text('未インポート'),
                    subtitle: Text(
                      '再生には対応機器から取り出した証明書と秘密鍵のペアが必要です（端末内にのみ保存）。',
                    ),
                  )
                : const ListTile(
                    dense: true,
                    contentPadding: EdgeInsets.zero,
                    leading: Icon(Icons.verified_user),
                    title: Text('インポート済み'),
                    subtitle: Text('端末内の安全な保管庫に保存されています。'),
                  ),
            loading: () => const ListTile(
              dense: true,
              contentPadding: EdgeInsets.zero,
              title: Text('確認中…'),
            ),
            error: (e, _) => const ListTile(
              dense: true,
              contentPadding: EdgeInsets.zero,
              title: Text('状態を確認できませんでした'),
            ),
          ),
          if (_error != null) ...[
            const SizedBox(height: 8),
            Container(
              padding: const EdgeInsets.all(10),
              decoration: BoxDecoration(
                color: theme.colorScheme.errorContainer,
                borderRadius: BorderRadius.circular(8),
              ),
              child: Text(
                _error!,
                style: TextStyle(color: theme.colorScheme.onErrorContainer),
              ),
            ),
          ],
          const SizedBox(height: 12),
          // Action buttons placed ABOVE the text inputs so Fire TV D-pad users
          // never get trapped inside FireTVIME before reaching the buttons.
          Wrap(
            spacing: 12,
            runSpacing: 8,
            children: [
              FilledButton.icon(
                autofocus: true,
                onPressed: _busy ? null : _importFromEnvFile,
                icon: const Icon(Icons.folder_open),
                label: const Text('ファイルから読み込む (credentials.env)'),
              ),
              FilledButton.tonalIcon(
                onPressed: _busy ? null : () => _import(),
                icon: const Icon(Icons.download_done),
                label: const Text('検証して保存'),
              ),
              if (preset.hasCredentials)
                FilledButton.tonalIcon(
                  onPressed: _busy ? null : () => _importFromPreset(preset),
                  icon: const Icon(Icons.restore),
                  label: const Text('内蔵プリセットを読み込む'),
                ),
              OutlinedButton.icon(
                onPressed: _busy ? null : _delete,
                icon: const Icon(Icons.delete_outline),
                label: const Text('保存済みの資格情報を削除'),
              ),
            ],
          ),
          const SizedBox(height: 12),
          Text('用意のしかた', style: theme.textTheme.titleSmall),
          const SizedBox(height: 4),
          Text(
            'ファイル (credentials.env) は Download フォルダまたはアプリ専用フォルダに置いて上のボタンから選べます。'
            '直接入力する場合は下の左右2欄に入力し、上の「検証して保存」を押してください。',
            style: theme.textTheme.bodySmall,
          ),
          const Divider(height: 24),
          Row(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Expanded(
                child: _pairFields(
                  label: '証明書',
                  controller: _certText,
                  fileBytes: _certFileBytes,
                  onPick: () async {
                    final bytes = await _pickFile();
                    if (bytes != null) setState(() => _certFileBytes = bytes);
                  },
                  onClearFile: () => setState(() => _certFileBytes = null),
                ),
              ),
              const SizedBox(width: 12),
              Expanded(
                child: _pairFields(
                  label: '秘密鍵',
                  controller: _keyText,
                  fileBytes: _keyFileBytes,
                  onPick: () async {
                    final bytes = await _pickFile();
                    if (bytes != null) setState(() => _keyFileBytes = bytes);
                  },
                  onClearFile: () => setState(() => _keyFileBytes = null),
                ),
              ),
            ],
          ),
        ],
      ),
    );
  }

  Widget _pairFields({
    required String label,
    required TextEditingController controller,
    required Uint8List? fileBytes,
    required Future<void> Function() onPick,
    required VoidCallback onClearFile,
  }) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Row(
          children: [
            Expanded(
              child: Text(label, style: Theme.of(context).textTheme.titleSmall),
            ),
            if (fileBytes == null)
              OutlinedButton.icon(
                onPressed: _busy ? null : onPick,
                icon: const Icon(Icons.folder_open, size: 18),
                label: const Text('ファイル選択'),
              ),
          ],
        ),
        const SizedBox(height: 6),
        if (fileBytes != null)
          ListTile(
            contentPadding: const EdgeInsets.symmetric(horizontal: 8),
            leading: const Icon(Icons.insert_drive_file),
            title: const Text('ファイルから読み込み済み'),
            trailing: IconButton(
              icon: const Icon(Icons.close),
              onPressed: onClearFile,
            ),
          )
        else
          FireTvTextInputField(
            controller: controller,
            labelText: label,
            hintText: '決定キーで入力（内容を貼り付け）',
            dialogTitle: '$label を入力',
            minLines: 2,
            maxLines: 3,
            autocorrect: false,
            enableSuggestions: false,
            showClearButton: true,
          ),
      ],
    );
  }
}

class _FireTvPickResult {
  const _FireTvPickResult.bytes(this.bytes) : useSystemPicker = false;
  const _FireTvPickResult.systemPicker()
    : bytes = null,
      useSystemPicker = true;

  final Uint8List? bytes;
  final bool useSystemPicker;
}

class _FireTvFilePickerDialog extends StatefulWidget {
  const _FireTvFilePickerDialog({required this.helper});

  final FireTvHelper helper;

  @override
  State<_FireTvFilePickerDialog> createState() =>
      _FireTvFilePickerDialogState();
}

class _FireTvFilePickerDialogState extends State<_FireTvFilePickerDialog> {
  bool _loading = true;
  bool _hasPermission = true;
  String? _appFilesDir;
  String? _error;
  List<CredentialCandidateFile> _files = const [];

  @override
  void initState() {
    super.initState();
    _refresh();
  }

  Future<void> _refresh() async {
    setState(() {
      _loading = true;
      _error = null;
    });
    final hasPerm = await widget.helper.hasStoragePermission();
    final appDir = await widget.helper.getAppFilesDirPath();
    final files = await widget.helper.listCredentialCandidateFiles();
    if (!mounted) return;
    setState(() {
      _hasPermission = hasPerm;
      _appFilesDir = appDir;
      _files = files;
      _loading = false;
    });
  }

  Future<void> _requestPermission() async {
    final granted = await widget.helper.requestStoragePermission();
    if (!mounted) return;
    if (!granted) {
      setState(() {
        _error = 'ストレージ読み取り権限が許可されませんでした。アプリ専用フォルダを使用してください。';
      });
    }
    await _refresh();
  }

  Future<void> _selectFile(CredentialCandidateFile file) async {
    setState(() {
      _loading = true;
      _error = null;
    });
    final bytes = await widget.helper.readFileBytes(file.path);
    if (!mounted) return;
    if (bytes == null) {
      setState(() {
        _loading = false;
        _error = '${file.name} を読み込めませんでした。権限またはファイル配置を確認してください。';
      });
      return;
    }
    Navigator.of(context).pop(_FireTvPickResult.bytes(bytes));
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return AlertDialog(
      title: const Text('資格情報ファイルを選択'),
      content: SizedBox(
        width: 520,
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            if (_error != null) ...[
              Text(_error!, style: TextStyle(color: theme.colorScheme.error)),
              const SizedBox(height: 8),
            ],
            if (_loading)
              const Padding(
                padding: EdgeInsets.symmetric(vertical: 24),
                child: Center(child: CircularProgressIndicator()),
              )
            else if (_files.isEmpty)
              Padding(
                padding: const EdgeInsets.symmetric(vertical: 8),
                child: Text(
                  '候補ファイルが見つかりませんでした。\n'
                  'Download フォルダ または アプリ専用フォルダにファイルを配置してください。'
                  '${_appFilesDir != null ? '\nアプリ専用フォルダ: $_appFilesDir' : ''}',
                  style: theme.textTheme.bodySmall,
                ),
              )
            else
              ConstrainedBox(
                constraints: const BoxConstraints(maxHeight: 280),
                child: ListView.builder(
                  shrinkWrap: true,
                  itemCount: _files.length,
                  itemBuilder: (context, index) {
                    final f = _files[index];
                    return ListTile(
                      autofocus: index == 0,
                      leading: const Icon(Icons.description_outlined),
                      title: Text(f.name),
                      subtitle: Text('${f.folder} (${f.size} B)'),
                      onTap: () => _selectFile(f),
                    );
                  },
                ),
              ),
          ],
        ),
      ),
      actions: [
        if (!_hasPermission)
          FilledButton.tonal(
            onPressed: _loading ? null : _requestPermission,
            child: const Text('Download フォルダの権限を許可'),
          ),
        TextButton(
          onPressed: _loading ? null : _refresh,
          child: const Text('再読み込み'),
        ),
        TextButton(
          onPressed: _loading
              ? null
              : () => Navigator.of(
                  context,
                ).pop(const _FireTvPickResult.systemPicker()),
          child: const Text('標準ピッカーを試す'),
        ),
        TextButton(
          onPressed: () => Navigator.of(context).pop(),
          child: const Text('キャンセル'),
        ),
      ],
    );
  }
}
