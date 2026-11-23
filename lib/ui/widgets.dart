/// Shared UI building blocks: async section handling, cards, and
/// simple placeholder views. Screens compose these so loading and
/// error presentation stay uniform.
library;

import 'dart:async';

import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:material_ui/material_ui.dart';

import '../core/core.dart';
import 'error_messages.dart';

/// Full-area loading indicator.
class LoadingView extends StatelessWidget {
  const LoadingView({super.key});

  @override
  Widget build(BuildContext context) {
    return const Center(child: CircularProgressIndicator());
  }
}

/// Error display with an optional retry action.
class ErrorView extends StatelessWidget {
  const ErrorView({super.key, required this.message, this.onRetry});

  final String message;
  final VoidCallback? onRetry;

  @override
  Widget build(BuildContext context) {
    return Center(
      child: Padding(
        padding: const EdgeInsets.all(24),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(
              Icons.error_outline,
              size: 40,
              color: Theme.of(context).colorScheme.error,
            ),
            const SizedBox(height: 12),
            Text(message, textAlign: TextAlign.center),
            if (onRetry != null) ...[
              const SizedBox(height: 12),
              FilledButton.tonal(onPressed: onRetry, child: const Text('再試行')),
            ],
          ],
        ),
      ),
    );
  }
}

/// A titled card used to group one home-screen section.
class SectionCard extends StatefulWidget {
  const SectionCard({
    super.key,
    required this.title,
    required this.child,
    this.icon,
    this.trailing,
    this.margin = defaultMargin,
    this.focusable = false,
    this.scrollController,
  });

  static const EdgeInsets defaultMargin = EdgeInsets.fromLTRB(12, 6, 12, 6);

  final String title;
  final IconData? icon;
  final Widget? trailing;
  final Widget child;
  final EdgeInsetsGeometry margin;
  final bool focusable;
  final ScrollController? scrollController;

  @override
  State<SectionCard> createState() => _SectionCardState();
}

class _SectionCardState extends State<SectionCard> {
  late final FocusNode _focusNode = FocusNode(
    debugLabel: 'section:${widget.title}',
  )..addListener(_handleFocusNodeChanged);
  bool _hasPrimaryFocus = false;

  @override
  void dispose() {
    _focusNode
      ..removeListener(_handleFocusNodeChanged)
      ..dispose();
    super.dispose();
  }

  void _handleFocusNodeChanged() {
    final primary = _focusNode.hasPrimaryFocus;
    if (_hasPrimaryFocus != primary && mounted) {
      setState(() => _hasPrimaryFocus = primary);
    }
  }

