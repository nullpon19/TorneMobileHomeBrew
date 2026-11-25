/// Dedicated Fire TV Niconico Jikkyo settings screen with a live 16:9 flowing
/// comment preview and channel mapping management (Phase 40).
library;

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:material_ui/material_ui.dart';

import '../app/providers.dart';
import '../core/jikkyo/jikkyo_models.dart';
import 'jikkyo_overlay.dart';
import 'widgets.dart';

const List<JikkyoComment> _jikkyoPreviewComments = [
  JikkyoComment(timestampMs: 1000, text: 'きたあああああ！'),
  JikkyoComment(
    timestampMs: 2000,
    text: '映像きれいだな',
    colorValue: 0xFF00FFFF,
  ),
  JikkyoComment(
    timestampMs: 3000,
    text: '速報テロップすごい',
    position: JikkyoCommentPosition.ue,
    colorValue: 0xFFFFFF00,
  ),
  JikkyoComment(timestampMs: 4000, text: '8888888888'),
  JikkyoComment(
    timestampMs: 5000,
    text: 'ここで神BGM！',
    colorValue: 0xFF00FF00,
    size: JikkyoCommentSize.big,
  ),
  JikkyoComment(
    timestampMs: 6000,
    text: '下に固定コメも出せるよ',
    position: JikkyoCommentPosition.shita,
  ),
];

class JikkyoSettingsScreen extends ConsumerStatefulWidget {
  const JikkyoSettingsScreen({super.key});

  @override
  ConsumerState<JikkyoSettingsScreen> createState() =>
      _JikkyoSettingsScreenState();
}

class _JikkyoSettingsScreenState extends ConsumerState<JikkyoSettingsScreen> {
  final TextEditingController _ngWordController = TextEditingController();

  @override
  void dispose() {
    _ngWordController.dispose();
    super.dispose();
  }

  void _submitNgWord(String raw) {
    final trimmed = raw.trim();
    if (trimmed.isEmpty) return;
    ref.read(jikkyoSettingsProvider.notifier).addNgWord(trimmed);
    _ngWordController.clear();
  }

