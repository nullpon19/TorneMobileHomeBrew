/// Home screen 3D assistant overlay ("ナスカ") with automatic bottom avoidance,
/// "ゲス" speech bubbles, TV focus-transparency, and classic Office assistant
/// "お前を消す方法" dialog on touch/desktop platforms.
library;

import 'dart:async';
import 'dart:math' as math;

import 'package:flutter/foundation.dart';
import 'package:flutter/scheduler.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:material_ui/material_ui.dart';

import '../app/providers.dart';
import '../app/state.dart';
import '../core/core.dart';
import 'home_assistant_3d.dart';
import 'multi_nasne_policy.dart';

const String nasukaDismissQuery = 'お前を消す方法';

/// Builds a tornef-inspired Nasuka line ending in "ゲス" using already-cached
/// Home status data (zero extra network requests).
String buildNasukaComment({
  DateTime? now,
  List<HddDetail>? hdds,
  LiveStatus? liveStatus,
  List<RecNgItem>? recNg,
  Set<String> dismissedRecNgKeys = const {},
  RegisteredNasne? reg,
  int seed = 0,
}) {
  final pool = <String>[];

  if (hdds != null) {
    for (final d in hdds) {
      final info = d.info;
      if (info == null || info.totalBytes <= 0) continue;
      final freeRatio = info.freeBytes / info.totalBytes;
      if (freeRatio < 0.15) {
        pool.add('HDD の空きがピンチでゲス！そろそろ整理するでゲスよ…');
      } else if (freeRatio >= 0.50) {
        pool.add('HDD の空き、まだまだ余裕でゲス！録りまくるでゲス！');
      }
      break;
    }
  }

  if (recNg != null && reg != null) {
    final visibleNg = recNg
        .where((item) => !dismissedRecNgKeys.contains(recNgDismissKey(reg, item)))
        .length;
    if (visibleNg > 0) {
      pool.add('録画失敗が $visibleNg 件あるみたいでゲス…確認しておくでゲス！');
    }
  }

  final presentTitle = liveStatus?.eitPf.present?.title?.trim();
  if (presentTitle != null && presentTitle.isNotEmpty) {
    final clipped = presentTitle.length > 18
        ? '${presentTitle.substring(0, 18)}…'
        : presentTitle;
    pool.add('いまは「$clipped」を放送中でゲスな〜');
  }

  final hour = (now ?? DateTime.now()).hour;
  if (hour >= 5 && hour < 11) {
    pool.add('おはようございますでゲス！今日も良い番組に出会えるでゲスな〜');
  } else if (hour >= 11 && hour < 17) {
    pool.add('こんにちはでゲス！お昼の番組チェックもおまかせでゲス！');
  } else if (hour >= 17 && hour < 23) {
    pool.add('こんばんはでゲス！今夜は見逃せない番組あるでゲスか？');
  } else {
    pool.add('こんな深夜まで起きてるんでゲスか？夜更かし仲間でゲスな〜');
  }

  pool.addAll(const [
    'オイラはナスカでゲス！よろしくでゲス！',
    'ナスじゃなくてナスカでゲスよ…たぶん',
    'ひれをバタバタして待ってるでゲス！',
    'くるっと回ると背中もカラフルなんでゲス！',
    'ホームの隅っこ、意外と居心地いいでゲスな〜',
    '5回連打されるとついつい出てきちゃうんでゲス…',
  ]);

  final idx = seed.abs() % pool.length;
  return pool[idx];
}

class HomeAssistantOverlay extends ConsumerStatefulWidget {
  const HomeAssistantOverlay({
    super.key,
    required this.reg,
    required this.avoidBottomListenable,
  });

  final RegisteredNasne? reg;
  final ValueListenable<bool> avoidBottomListenable;

  @override
  ConsumerState<HomeAssistantOverlay> createState() =>
      _HomeAssistantOverlayState();
}