  void _onFocusChange(bool hasFocus) {
    _handleFocusNodeChanged();
    if (!hasFocus) return;
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted) return;
      unawaited(
        Scrollable.ensureVisible(
          context,
          duration: const Duration(milliseconds: 180),
          curve: Curves.easeOut,
          alignment: 0.15,
        ),
      );
    });
  }

  KeyEventResult _handleKeyEvent(FocusNode node, KeyEvent event) {
    if (event is! KeyDownEvent && event is! KeyRepeatEvent) {
      return KeyEventResult.ignored;
    }
    if (!_focusNode.hasPrimaryFocus) {
      return KeyEventResult.ignored;
    }
    final key = event.logicalKey;
    if (key != LogicalKeyboardKey.arrowDown &&
        key != LogicalKeyboardKey.arrowUp) {
      return KeyEventResult.ignored;
    }

    final scrollable = Scrollable.maybeOf(context);
    final pos =
        (widget.scrollController != null && widget.scrollController!.hasClients)
        ? widget.scrollController!.position
        : scrollable?.position;
    final cardBox = context.findRenderObject() as RenderBox?;
    final viewportBox = scrollable?.context.findRenderObject() as RenderBox?;

    if (cardBox != null &&
        cardBox.attached &&
        cardBox.hasSize &&
        viewportBox != null &&
        viewportBox.attached &&
        viewportBox.hasSize) {
      final cardTop = cardBox
          .localToGlobal(Offset.zero, ancestor: viewportBox)
          .dy;
      final cardHeight = cardBox.size.height;
      final cardBottom = cardTop + cardHeight;
      final viewportHeight = viewportBox.size.height;

      if (key == LogicalKeyboardKey.arrowDown) {
        final overflowingBottom =
            cardBottom > viewportHeight + 4 &&
            (cardTop <= 24 || cardHeight > viewportHeight - 16);
        if (overflowingBottom &&
            pos != null &&
            pos.pixels < pos.maxScrollExtent) {
          final step = (cardBottom - viewportHeight + 16).clamp(80.0, 180.0);
          final target = (pos.pixels + step).clamp(
            pos.minScrollExtent,
            pos.maxScrollExtent,
          );
          unawaited(
            pos.animateTo(
              target,
              duration: const Duration(milliseconds: 140),
              curve: Curves.easeOut,
            ),
          );
          return KeyEventResult.handled;
        }
      } else {
        final overflowingTop =
            cardTop < -4 &&
            (cardBottom >= viewportHeight - 24 ||
                cardHeight > viewportHeight - 16);
        if (overflowingTop && pos != null && pos.pixels > pos.minScrollExtent) {
          final step = (-cardTop + 16).clamp(80.0, 180.0);
          final target = (pos.pixels - step).clamp(
            pos.minScrollExtent,
            pos.maxScrollExtent,
          );
          unawaited(
            pos.animateTo(
              target,
              duration: const Duration(milliseconds: 140),
              curve: Curves.easeOut,
            ),
          );
          return KeyEventResult.handled;
        }
      }
    }

    if (key == LogicalKeyboardKey.arrowDown) {
      final moved = _focusNode.focusInDirection(TraversalDirection.down);
      if (moved) return KeyEventResult.handled;
      if (pos != null && pos.pixels < pos.maxScrollExtent) {
        unawaited(
          pos.animateTo(
            pos.maxScrollExtent,
            duration: const Duration(milliseconds: 180),
            curve: Curves.easeOut,
          ),
        );
      }
      return KeyEventResult.handled;
    }

    return KeyEventResult.ignored;
  }

  @override
  Widget build(BuildContext context) {
    final isDark = Theme.of(context).brightness == Brightness.dark;
    final focusBorderColor = isDark ? Colors.amberAccent : Colors.black;
    final card = Card(
      margin: widget.margin,
      shape: widget.focusable && _hasPrimaryFocus
          ? RoundedRectangleBorder(
              borderRadius: BorderRadius.circular(12),
              side: BorderSide(color: focusBorderColor, width: 3),
            )
          : null,
      child: Padding(
        padding: const EdgeInsets.fromLTRB(16, 12, 16, 16),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              children: [
                if (widget.icon != null) ...[
                  Icon(widget.icon, size: 20),
                  const SizedBox(width: 8),
                ],
                Expanded(
                  child: Text(
                    widget.title,
                    style: Theme.of(context).textTheme.titleMedium,
                  ),
                ),
                ?widget.trailing,
              ],
            ),
            const SizedBox(height: 8),
            widget.child,
          ],
        ),
      ),
    );
    if (!widget.focusable) return card;
    return Focus(
      focusNode: _focusNode,
      onFocusChange: _onFocusChange,
      onKeyEvent: _handleKeyEvent,
      child: card,
    );
  }
}

/// Renders an [AsyncValue] as data / loading / error, uniformly.
Widget asyncSection<T>(
  AsyncValue<T> value,
  Widget Function(T data) builder, {
  VoidCallback? onRetry,
}) {
  return value.when(
    data: builder,
    loading: () => const Padding(
      padding: EdgeInsets.all(24),
      child: Center(child: CircularProgressIndicator()),
    ),
    error: (e, _) => Padding(
      padding: const EdgeInsets.all(12),
      child: ErrorView(message: userMessageForError(e), onRetry: onRetry),
    ),
  );
}

/// A label/value row for detail views.
class FieldRow extends StatelessWidget {
  const FieldRow({super.key, required this.label, required this.value});

  final String label;
  final String value;

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 3),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          SizedBox(
            width: 104,
            child: Text(
              label,
              style: Theme.of(context).textTheme.bodyMedium?.copyWith(
                color: Theme.of(context).colorScheme.onSurfaceVariant,
              ),
            ),
          ),
          Expanded(child: Text(value)),
        ],
      ),
    );
  }
}