  @override
  Widget build(BuildContext context) {
    final settings = ref.watch(jikkyoSettingsProvider);
    final notifier = ref.read(jikkyoSettingsProvider.notifier);
    final enabled = ref.watch(jikkyoEnabledProvider);
    final theme = Theme.of(context);
    final overrides = settings.channelOverrides.entries.toList()
      ..sort((a, b) => a.key.compareTo(b.key));

    return Scaffold(
      appBar: AppBar(
        title: const Text('ニコニコ実況設定'),
        actions: [
          TextButton.icon(
            onPressed: notifier.resetDefaults,
            icon: const Icon(Icons.restart_alt),
            label: const Text('初期設定に戻す'),
          ),
        ],
      ),
      body: Column(
        children: [
          Padding(
            padding: const EdgeInsets.fromLTRB(16, 10, 16, 8),
            child: Center(
              child: ConstrainedBox(
                constraints: const BoxConstraints(maxHeight: 204),
                child: AspectRatio(
                  aspectRatio: 16 / 9,
                  child: ClipRRect(
                    borderRadius: BorderRadius.circular(10),
                    child: FittedBox(
                      fit: BoxFit.contain,
                      child: SizedBox(
                        width: 960,
                        height: 540,
                        child: Stack(
                          fit: StackFit.expand,
                          children: [
                            const DecoratedBox(
                              decoration: BoxDecoration(
                                gradient: LinearGradient(
                                  begin: Alignment.topLeft,
                                  end: Alignment.bottomRight,
                                  colors: [
                                    Color(0xFF3E5C76),
                                    Color(0xFF2D4A3E),
                                    Color(0xFF1A202C),
                                  ],
                                ),
                              ),
                            ),
                            Positioned(
                              top: 16,
                              right: 20,
                              child: Container(
                                padding: const EdgeInsets.symmetric(
                                  horizontal: 14,
                                  vertical: 5,
                                ),
                                decoration: BoxDecoration(
                                  color: Colors.black54,
                                  borderRadius: BorderRadius.circular(6),
                                ),
                                child: const Text(
                                  '実況プレビュー (16:9)',
                                  style: TextStyle(
                                    color: Colors.white70,
                                    fontSize: 18,
                                    fontWeight: FontWeight.bold,
                                  ),
                                ),
                              ),
                            ),
                            JikkyoDanmakuOverlay(
                              settings: settings,
                              isPlaying: true,
                              avoidBottomSubtitles: settings.avoidSubtitleArea,
                              previewLoopComments: _jikkyoPreviewComments,
                            ),
                            if (settings.avoidSubtitleArea)
                              Positioned(
                                left: 160,
                                right: 160,
                                bottom: 32,
                                child: Container(
                                  padding: const EdgeInsets.symmetric(
                                    horizontal: 16,
                                    vertical: 8,
                                  ),
                                  decoration: BoxDecoration(
                                    color: Colors.black.withValues(alpha: 0.65),
                                    borderRadius: BorderRadius.circular(6),
                                  ),
                                  child: const Text(
                                    '[字] 字幕表示エリア（この領域を避けて表示します）',
                                    textAlign: TextAlign.center,
                                    style: TextStyle(
                                      color: Colors.white,
                                      fontSize: 22,
                                      fontWeight: FontWeight.bold,
                                    ),
                                  ),
                                ),
                              ),
                          ],
                        ),
                      ),
                    ),
                  ),
                ),
              ),
            ),
          ),
          const Divider(height: 1),
          Expanded(
            child: ListView(
              padding: const EdgeInsets.fromLTRB(16, 12, 16, 24),
              children: [
                SwitchListTile(
                  contentPadding: EdgeInsets.zero,
                  title: const Text('ニコニコ実況表示（再生時の既定）'),
                  subtitle: const Text('初期状態はオフです。再生画面のメニューからも切り替えできます'),
                  value: enabled,
                  onChanged: (value) =>
                      ref.read(jikkyoEnabledProvider.notifier).set(value),
                ),
                const Divider(height: 16),
                _SectionHeader(title: '文字の濃さ（不透明度）', theme: theme),
                const SizedBox(height: 8),
                Wrap(
                  spacing: 8,
                  runSpacing: 8,
                  children: [
                    for (final opacity in jikkyoOpacityOptions)
                      ChoiceChip(
                        label: Text('$opacity%'),
                        selected: settings.opacityPercent == opacity,
                        onSelected: (selected) {
                          if (selected) notifier.setOpacity(opacity);
                        },
                      ),
                  ],
                ),
                const SizedBox(height: 20),
                _SectionHeader(title: '文字サイズ', theme: theme),
                const SizedBox(height: 8),
                SegmentedButton<JikkyoTextSizePreset>(
                  segments: [
                    for (final preset in JikkyoTextSizePreset.values)
                      ButtonSegment(value: preset, label: Text(preset.label)),
                  ],
                  selected: {settings.textSize},
                  onSelectionChanged: (sel) => notifier.setTextSize(sel.first),
                ),
                const SizedBox(height: 20),
                _SectionHeader(title: '流れる速度', theme: theme),
                const SizedBox(height: 8),
                SegmentedButton<JikkyoSpeedPreset>(
                  segments: [
                    for (final preset in JikkyoSpeedPreset.values)
                      ButtonSegment(value: preset, label: Text(preset.label)),
                  ],
                  selected: {settings.speed},
                  onSelectionChanged: (sel) => notifier.setSpeed(sel.first),
                ),
                const SizedBox(height: 20),
                _SectionHeader(title: '画面内の同時表示上限', theme: theme),
                const SizedBox(height: 8),
                SegmentedButton<int>(
                  segments: [
                    for (final count in jikkyoMaxConcurrentOptions)
                      ButtonSegment(value: count, label: Text('$count件')),
                  ],
                  selected: {settings.maxConcurrentComments},
                  onSelectionChanged: (sel) =>
                      notifier.setMaxConcurrent(sel.first),
                ),
                const SizedBox(height: 16),
                SwitchListTile(
                  contentPadding: EdgeInsets.zero,
                  title: const Text('字幕・文字スーパー領域を避ける'),
                  subtitle: const Text('字幕や速報テロップが表示されている間は下部への描画を控えます'),
                  value: settings.avoidSubtitleArea,
                  onChanged: notifier.setAvoidSubtitleArea,
                ),
                const SizedBox(height: 16),
                _SectionHeader(title: 'Live 視聴時の遅延補正', theme: theme),
                const SizedBox(height: 4),
                Text(
                  'nasne からの映像配信の遅れに合わせて、表示タイミングを少し遅らせます（初期値 +5秒）',
                  style: theme.textTheme.bodySmall,
                ),
                const SizedBox(height: 8),
                Wrap(
                  spacing: 8,
                  runSpacing: 8,
                  children: [
                    for (final sec in jikkyoLiveDelayOptions)
                      ChoiceChip(
                        label: Text(sec == 0 ? '0秒' : '+$sec秒'),
                        selected: settings.liveDelaySeconds == sec,
                        onSelected: (selected) {
                          if (selected) notifier.setLiveDelaySeconds(sec);
                        },
                      ),
                  ],
                ),
                const Divider(height: 24),
                _SectionHeader(title: 'コメントフィルタ', theme: theme),
                const SizedBox(height: 4),
                SwitchListTile(
                  contentPadding: EdgeInsets.zero,
                  title: const Text('文字色を白に統一'),
                  subtitle: const Text('色付きコメントの色指定を無視してすべて白文字で表示します'),
                  value: settings.forceWhiteText,
                  onChanged: notifier.setForceWhiteText,
                ),
                SwitchListTile(
                  contentPadding: EdgeInsets.zero,
                  title: const Text('上下固定コメントを非表示'),
                  subtitle: const Text('画面上部・下部に固定表示されるコメントを除外します'),
                  value: settings.hideFixedComments,
                  onChanged: notifier.setHideFixedComments,
                ),
                const SizedBox(height: 8),
                Row(
                  children: [
                    Expanded(
                      child: FireTvTextInputField(
                        controller: _ngWordController,
                        labelText: 'NG ワードを追加',
                        hintText: '例: 特定の単語や絵文字',
                        dialogTitle: 'NG ワードを追加',
                        onSubmitted: _submitNgWord,
                      ),
                    ),
                    const SizedBox(width: 8),
                    OutlinedButton.icon(
                      onPressed: () => _submitNgWord(_ngWordController.text),
                      icon: const Icon(Icons.add),
                      label: const Text('追加'),
                    ),
                  ],
                ),
                if (settings.ngWords.isNotEmpty) ...[
                  const SizedBox(height: 10),
                  Row(
                    children: [
                      Text(
                        '登録済み NG ワード (${settings.ngWords.length}件)',
                        style: theme.textTheme.bodySmall,
                      ),
                      const Spacer(),
                      TextButton.icon(
                        onPressed: notifier.clearNgWords,
                        icon: const Icon(Icons.delete_sweep_outlined, size: 18),
                        label: const Text('すべて削除'),
                      ),
                    ],
                  ),
                  const SizedBox(height: 4),
                  Wrap(
                    spacing: 8,
                    runSpacing: 6,
                    children: [
                      for (final word in settings.ngWords)
                        InputChip(
                          label: Text(word),
                          deleteIcon: const Icon(Icons.close, size: 16),
                          onDeleted: () => notifier.removeNgWord(word),
                        ),
                    ],
                  ),
                ],
                const Divider(height: 24),
                Row(
                  children: [
                    Expanded(
                      child: _SectionHeader(
                        title: '手動チャンネル紐付け (${overrides.length}件)',
                        theme: theme,
                      ),
                    ),
                    if (overrides.isNotEmpty)
                      TextButton.icon(
                        onPressed: notifier.clearChannelOverrides,
                        icon: const Icon(Icons.delete_sweep_outlined),
                        label: const Text('すべてリセット'),
                      ),
                  ],
                ),
                const SizedBox(height: 6),
                if (overrides.isEmpty)
                  Text(
                    '現在はすべて自動判定です。ローカル局などで調整したい場合は再生中の OSD「実況調整」から変更できます。',
                    style: theme.textTheme.bodySmall,
                  )
                else
                  for (final entry in overrides)
                    ListTile(
                      contentPadding: EdgeInsets.zero,
                      title: Text(
                        settings.channelOverrideLabels[entry.key] ?? entry.key,
                      ),
                      subtitle: Text(
                        entry.value == kJikkyoDisabledId
                            ? 'このチャンネルは実況を表示しない'
                            : (jikkyoChannelById(entry.value)?.displayLabel ??
                                  entry.value),
                      ),
                      trailing: IconButton(
                        tooltip: '自動判定に戻す',
                        icon: const Icon(Icons.close),
                        onPressed: () =>
                            notifier.removeChannelOverride(entry.key),
                      ),
                    ),
              ],
            ),
          ),
        ],
      ),
    );
  }
}

class _SectionHeader extends StatelessWidget {
  const _SectionHeader({required this.title, required this.theme});

  final String title;
  final ThemeData theme;

  @override
  Widget build(BuildContext context) {
    return Text(title, style: theme.textTheme.titleSmall);
  }
}