class _HomeAssistantOverlayState extends ConsumerState<HomeAssistantOverlay>
    with SingleTickerProviderStateMixin {
  static const Duration _enterDuration = Duration(milliseconds: 1900);
  static const Duration _exitDuration = Duration(milliseconds: 2300);

  late final Ticker _ticker;
  Duration _lastTick = Duration.zero;
  double _idleTime = 0.0;
  double _stageSeconds = 0.0;
  NasukaAction _action = NasukaAction.float;
  double _actionSeconds = 0.0;
  double _actionDuration = 1.0;

  HomeAssistantStage _lastStage = HomeAssistantStage.hidden;
  int _lastSeq = -1;
  bool _officeBalloonOpen = false;
  bool _autoDismissSad = false;
  String? _speechText;
  int _commentCounter = 0;

  Timer? _actionTimer;
  Timer? _speechTimer;
  Timer? _speechHideTimer;
  Timer? _entrySpeechTimer;

  final math.Random _rng = math.Random();
  final ValueNotifier<Nasuka3dPose> _poseNotifier = ValueNotifier<Nasuka3dPose>(
    const Nasuka3dPose(
      stage: HomeAssistantStage.hidden,
      stageProgress: 0.0,
      idleTime: 0.0,
      action: NasukaAction.float,
      actionProgress: 0.0,
    ),
  );

  @override
  void initState() {
    super.initState();
    _ticker = createTicker(_onTick);
  }

  @override
  void dispose() {
    _cancelAllTimers();
    _ticker.dispose();
    _poseNotifier.dispose();
    super.dispose();
  }

  void _cancelAllTimers() {
    _actionTimer?.cancel();
    _actionTimer = null;
    _speechTimer?.cancel();
    _speechTimer = null;
    _speechHideTimer?.cancel();
    _speechHideTimer = null;
    _entrySpeechTimer?.cancel();
    _entrySpeechTimer = null;
  }

  void _syncTicker(HomeAssistantStage stage, bool tickerEnabled) {
    final shouldRun = stage != HomeAssistantStage.hidden && tickerEnabled;
    if (shouldRun && !_ticker.isActive) {
      _lastTick = Duration.zero;
      _ticker.start();
    } else if (!shouldRun && _ticker.isActive) {
      _ticker.stop();
    }
  }

  void _handleStageTransition(HomeAssistantState state) {
    if (state.stage == _lastStage && state.triggerSeq == _lastSeq) return;
    _lastStage = state.stage;
    _lastSeq = state.triggerSeq;

    switch (state.stage) {
      case HomeAssistantStage.hidden:
        _cancelAllTimers();
        _stageSeconds = 0.0;
        _action = NasukaAction.float;
        _actionSeconds = 0.0;
        _autoDismissSad = false;
        if (_officeBalloonOpen || _speechText != null) {
          WidgetsBinding.instance.addPostFrameCallback((_) {
            if (!mounted) return;
            setState(() {
              _officeBalloonOpen = false;
              _speechText = null;
            });
          });
        }
      case HomeAssistantStage.entering:
        _cancelAllTimers();
        _stageSeconds = 0.0;
        _action = NasukaAction.float;
        _actionSeconds = 0.0;
        _autoDismissSad = false;
        if (_officeBalloonOpen || _speechText != null) {
          WidgetsBinding.instance.addPostFrameCallback((_) {
            if (!mounted) return;
            setState(() {
              _officeBalloonOpen = false;
              _speechText = null;
            });
          });
        }
        _entrySpeechTimer = Timer(const Duration(milliseconds: 550), () {
          if (!mounted) return;
          if (ref.read(homeAssistantProvider).stage ==
                  HomeAssistantStage.entering ||
              ref.read(homeAssistantProvider).stage ==
                  HomeAssistantStage.idle) {
            _showComment('ざっぱーん！オイラはナスカでゲス！よろしくでゲス！');
          }
        });
      case HomeAssistantStage.idle:
        _stageSeconds = 0.0;
        _autoDismissSad = false;
        _scheduleNextAction();
        _scheduleNextSpeech();
      case HomeAssistantStage.dismissingAuto:
        _cancelAllTimers();
        _stageSeconds = 0.0;
        _action = NasukaAction.float;
        _actionSeconds = 0.0;
        _autoDismissSad = false;
        if (_officeBalloonOpen || _speechText != null) {
          WidgetsBinding.instance.addPostFrameCallback((_) {
            if (!mounted) return;
            setState(() {
              _officeBalloonOpen = false;
              _speechText = null;
            });
          });
        }
      case HomeAssistantStage.exiting:
        _cancelAllTimers();
        _stageSeconds = 0.0;
        _action = NasukaAction.float;
        _actionSeconds = 0.0;
        _autoDismissSad = false;
        if (_officeBalloonOpen || _speechText != null) {
          WidgetsBinding.instance.addPostFrameCallback((_) {
            if (!mounted) return;
            setState(() {
              _officeBalloonOpen = false;
              _speechText = null;
            });
          });
        }
    }
    _emitPose(state.stage);
  }

  void _scheduleNextAction() {
    _actionTimer?.cancel();
    final delayMs = 4500 + _rng.nextInt(3000);
    _actionTimer = Timer(Duration(milliseconds: delayMs), () {
      if (!mounted) return;
      final st = ref.read(homeAssistantProvider).stage;
      if (st != HomeAssistantStage.idle) return;
      const choices = [
        NasukaAction.wink,
        NasukaAction.flap,
        NasukaAction.spin,
        NasukaAction.swim,
      ];
      _action = choices[_rng.nextInt(choices.length)];
      _actionSeconds = 0.0;
      _actionDuration = switch (_action) {
        NasukaAction.wink => 1.1,
        NasukaAction.flap => 1.35,
        NasukaAction.spin => 1.4,
        NasukaAction.swim => 2.1,
        NasukaAction.float => 1.0,
      };
    });
  }

  void _scheduleNextSpeech() {
    _speechTimer?.cancel();
    final delayMs = 10500 + _rng.nextInt(5500);
    _speechTimer = Timer(Duration(milliseconds: delayMs), () {
      if (!mounted) return;
      final st = ref.read(homeAssistantProvider).stage;
      if (st != HomeAssistantStage.idle) return;
      if (!_officeBalloonOpen) {
        final reg = widget.reg;
        final text = buildNasukaComment(
          hdds: reg == null ? null : ref.read(hddDetailsProvider(reg)).value,
          liveStatus: reg == null ? null : ref.read(liveStatusProvider(reg)).value,
          recNg: reg == null ? null : ref.read(recNgProvider(reg)).value,
          dismissedRecNgKeys: ref.read(dismissedRecNgKeysProvider),
          reg: reg,
          seed: _commentCounter++,
        );
        _showComment(text);
      }
      _scheduleNextSpeech();
    });
  }

  void _showComment(String text) {
    _speechHideTimer?.cancel();
    setState(() => _speechText = text);
    _speechHideTimer = Timer(const Duration(milliseconds: 5200), () {
      if (!mounted) return;
      setState(() => _speechText = null);
    });
  }

  void _onTick(Duration elapsed) {
    if (!mounted) return;
    final dtSec = _lastTick == Duration.zero
        ? (1.0 / 60.0)
        : ((elapsed - _lastTick).inMicroseconds / 1000000.0).clamp(0.0, 1.0);
    _lastTick = elapsed;

    final state = ref.read(homeAssistantProvider);
    if (state.stage == HomeAssistantStage.hidden) {
      _syncTicker(state.stage, false);
      return;
    }

    _idleTime += dtSec;

    if (state.stage == HomeAssistantStage.entering) {
      _stageSeconds += dtSec;
      if (_stageSeconds >= _enterDuration.inMilliseconds / 1000.0) {
        _emitPose(HomeAssistantStage.entering);
        ref.read(homeAssistantProvider.notifier).markEntered();
        return;
      }
    } else if (state.stage == HomeAssistantStage.exiting) {
      _stageSeconds += dtSec;
      if (_stageSeconds >= _exitDuration.inMilliseconds / 1000.0) {
        _emitPose(HomeAssistantStage.exiting);
        ref.read(homeAssistantProvider.notifier).markExited();
        return;
      }
    } else if (_action != NasukaAction.float) {
      _actionSeconds += dtSec;
      if (_actionSeconds >= _actionDuration) {
        _action = NasukaAction.float;
        _actionSeconds = 0.0;
        _scheduleNextAction();
      }
    }

    _emitPose(state.stage);
  }

  void _emitPose(HomeAssistantStage stage) {
    final stageProgress = switch (stage) {
      HomeAssistantStage.entering =>
        (_stageSeconds / (_enterDuration.inMilliseconds / 1000.0)).clamp(0.0, 1.0),
      HomeAssistantStage.exiting =>
        (_stageSeconds / (_exitDuration.inMilliseconds / 1000.0)).clamp(0.0, 1.0),
      _ => 0.0,
    };
    final actionProgress = _action == NasukaAction.float || _actionDuration <= 0
        ? 0.0
        : (_actionSeconds / _actionDuration).clamp(0.0, 1.0);
    _poseNotifier.value = Nasuka3dPose(
      stage: stage,
      stageProgress: stageProgress,
      idleTime: _idleTime,
      action: _action,
      actionProgress: actionProgress,
      speaking:
          _speechText != null &&
          stage != HomeAssistantStage.exiting &&
          stage != HomeAssistantStage.dismissingAuto,
      sad:
          stage == HomeAssistantStage.exiting ||
          (stage == HomeAssistantStage.dismissingAuto && _autoDismissSad),
    );
  }

  void _openOfficeBalloon() {
    if (_officeBalloonOpen) return;
    _speechHideTimer?.cancel();
    setState(() {
      _speechText = null;
      _officeBalloonOpen = true;
    });
  }

  void _closeOfficeBalloon() {
    if (!_officeBalloonOpen) return;
    setState(() => _officeBalloonOpen = false);
  }

  void _triggerDismissFromOffice() {
    setState(() {
      _officeBalloonOpen = false;
      _speechText = null;
      _autoDismissSad = false;
    });
    ref.read(homeAssistantProvider.notifier).startDismiss();
  }

  @override
  Widget build(BuildContext context) {
    final assistant = ref.watch(homeAssistantProvider);
    final isTv = ref.watch(uiControlModeProvider).isTv;
    final tickerEnabled = TickerMode.valuesOf(context).enabled;

    _handleStageTransition(assistant);
    _syncTicker(assistant.stage, tickerEnabled);

    if (assistant.stage == HomeAssistantStage.hidden) {
      return const SizedBox.shrink();
    }

    final width = MediaQuery.sizeOf(context).width;
    final charSize = width < 480
        ? const Size(132, 116)
        : const Size(164, 144);
    // Nasuka's head sits left-of-center (~62% from the right edge of charSize).
    final double tailTipFromRight = charSize.width * 0.62;
    final showAutoDismissBalloon =
        assistant.stage == HomeAssistantStage.dismissingAuto;
    final showInteractiveOfficeBalloon =
        !isTv &&
        _officeBalloonOpen &&
        assistant.stage != HomeAssistantStage.exiting &&
        assistant.stage != HomeAssistantStage.dismissingAuto;

    Widget buildCharacterArea({required bool interactive}) {
      final canvas = RepaintBoundary(
        child: SizedBox(
          width: charSize.width,
          height: charSize.height,
          child: ValueListenableBuilder<Nasuka3dPose>(
            valueListenable: _poseNotifier,
            builder: (context, pose, _) => CustomPaint(
              painter: Nasuka3dPainter(pose: pose),
              size: charSize,
            ),
          ),
        ),
      );
      if (!interactive) return canvas;
      return GestureDetector(
        key: const ValueKey('nasukaCharacterTapTarget'),
        behavior: HitTestBehavior.opaque,
        onTap: () {
          if (assistant.stage == HomeAssistantStage.exiting ||
              assistant.stage == HomeAssistantStage.dismissingAuto) {
            return;
          }
          if (_officeBalloonOpen) {
            _closeOfficeBalloon();
          } else {
            _openOfficeBalloon();
          }
        },
        child: canvas,
      );
    }

    final content = ValueListenableBuilder<bool>(
      valueListenable: widget.avoidBottomListenable,
      builder: (context, avoidBottom, _) {
        final double bottomOffset = avoidBottom ? 124 : 12;
        return AnimatedPositioned(
          key: const ValueKey('nasukaOverlayPosition'),
          duration: const Duration(milliseconds: 280),
          curve: Curves.easeOutCubic,
          right: 12,
          bottom: bottomOffset,
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.end,
            children: [
              if (showAutoDismissBalloon)
                _ClassicOfficeBalloon(
                  key: ValueKey('nasukaAutoDismissBalloon_${assistant.triggerSeq}'),
                  tailTipFromRight: tailTipFromRight,
                  autoPlayDismiss: true,
                  onSearchPressedVisual: () {
                    if (!mounted) return;
                    setState(() => _autoDismissSad = true);
                    _emitPose(ref.read(homeAssistantProvider).stage);
                  },
                  onDismissTriggered: _triggerDismissFromOffice,
                )
              else if (showInteractiveOfficeBalloon)
                _ClassicOfficeBalloon(
                  tailTipFromRight: tailTipFromRight,
                  onDismissTriggered: _triggerDismissFromOffice,
                )
              else if (_speechText != null &&
                  assistant.stage != HomeAssistantStage.exiting)
                _NasukaSpeechBubble(
                  text: _speechText!,
                  tailTipFromRight: tailTipFromRight,
                ),
              Align(
                heightFactor: 0.88,
                alignment: Alignment.bottomCenter,
                child: buildCharacterArea(interactive: !isTv),
              ),
            ],
          ),
        );
      },
    );

    if (isTv) {
      return ExcludeFocus(
        excluding: true,
        child: IgnorePointer(
          ignoring: true,
          child: Stack(
            fit: StackFit.expand,
            clipBehavior: Clip.none,
            children: [content],
          ),
        ),
      );
    }

    return Stack(
      fit: StackFit.expand,
      clipBehavior: Clip.none,
      children: [
        if (showInteractiveOfficeBalloon)
          Positioned.fill(
            child: GestureDetector(
              behavior: HitTestBehavior.translucent,
              onTap: _closeOfficeBalloon,
            ),
          ),
        content,
      ],
    );
  }
}