/// Resolves the display name of the channel a schedule / title refers
/// to, falling back to the raw service id when the channel list is
/// unavailable.
String channelDisplayName(List<Channel>? channels, ScheduleChannel? channel) {
  if (channel == null) return '不明';
  if (channels != null) {
    for (final c in channels) {
      if (c.serviceId == channel.serviceId &&
          c.broadcastingType == channel.broadcastingType) {
        return c.serviceName;
      }
    }
  }
  return 'サービス ${channel.serviceIdHex}';
}

/// Shows a transient message at the bottom of [context]'s scaffold.
void showSnack(BuildContext context, String message) {
  ScaffoldMessenger.of(context)
    ..hideCurrentSnackBar()
    ..showSnackBar(SnackBar(content: Text(message)));
}

/// Confirmation dialog; resolves to true only on explicit confirm.
Future<bool> confirmDialog(
  BuildContext context, {
  required String title,
  required String message,
  String confirmLabel = '削除',
}) async {
  final result = await showDialog<bool>(
    context: context,
    builder: (context) => AlertDialog(
      title: Text(title),
      content: Text(message),
      actions: [
        TextButton(
          onPressed: () => Navigator.of(context).pop(false),
          child: const Text('キャンセル'),
        ),
        FilledButton(
          onPressed: () => Navigator.of(context).pop(true),
          child: Text(confirmLabel),
        ),
      ],
    ),
  );
  return result ?? false;
}

/// Cause-based checks for when discovery finds no nasne (plan 86.4).
/// Written for users who do not know the network vocabulary: each
/// item names a concrete thing to look at, in roughly the order it
/// most often turns out to be the cause.
const List<String> discoveryChecklistItems = [
  'nasne の電源が入っていて、起動が終わっていること',
  'この端末が、nasne と同じ Wi-Fi (同じネットワーク) につながっていること',
  'ルーターの「端末同士の通信を止める」設定 (プライバシーセパレータ、AP アイソレーションなど) がオフになっていること',
  'このアプリにローカルネットワークへのアクセスが許可されていること (iOS では「設定」アプリから確認できます)',
];

/// The discovery-failure checklist block (plan 86.4), shared by the
/// settings screen's "not found" and search-error states.
class DiscoveryChecklist extends StatelessWidget {
  const DiscoveryChecklist({super.key});

  @override
  Widget build(BuildContext context) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text(
          '見つからないときは、次の点を確認してください。',
          style: Theme.of(context).textTheme.titleSmall,
        ),
        const SizedBox(height: 6),
        for (final item in discoveryChecklistItems)
          Padding(
            padding: const EdgeInsets.symmetric(vertical: 2),
            child: Row(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                const Icon(Icons.check, size: 18),
                const SizedBox(width: 6),
                Expanded(child: Text(item)),
              ],
            ),
          ),
      ],
    );
  }
}

/// Shared "no nasne registered yet" guidance (plan 86.4): the same
/// view on every tab, with a button that jumps to the settings tab
/// where registration happens.
class NoDeviceView extends StatelessWidget {
  const NoDeviceView({super.key, required this.onRegister});

  final VoidCallback onRegister;

  @override
  Widget build(BuildContext context) {
    return Center(
      child: Padding(
        padding: const EdgeInsets.all(24),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            const Icon(Icons.tv_off_outlined, size: 48),
            const SizedBox(height: 16),
            const Text('nasne が登録されていません'),
            const SizedBox(height: 8),
            const Text(
              '使うには、まず nasne を登録してください。設定画面で探して登録できます。',
              textAlign: TextAlign.center,
            ),
            const SizedBox(height: 16),
            FilledButton.icon(
              onPressed: onRegister,
              icon: const Icon(Icons.settings),
              label: const Text('設定で登録する'),
            ),
          ],
        ),
      ),
    );
  }
}

/// Dismisses the software keyboard when a tap lands outside
/// the focused text field (plan 54). The app wraps its whole
/// UI in this (see main.dart): the field screens had no
/// unfocus path at all — no tap-outside handling, no done
/// action — so on iOS, whose keyboard offers no dismiss key
/// for these input types, opening a field (the manual
/// registration field was the reported case) trapped the
/// keyboard on screen with no way to close it.
class KeyboardDismissOnTap extends StatelessWidget {
  const KeyboardDismissOnTap({super.key, required this.child});

