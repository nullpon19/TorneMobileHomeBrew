/// Dedicated Fire TV subtitle appearance settings screen with an always-visible
/// live broadcast preview above the control list.
library;

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
    normalizedX: 0.50,
    normalizedY: 0.78,
    alignment: 2,
    spans: [
      SubtitleStyledSpan(text: '[二] 話者A：', color: Color(0xFF80FFFF)),
      SubtitleStyledSpan(text: 'テレビ並みに見やすい字幕 →'),
    ],
  ),
  SubtitleCue(
    normalizedX: 0.50,
    normalizedY: 0.89,
    alignment: 2,
    spans: [
      SubtitleStyledSpan(text: '話者B「背景色や書体もここで確認できます」'),
    ],
  ),
];

/// Full-screen settings page for Fire TV subtitle appearance customization.
class SubtitleSettingsScreen extends ConsumerWidget {
  const SubtitleSettingsScreen({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final settings = ref.watch(subtitleSettingsProvider);
    final notifier = ref.read(subtitleSettingsProvider.notifier);
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
            padding: const EdgeInsets.fromLTRB(16, 12, 16, 8),
            child: Center(
              child: ConstrainedBox(
                constraints: const BoxConstraints(maxWidth: 520),
                child: ClipRRect(
                  borderRadius: BorderRadius.circular(12),
                  child: SizedBox(
                    height: 190,
                    width: double.infinity,
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
                          top: 8,
                          right: 12,
                          child: Container(
                            padding: const EdgeInsets.symmetric(
                              horizontal: 8,
                              vertical: 2,
                            ),
                            decoration: BoxDecoration(
                              color: Colors.black54,
                              borderRadius: BorderRadius.circular(4),
                            ),
                            child: const Text(
                              'プレビュー',
                              style: TextStyle(
                                color: Colors.white70,
                                fontSize: 11,
                                fontWeight: FontWeight.bold,
                              ),
                            ),
                          ),
                        ),
                        PlayerSubtitleOverlay(
                          settings: settings,
                          cues: _previewSampleCues,
                          bottomSafePadding: 14.0,
                          minFontSize: 10.0,
                        ),
                      ],
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
                _SectionHeader(title: '文字の縁取り', theme: theme),
                const SizedBox(height: 8),
                SegmentedButton<SubtitleEdgeStyle>(
                  segments: [
                    for (final edge in SubtitleEdgeStyle.values)
                      ButtonSegment(value: edge, label: Text(edge.label)),
                  ],
                  selected: {settings.edge},
                  onSelectionChanged: (sel) => notifier.setEdge(sel.first),
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