class _NasukaSpeechBubble extends StatelessWidget {
  const _NasukaSpeechBubble({
    required this.text,
    required this.tailTipFromRight,
  });

  final String text;
  final double tailTipFromRight;

  @override
  Widget build(BuildContext context) {
    return _UnifiedSpeechBalloon(
      tailTipFromRight: tailTipFromRight,
      minWidth: math.max(150.0, tailTipFromRight + 34.0),
      maxWidth: 248.0,
      shadowBlur: 6.0,
      child: Text(
        text,
        style: const TextStyle(
          color: Color(0xFF111111),
          fontSize: 12.5,
          height: 1.3,
        ),
      ),
    );
  }
}

class _ClassicOfficeBalloon extends StatefulWidget {
  const _ClassicOfficeBalloon({
    super.key,
    required this.onDismissTriggered,
    required this.tailTipFromRight,
    this.autoPlayDismiss = false,
    this.onSearchPressedVisual,
  });

  final VoidCallback onDismissTriggered;
  final double tailTipFromRight;
  final bool autoPlayDismiss;
  final VoidCallback? onSearchPressedVisual;

  @override
  State<_ClassicOfficeBalloon> createState() => _ClassicOfficeBalloonState();
}

class _ClassicOfficeBalloonState extends State<_ClassicOfficeBalloon> {
  final TextEditingController _controller = TextEditingController();
  final FocusNode _inputFocusNode = FocusNode();
  Timer? _typeTimer;
  Timer? _caretTimer;
  Timer? _autoDelayTimer;
  Timer? _autoPressTimer;
  Timer? _autoSubmitTimer;
  int _typedLength = 0;
  bool _optionsMenuVisible = false;
  bool _searchButtonPressed = false;
  bool _caretVisible = true;

