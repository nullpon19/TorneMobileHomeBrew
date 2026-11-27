/// The app version, embedded in the code at build time (plan 35).
///
/// The settings screen used to carry a hand-written "1.0.0"
/// literal from the first release. Nothing ever updated it, so
/// the screen kept claiming 1.0.0 while the running code was
/// 1.2.x — in the build-13 field test the user concluded they
/// were on an old build and reinstalled one they already had.
///
/// The version therefore lives in exactly this one place and is
/// compiled into the binary. It is deliberately NOT read from the
/// platform bundle at runtime (package_info style): in sideload
/// hosts such as LiveContainer the bundle such a query reaches
/// is the host app's, not this app's, so the answer cannot be
/// trusted there. A test (test/app_version_test.dart) fails if
/// these constants ever drift from pubspec.yaml's `version:`.
library;

/// Version name from pubspec.yaml (`version:`), e.g. `1.3.0`.
const String appVersionName = '1.5.0';

/// Build number from pubspec.yaml (`version:`), e.g. `17`.
const int appBuildNumber = 48;

/// How the settings screen presents the version.
const String appVersionLabel = 'バージョン $appVersionName (ビルド $appBuildNumber)';