  final Widget child;

  @override
  Widget build(BuildContext context) {
    return GestureDetector(
      behavior: HitTestBehavior.translucent,
      onTap: () => FocusScope.of(context).unfocus(),
      child: child,
    );
  }
}

/// Fire TV D-pad friendly text input box that avoids exposing a raw
/// [TextField] directly on screen (which causes FireTVIME to pop up and trap
/// D-pad focus on hover). Opens a dedicated input dialog only on explicit
/// activation (Select / Enter / tap).
class FireTvTextInputField extends StatefulWidget {
  const FireTvTextInputField({
    super.key,
    required this.controller,
    this.labelText,
    this.hintText,
    this.dialogTitle,
    this.prefixIcon,
    this.suffixText,
    this.keyboardType,
    this.textInputAction = TextInputAction.done,
    this.minLines = 1,
    this.maxLines = 1,
    this.autocorrect = true,
    this.enableSuggestions = true,
    this.showClearButton = false,
    this.onChanged,
    this.onSubmitted,
  });

  final TextEditingController controller;
  final String? labelText;
  final String? hintText;
  final String? dialogTitle;
  final IconData? prefixIcon;
  final String? suffixText;
  final TextInputType? keyboardType;
  final TextInputAction textInputAction;
  final int minLines;
  final int maxLines;
  final bool autocorrect;
  final bool enableSuggestions;
  final bool showClearButton;
  final ValueChanged<String>? onChanged;
  final ValueChanged<String>? onSubmitted;

  @override
  State<FireTvTextInputField> createState() => _FireTvTextInputFieldState();
}

class _FireTvTextInputFieldState extends State<FireTvTextInputField> {
  final FocusNode _focusNode = FocusNode(debugLabel: 'fireTvTextInput');
  bool _focused = false;

  @override
  void initState() {
    super.initState();
    widget.controller.addListener(_onControllerChanged);
  }

  @override
  void didUpdateWidget(covariant FireTvTextInputField oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.controller != widget.controller) {
      oldWidget.controller.removeListener(_onControllerChanged);
      widget.controller.addListener(_onControllerChanged);
    }
  }

  @override
  void dispose() {
    widget.controller.removeListener(_onControllerChanged);
    _focusNode.dispose();
    super.dispose();
  }

  void _onControllerChanged() {
    if (mounted) setState(() {});
  }

  Future<void> _openInputDialog() async {
    final result = await showDialog<String>(
      context: context,
      builder: (_) => _FireTvTextInputDialog(
        title:
            widget.dialogTitle ?? widget.labelText ?? widget.hintText ?? '入力',
        initialValue: widget.controller.text,
        hintText: widget.hintText,
        suffixText: widget.suffixText,
        keyboardType: widget.keyboardType,
        textInputAction: widget.textInputAction,
        minLines: widget.minLines,
        maxLines: widget.maxLines,
        autocorrect: widget.autocorrect,
        enableSuggestions: widget.enableSuggestions,
      ),
    );
    if (!mounted) return;
    if (result != null) {
      widget.controller.value = TextEditingValue(
        text: result,
        selection: TextSelection.collapsed(offset: result.length),
      );
      widget.onChanged?.call(result);
      widget.onSubmitted?.call(result);
    }
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (mounted) _focusNode.requestFocus();
    });
  }

  void _clear() {
    widget.controller.clear();
    widget.onChanged?.call('');
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final isDark = theme.brightness == Brightness.dark;
    final text = widget.controller.text;
    final hasText = text.isNotEmpty;
    final borderColor = _focused
        ? (isDark ? Colors.amberAccent : Colors.amber)
        : theme.colorScheme.outlineVariant;
    return Row(
      crossAxisAlignment: CrossAxisAlignment.center,
      children: [
        Expanded(
          child: InkWell(
            focusNode: _focusNode,
            onFocusChange: (focused) {
              if (_focused != focused) setState(() => _focused = focused);
            },
            borderRadius: BorderRadius.circular(8),
            onTap: _openInputDialog,
            child: Container(
              padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
              decoration: BoxDecoration(
                color: theme.colorScheme.surfaceContainerLow,
                borderRadius: BorderRadius.circular(8),
                border: Border.all(
                  color: borderColor,
                  width: _focused ? 3 : 1,
                ),
              ),
              child: Row(
                children: [
                  if (widget.prefixIcon != null) ...[
                    Icon(
                      widget.prefixIcon,
                      size: 20,
                      color: theme.colorScheme.onSurfaceVariant,
                    ),
                    const SizedBox(width: 10),
                  ],
                  Expanded(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        if (widget.labelText != null)
                          Padding(
                            padding: const EdgeInsets.only(bottom: 2),
                            child: Text(
                              widget.labelText!,
                              style: theme.textTheme.labelSmall?.copyWith(
                                color: theme.colorScheme.onSurfaceVariant,
                              ),
                            ),
                          ),
                        Text(
                          hasText ? text : (widget.hintText ?? '決定キーで入力'),
                          maxLines: widget.maxLines > 1 ? 2 : 1,
                          overflow: TextOverflow.ellipsis,
                          style: theme.textTheme.bodyMedium?.copyWith(
                            color: hasText
                                ? theme.colorScheme.onSurface
                                : theme.colorScheme.onSurfaceVariant,
                          ),
                        ),
                      ],
                    ),
                  ),
                  if (widget.suffixText != null && hasText) ...[
                    const SizedBox(width: 4),
                    Text(
                      widget.suffixText!,
                      style: theme.textTheme.bodySmall?.copyWith(
                        color: theme.colorScheme.onSurfaceVariant,
                      ),
                    ),
                  ],
                  const SizedBox(width: 8),
                  Icon(
                    Icons.edit_outlined,
                    size: 18,
                    color: theme.colorScheme.onSurfaceVariant,
                  ),
                ],
              ),
            ),
          ),
        ),
        if (widget.showClearButton && hasText) ...[
          const SizedBox(width: 4),
          IconButton(
            icon: const Icon(Icons.clear),
            tooltip: 'クリア',
            onPressed: _clear,
          ),
        ],
      ],
    );
  }
}