  String get _lockedText => nasukaDismissQuery.substring(0, _typedLength);

  @override
  void initState() {
    super.initState();
    if (widget.autoPlayDismiss) {
      _caretTimer = Timer.periodic(const Duration(milliseconds: 450), (_) {
        if (!mounted) return;
        setState(() => _caretVisible = !_caretVisible);
      });
      _autoDelayTimer = Timer(const Duration(milliseconds: 350), _startTyping);
    } else {
      _startTyping();
    }
  }

  void _startTyping() {
    final step = widget.autoPlayDismiss
        ? const Duration(milliseconds: 130)
        : const Duration(milliseconds: 75);
    _typeTimer = Timer.periodic(step, (timer) {
      if (!mounted) {
        timer.cancel();
        return;
      }
      if (_typedLength >= nasukaDismissQuery.length) {
        timer.cancel();
        _typeTimer = null;
        if (widget.autoPlayDismiss) {
          _scheduleAutoSearchPress();
        }
        return;
      }
      setState(() {
        _typedLength++;
        if (!widget.autoPlayDismiss) {
          _syncControllerToLockedText();
        }
      });
    });
  }

  void _scheduleAutoSearchPress() {
    _autoPressTimer?.cancel();
    _autoPressTimer = Timer(const Duration(milliseconds: 550), () {
      if (!mounted) return;
      setState(() => _searchButtonPressed = true);
      widget.onSearchPressedVisual?.call();
      _autoSubmitTimer?.cancel();
      _autoSubmitTimer = Timer(const Duration(milliseconds: 420), () {
        if (!mounted) return;
        widget.onDismissTriggered();
      });
    });
  }

