/// Dedicated Fire TV subtitle appearance settings screen with an always-visible
/// live broadcast preview above the control list.
library;

import 'dart:async';

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:material_ui/material_ui.dart';

import '../app/providers.dart';
import 'subtitle_overlay.dart';
import 'subtitle_style_policy.dart';

const List<SubtitleCue> _previewSampleCues = [
  SubtitleCue(
    normalizedX: 0.14,
    normalizedY: 0.14,
    alignment: 7,
    spans: [
      SubtitleStyledSpan(
        text: '♪[字] ニュース・番組テーマ',
        color: Color(0xFFFFFF00),
      ),
    ],
  ),
  SubtitleCue(
    normalizedX: 0.14,
    normalizedY: 0.72,
    alignment: 1,
    spans: [
      SubtitleStyledSpan(text: '[二] 話者A：', color: Color(0xFF80FFFF)),
      SubtitleStyledSpan(text: 'テレビ並みの字幕 →'),
    ],
  ),
  SubtitleCue(
    normalizedX: 0.14,
    normalizedY: 0.84,
    alignment: 1,
    spans: [
      SubtitleStyledSpan(text: '話者B「短い行」'),
    ],
  ),
];

/// Full-screen settings page for Fire TV subtitle & superimpose customization.
class SubtitleSettingsScreen extends ConsumerStatefulWidget {
  const SubtitleSettingsScreen({super.key});

  @override
  ConsumerState<SubtitleSettingsScreen> createState() =>
      _SubtitleSettingsScreenState();
}