class _FireTvTextInputDialog extends StatefulWidget {
  const _FireTvTextInputDialog({
    required this.title,
    required this.initialValue,
    this.hintText,
    this.suffixText,
    this.keyboardType,
    this.textInputAction = TextInputAction.done,
    this.minLines = 1,
    this.maxLines = 1,
    this.autocorrect = true,
    this.enableSuggestions = true,
  });

  final String title;
  final String initialValue;
  final String? hintText;
  final String? suffixText;
  final TextInputType? keyboardType;
  final TextInputAction textInputAction;
  final int minLines;
  final int maxLines;
  final bool autocorrect;
  final bool enableSuggestions;

  @override
  State<_FireTvTextInputDialog> createState() => _FireTvTextInputDialogState();
}

class _FireTvTextInputDialogState extends State<_FireTvTextInputDialog> {
  late final TextEditingController _controller;

  @override
  void initState() {
    super.initState();
    _controller = TextEditingController(text: widget.initialValue);
  }

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return AlertDialog(
      title: Text(widget.title),
      content: SingleChildScrollView(
        child: TextField(
          controller: _controller,
          autofocus: true,
          keyboardType: widget.keyboardType,
          textInputAction: widget.textInputAction,
          minLines: widget.minLines,
          maxLines: widget.maxLines,
          autocorrect: widget.autocorrect,
          enableSuggestions: widget.enableSuggestions,
          decoration: InputDecoration(
            border: const OutlineInputBorder(),
            hintText: widget.hintText,
            suffixText: widget.suffixText,
          ),
          onSubmitted: widget.maxLines == 1
              ? (value) => Navigator.of(context).pop(value)
              : null,
        ),
      ),
      actions: [
        TextButton(
          onPressed: _controller.clear,
          child: const Text('クリア'),
        ),
        TextButton(
          onPressed: () => Navigator.of(context).pop(null),
          child: const Text('キャンセル'),
        ),
        FilledButton(
          onPressed: () => Navigator.of(context).pop(_controller.text),
          child: const Text('決定'),
        ),
      ],
    );
  }
}