  @override
  void dispose() {
    _typeTimer?.cancel();
    _typeTimer = null;
    _caretTimer?.cancel();
    _caretTimer = null;
    _autoDelayTimer?.cancel();
    _autoDelayTimer = null;
    _autoPressTimer?.cancel();
    _autoPressTimer = null;
    _autoSubmitTimer?.cancel();
    _autoSubmitTimer = null;
    _controller.dispose();
    _inputFocusNode.dispose();
    super.dispose();
  }

  void _syncControllerToLockedText() {
    final target = _lockedText;
    _controller.value = TextEditingValue(
      text: target,
      selection: TextSelection.collapsed(offset: target.length),
    );
  }

  @override
  Widget build(BuildContext context) {
    return Material(
      color: Colors.transparent,
      child: _UnifiedSpeechBalloon(
        tailTipFromRight: widget.tailTipFromRight,
        padding: const EdgeInsets.fromLTRB(12, 10, 12, 10),
        minWidth: 258.0,
        maxWidth: 268.0,
        shadowBlur: 8.0,
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            const Text(
              '何について調べますか？',
              style: TextStyle(
                color: Color(0xFF111111),
                fontSize: 13.5,
                fontWeight: FontWeight.w500,
              ),
            ),
            const SizedBox(height: 8),
            Container(
              width: double.infinity,
              decoration: BoxDecoration(
                color: Colors.white,
                border: Border.all(
                  color: const Color(0xFF7F9DB9),
                  width: 1.2,
                ),
              ),
              padding: const EdgeInsets.symmetric(
                horizontal: 6,
                vertical: 4,
              ),
              child: widget.autoPlayDismiss
                  ? ConstrainedBox(
                      constraints: const BoxConstraints(minHeight: 34),
                      child: Text(
                        '$_lockedText${_caretVisible ? '|' : ''}',
                        key: const ValueKey('nasukaAutoDismissInputText'),
                        maxLines: 2,
                        style: const TextStyle(
                          color: Color(0xFF111111),
                          fontSize: 13,
                          height: 1.3,
                        ),
                      ),
                    )
                  : TextField(
                      key: const ValueKey('nasukaOfficeInput'),
                      controller: _controller,
                      focusNode: _inputFocusNode,
                      maxLines: 2,
                      minLines: 2,
                      cursorColor: const Color(0xFF111111),
                      style: const TextStyle(
                        color: Color(0xFF111111),
                        fontSize: 13,
                        height: 1.3,
                      ),
                      inputFormatters: [
                        _LockedPrefixInputFormatter(() => _lockedText),
                      ],
                      decoration: const InputDecoration(
                        isDense: true,
                        border: InputBorder.none,
                        focusedBorder: InputBorder.none,
                        enabledBorder: InputBorder.none,
                        contentPadding: EdgeInsets.zero,
                      ),
                    ),
            ),
            const SizedBox(height: 8),
            Row(
              mainAxisAlignment: MainAxisAlignment.spaceBetween,
              children: [
                _ClassicWinButton(
                  key: const ValueKey('nasukaOfficeOptionsButton'),
                  prefix: 'オプション(',
                  hotkey: 'O',
                  suffix: ')',
                  onPressed: widget.autoPlayDismiss
                      ? null
                      : () {
                          setState(
                            () => _optionsMenuVisible = !_optionsMenuVisible,
                          );
                        },
                ),
                _ClassicWinButton(
                  key: const ValueKey('nasukaOfficeSearchButton'),
                  prefix: '検索(',
                  hotkey: 'S',
                  suffix: ')',
                  pressed: _searchButtonPressed,
                  onPressed: widget.autoPlayDismiss
                      ? null
                      : widget.onDismissTriggered,
                ),
              ],
            ),
            if (_optionsMenuVisible) ...[
              const SizedBox(height: 6),
              Container(
                width: 120,
                decoration: BoxDecoration(
                  color: const Color(0xFFF6F5EE),
                  border: Border.all(
                    color: const Color(0xFF666666),
                    width: 1.0,
                  ),
                  boxShadow: const [
                    BoxShadow(
                      color: Color(0x33000000),
                      blurRadius: 3,
                      offset: Offset(1, 2),
                    ),
                  ],
                ),
                child: InkWell(
                  key: const ValueKey('nasukaOfficeSayonaraItem'),
                  onTap: widget.onDismissTriggered,
                  child: const Padding(
                    padding: EdgeInsets.symmetric(
                      horizontal: 10,
                      vertical: 6,
                    ),
                    child: Text(
                      'さようなら',
                      style: TextStyle(
                        color: Color(0xFF111111),
                        fontSize: 12.5,
                      ),
                    ),
                  ),
                ),
              ),
            ],
          ],
        ),
      ),
    );
  }
}

