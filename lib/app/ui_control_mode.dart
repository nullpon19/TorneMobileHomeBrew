/// UI control mode selection (TV D-pad vs touch vs desktop mouse/keyboard).
///
/// The app shares a single codebase across Fire TV / Android TV, Android
/// phones/tablets, iOS / iPadOS, macOS, and Windows. By default (`auto`), the
/// control mode is inferred from the host OS and Android TV device flags; users
/// can also override it manually from Settings -> 表示 -> 操作モード.
library;

import 'dart:io';

enum UiControlModePreference {
  auto('auto', '自動'),
  tv('tv', 'TVリモコン'),
  touch('touch', 'タッチ'),
  desktop('desktop', 'デスクトップ');

  const UiControlModePreference(this.storageValue, this.label);

  final String storageValue;
  final String label;

  static UiControlModePreference fromStorage(String? raw) {
    for (final value in values) {
      if (value.storageValue == raw) return value;
    }
    return UiControlModePreference.auto;
  }
}

enum UiControlMode {
  tv('TVリモコン'),
  touch('タッチ'),
  desktop('デスクトップ');

  const UiControlMode(this.label);

  final String label;

  bool get isTv => this == UiControlMode.tv;
  bool get isTouch => this == UiControlMode.touch;
  bool get isDesktop => this == UiControlMode.desktop;
}

UiControlMode resolveUiControlMode({
  required UiControlModePreference preference,
  required bool isAndroid,
  required bool isAndroidTv,
  required bool isIOS,
  required bool isDesktop,
}) {
  switch (preference) {
    case UiControlModePreference.tv:
      return UiControlMode.tv;
    case UiControlModePreference.touch:
      return UiControlMode.touch;
    case UiControlModePreference.desktop:
      return UiControlMode.desktop;
    case UiControlModePreference.auto:
      if (isAndroid) {
        return isAndroidTv ? UiControlMode.tv : UiControlMode.touch;
      }
      if (isIOS) {
        return UiControlMode.touch;
      }
      if (isDesktop) {
        return UiControlMode.desktop;
      }
      return UiControlMode.touch;
  }
}

UiControlMode detectPlatformDefaultUiControlMode({required bool isAndroidTv}) {
  return resolveUiControlMode(
    preference: UiControlModePreference.auto,
    isAndroid: Platform.isAndroid,
    isAndroidTv: isAndroidTv,
    isIOS: Platform.isIOS,
    isDesktop: Platform.isMacOS || Platform.isWindows || Platform.isLinux,
  );
}