class _SubtitleSettingsScreenState
    extends ConsumerState<SubtitleSettingsScreen> {
  List<SubtitleCue> _testSuperimposeCues = const [];
  Timer? _testSuperimposeTimer;

  @override
  void dispose() {
    _testSuperimposeTimer?.cancel();
    super.dispose();
  }

  void _triggerSuperimposeTest({required bool emergency}) {
    _testSuperimposeTimer?.cancel();
    final cues = decodeSampleSuperimposeCues(emergency: emergency);
    setState(() {
      _testSuperimposeCues = cues;
    });
    _testSuperimposeTimer = Timer(const Duration(seconds: 4), () {
      if (!mounted) return;
      setState(() {
        _testSuperimposeCues = const [];
      });
    });
    if (ref.read(superimposeSoundEnabledProvider)) {
      unawaited(
        ref
            .read(aribSoundPlayerProvider)
            .playAribBuiltinSound(emergency ? 4 : 0, urgent: emergency),
      );
    }
  }

  @override
  Widget build(BuildContext context) {
    final settings = ref.watch(subtitleSettingsProvider);
    final notifier = ref.read(subtitleSettingsProvider.notifier);
    final subtitlesOn = ref.watch(subtitlesEnabledProvider);
    final superimposeOn = ref.watch(superimposeEnabledProvider);
    final superimposeSoundOn = ref.watch(superimposeSoundEnabledProvider);
    final theme = Theme.of(context);

    return Scaffold(
      appBar: AppBar(
        title: const Text('字幕表示設定'),
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
                            // Simulated bright-to-dark TV frame behind preview cues.
                            const DecoratedBox(
                              decoration: BoxDecoration(
                                gradient: LinearGradient(
                                  begin: Alignment.topLeft,
                                  end: Alignment.bottomRight,
                                  colors: [
                                    Color(0xFF5D8AA8),
                                    Color(0xFF3E6B48),
                                    Color(0xFF1F2937),
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
                                  'プレビュー (16:9)',
                                  style: TextStyle(
                                    color: Colors.white70,
                                    fontSize: 18,
                                    fontWeight: FontWeight.bold,
                                  ),
                                ),
                              ),
                            ),
                            PlayerSubtitleOverlay(
                              settings: settings,
                              cues: _previewSampleCues,
                              bottomSafePadding: 24.0,
                            ),
                            if (_testSuperimposeCues.isNotEmpty)
                              PlayerSubtitleOverlay(
                                settings: settings,
                                cues: _testSuperimposeCues,
                                bottomSafePadding: 24.0,
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
                  title: const Text('字幕表示（再生時の既定）'),
                  subtitle: const Text('オン／オフの状態を記憶し、チャンネル切替後も維持します'),
                  value: subtitlesOn,
                  onChanged: (value) =>
                      ref.read(subtitlesEnabledProvider.notifier).set(value),
                ),
                const Divider(height: 16),
                _SectionHeader(title: '文字サイズ', theme: theme),
                const SizedBox(height: 8),
                SegmentedButton<SubtitleSizePreset>(
                  segments: [
                    for (final preset in SubtitleSizePreset.values)
                      ButtonSegment(value: preset, label: Text(preset.label)),
                  ],
                  selected: {settings.size},
                  onSelectionChanged: (sel) => notifier.setSize(sel.first),
                ),
                const SizedBox(height: 20),
                _SectionHeader(title: 'フォント', theme: theme),
                const SizedBox(height: 8),
                Wrap(
                  spacing: 8,
                  runSpacing: 8,
                  children: [
                    for (final font in SubtitleFontFamily.values)
                      ChoiceChip(
                        label: Text(
                          font.label,
                          style: TextStyle(
                            fontFamily: font.fontFamily,
                            fontFamilyFallback: font.fontFamilyFallback,
                            fontWeight: font.fontWeight,
                          ),
                        ),
                        selected: settings.font == font,
                        onSelected: (selected) {
                          if (selected) notifier.setFont(font);
                        },
                      ),
                  ],
                ),
                const SizedBox(height: 20),
                _SectionHeader(title: '文字の縁取り・影', theme: theme),
                const SizedBox(height: 8),
                Wrap(
                  spacing: 8,
                  runSpacing: 8,
                  children: [
                    for (final edge in SubtitleEdgeStyle.values)
                      ChoiceChip(
                        label: Text(edge.label),
                        selected: settings.edge == edge,
                        onSelected: (selected) {
                          if (selected) notifier.setEdge(edge);
                        },
                      ),
                  ],
                ),
                const SizedBox(height: 20),
                _SectionHeader(title: '背景色', theme: theme),
                const SizedBox(height: 8),
                SegmentedButton<SubtitleBackgroundColorPreset>(
                  segments: [
                    for (final bg in SubtitleBackgroundColorPreset.values)
                      ButtonSegment(value: bg, label: Text(bg.label)),
                  ],
                  selected: {settings.backgroundColor},
                  onSelectionChanged: (sel) =>
                      notifier.setBackgroundColor(sel.first),
                ),
                const SizedBox(height: 16),
                _SectionHeader(title: '背景の透明度', theme: theme),
                const SizedBox(height: 8),
                Wrap(
                  spacing: 8,
                  runSpacing: 8,
                  children: [
                    for (final opacity in subtitleBackgroundOpacityOptions)
                      ChoiceChip(
                        label: Text(subtitleBackgroundOpacityLabel(opacity)),
                        selected: settings.backgroundOpacityPercent == opacity,
                        onSelected: (selected) {
                          if (selected) notifier.setBackgroundOpacity(opacity);
                        },
                      ),
                  ],
                ),
                const Divider(height: 24),
                _SectionHeader(title: '文字スーパー（速報テロップ）', theme: theme),
                const SizedBox(height: 4),
                SwitchListTile(
                  contentPadding: EdgeInsets.zero,
                  title: const Text('文字スーパー表示（緊急地震速報・BSニュース速報等）'),
                  subtitle: const Text('字幕オフ時でも速報テロップを自動表示します'),
                  value: superimposeOn,
                  onChanged: (value) =>
                      ref.read(superimposeEnabledProvider.notifier).set(value),
                ),
                SwitchListTile(
                  contentPadding: EdgeInsets.zero,
                  title: const Text('文字スーパーの内蔵チャイム音'),
                  subtitle: const Text('速報テロップに内蔵音指定がある場合にテレビ音声へ重ねて鳴らします'),
                  value: superimposeSoundOn,
                  onChanged: superimposeOn
                      ? (value) => ref
                            .read(superimposeSoundEnabledProvider.notifier)
                            .set(value)
                      : null,
                ),
                const SizedBox(height: 8),
                Wrap(
                  spacing: 12,
                  runSpacing: 8,
                  children: [
                    OutlinedButton.icon(
                      onPressed: () => _triggerSuperimposeTest(emergency: true),
                      icon: const Icon(Icons.warning_amber_rounded),
                      label: const Text('緊急地震速報をテスト'),
                    ),
                    OutlinedButton.icon(
                      onPressed: () =>
                          _triggerSuperimposeTest(emergency: false),
                      icon: const Icon(Icons.campaign_outlined),
                      label: const Text('BSニュース速報をテスト'),
                    ),
                  ],
                ),
                const SizedBox(height: 16),
                Text(
                  '※ 字幕の表示位置や話者ごとの文字色、♪・［字］等の放送用記号は番組側の情報に合わせて自動反映されます。'
                  '放送局独自の画像外字（DRCS）は代替記号で表示されます。',
                  style: theme.textTheme.bodySmall,
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