class _LockedPrefixInputFormatter extends TextInputFormatter {
  _LockedPrefixInputFormatter(this.readTarget);

  final String Function() readTarget;

  @override
  TextEditingValue formatEditUpdate(
    TextEditingValue oldValue,
    TextEditingValue newValue,
  ) {
    final target = readTarget();
    return TextEditingValue(
      text: target,
      selection: TextSelection.collapsed(offset: target.length),
    );
  }
}

class _ClassicWinButton extends StatelessWidget {
  const _ClassicWinButton({
    super.key,
    required this.prefix,
    required this.hotkey,
    required this.suffix,
    required this.onPressed,
    this.pressed = false,
  });

  final String prefix;
  final String hotkey;
  final String suffix;
  final VoidCallback? onPressed;
  final bool pressed;

  @override
  Widget build(BuildContext context) {
    return InkWell(
      onTap: onPressed,
      child: Transform.translate(
        offset: pressed ? const Offset(0, 1) : Offset.zero,
        child: Container(
          constraints: const BoxConstraints(minWidth: 96),
          padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 5),
          decoration: BoxDecoration(
            color: pressed ? const Color(0xFFDDDCD0) : const Color(0xFFF3F2E8),
            borderRadius: BorderRadius.circular(3),
            border: Border.all(
              color: pressed ? const Color(0xFF222222) : const Color(0xFF555555),
              width: pressed ? 1.4 : 1.0,
            ),
            boxShadow: pressed
                ? const []
                : const [
                    BoxShadow(
                      color: Color(0x22000000),
                      blurRadius: 1,
                      offset: Offset(0, 1),
                    ),
                  ],
          ),
          alignment: Alignment.center,
          child: Text.rich(
            TextSpan(
              style: const TextStyle(color: Color(0xFF111111), fontSize: 12),
              children: [
                TextSpan(text: prefix),
                TextSpan(
                  text: hotkey,
                  style: const TextStyle(decoration: TextDecoration.underline),
                ),
                TextSpan(text: suffix),
              ],
            ),
          ),
        ),
      ),
    );
  }
}

class _UnifiedSpeechBalloon extends StatelessWidget {
  const _UnifiedSpeechBalloon({
    required this.child,
    required this.tailTipFromRight,
    this.padding = const EdgeInsets.symmetric(horizontal: 10, vertical: 8),
    this.minWidth = 0.0,
    this.maxWidth = 260.0,
    this.shadowBlur = 6.0,
  });

  static const double _tailHeight = 14.0;
  static const double _borderRadius = 10.0;

  final Widget child;
  final double tailTipFromRight;
  final EdgeInsetsGeometry padding;
  final double minWidth;
  final double maxWidth;
  final double shadowBlur;

  @override
  Widget build(BuildContext context) {
    return ConstrainedBox(
      constraints: BoxConstraints(minWidth: minWidth, maxWidth: maxWidth),
      child: CustomPaint(
        painter: _UnifiedBalloonPainter(
          tailTipFromRight: tailTipFromRight,
          shadowBlur: shadowBlur,
        ),
        child: Padding(
          padding: const EdgeInsets.only(bottom: _tailHeight),
          child: Padding(padding: padding, child: child),
        ),
      ),
    );
  }
}

class _UnifiedBalloonPainter extends CustomPainter {
  const _UnifiedBalloonPainter({
    required this.tailTipFromRight,
    required this.shadowBlur,
  });

  static const double _tailHeight = _UnifiedSpeechBalloon._tailHeight;
  static const double _borderRadius = _UnifiedSpeechBalloon._borderRadius;

  final double tailTipFromRight;
  final double shadowBlur;

  @override
  void paint(Canvas canvas, Size size) {
    if (size.width <= 0 || size.height <= _tailHeight) return;
    final bodyBottom = math.max(_borderRadius * 2 + 2.0, size.height - _tailHeight);
    final r = math.min(_borderRadius, math.min(size.width * 0.25, bodyBottom * 0.4));
    final tipX = (size.width - tailTipFromRight).clamp(
      r + 18.0,
      size.width - r - 4.0,
    );
    final baseRight = (tipX - 1.0).clamp(r + 14.0, size.width - r - 2.0);
    final baseLeft = (baseRight - 13.0).clamp(r + 2.0, baseRight - 8.0);

    final path = Path()
      ..moveTo(r, 0)
      ..lineTo(size.width - r, 0)
      ..arcToPoint(
        Offset(size.width, r),
        radius: Radius.circular(r),
        clockwise: true,
      )
      ..lineTo(size.width, bodyBottom - r)
      ..arcToPoint(
        Offset(size.width - r, bodyBottom),
        radius: Radius.circular(r),
        clockwise: true,
      )
      ..lineTo(baseRight, bodyBottom)
      ..lineTo(tipX, size.height)
      ..lineTo(baseLeft, bodyBottom)
      ..lineTo(r, bodyBottom)
      ..arcToPoint(
        Offset(0, bodyBottom - r),
        radius: Radius.circular(r),
        clockwise: true,
      )
      ..lineTo(0, r)
      ..arcToPoint(
        Offset(r, 0),
        radius: Radius.circular(r),
        clockwise: true,
      )
      ..close();

    canvas.drawPath(
      path.shift(const Offset(1.5, 2.5)),
      Paint()
        ..color = const Color(0x38000000)
        ..maskFilter = MaskFilter.blur(BlurStyle.normal, shadowBlur),
    );
    canvas.drawPath(
      path,
      Paint()
        ..color = const Color(0xFFFFFFCC)
        ..style = PaintingStyle.fill
        ..isAntiAlias = true,
    );
    canvas.drawPath(
      path,
      Paint()
        ..color = const Color(0xFF1E1E1E)
        ..style = PaintingStyle.stroke
        ..strokeWidth = 1.5
        ..strokeJoin = StrokeJoin.round
        ..isAntiAlias = true,
    );
  }

  @override
  bool shouldRepaint(covariant _UnifiedBalloonPainter oldDelegate) =>
      oldDelegate.tailTipFromRight != tailTipFromRight ||
      oldDelegate.shadowBlur != shadowBlur;
}
