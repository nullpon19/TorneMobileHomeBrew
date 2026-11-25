import AVFoundation
import Flutter
import UIKit

@main
@objc class AppDelegate: FlutterAppDelegate, FlutterImplicitEngineDelegate {
  override func application(
    _ application: UIApplication,
    didFinishLaunchingWithOptions launchOptions: [UIApplication.LaunchOptionsKey: Any]?
  ) -> Bool {
    return super.application(application, didFinishLaunchingWithOptions: launchOptions)
  }

  func didInitializeImplicitFlutterEngine(_ engineBridge: FlutterImplicitEngineBridge) {
    GeneratedPluginRegistrant.register(with: engineBridge.pluginRegistry)
    // Native AKE socket channels (IP TTL 3, plan 28).
    if let akeRegistrar = engineBridge.pluginRegistry.registrar(
      forPlugin: "AkeSocketChannels")
    {
      AkeSocketHub.shared.register(messenger: akeRegistrar.messenger())
    }
    // Native wakelock channel (plan 35).
    if let wakelockRegistrar = engineBridge.pluginRegistry.registrar(
      forPlugin: "WakelockChannels")
    {
      WakelockHub.shared.register(messenger: wakelockRegistrar.messenger())
    }
    // Native share sheet channel (plan 46).
    if let shareRegistrar = engineBridge.pluginRegistry.registrar(
      forPlugin: "ShareChannels")
    {
      ShareHub.shared.register(messenger: shareRegistrar.messenger())
    }
    // Native ARIB built-in chime sound channel.
    if let aribSoundRegistrar = engineBridge.pluginRegistry.registrar(
      forPlugin: "AribSoundChannels")
    {
      AribSoundHub.shared.register(messenger: aribSoundRegistrar.messenger())
    }
  }
}

/// Native wakelock channel (plan 35): flips
/// `UIApplication.isIdleTimerDisabled` and returns the value read
/// back immediately afterwards, so the Dart side can prove from
/// the debug log whether the setting actually stuck.
///
/// This replaces wakelock_plus: in the build-13 field test
/// (iPhone, LiveContainer) the device slept mid-playback although
/// every enable had reported success — the plugin never reads the
/// value back, so a request the platform ignored was
/// indistinguishable from one that worked. Method channel
/// handlers are delivered on the main thread, so touching
/// UIApplication here is safe.
final class WakelockHub {
  static let shared = WakelockHub()

  func register(messenger: FlutterBinaryMessenger) {
    let channel = FlutterMethodChannel(
      name: "com.markun.tmhb/wakelock", binaryMessenger: messenger)
    channel.setMethodCallHandler { call, result in
      switch call.method {
      case "setKeepAwake":
        let args = call.arguments as? [String: Any] ?? [:]
        let keepAwake = args["keepAwake"] as? Bool ?? false
        UIApplication.shared.isIdleTimerDisabled = keepAwake
        result(UIApplication.shared.isIdleTimerDisabled)
      case "getKeepAwake":
        result(UIApplication.shared.isIdleTimerDisabled)
      default:
        result(FlutterMethodNotImplemented)
      }
    }
  }
}

/// Native share sheet channel (plan 46): presents
/// UIActivityViewController for the staged debug log copies, so
/// logs recorded on a directly sideloaded install — whose app
/// container cannot be pulled off the device the way a
/// LiveContainer container can — still leave the device.
///
/// The Dart side stages copies under the temporary directory and
/// passes their paths. On iPad the sheet is a popover and
/// presentation crashes without an anchor, so the Dart side also
/// passes the tapped tile's rect (in the Flutter view's
/// coordinates, which are the presenter's view coordinates).
final class ShareHub {
  static let shared = ShareHub()

  func register(messenger: FlutterBinaryMessenger) {
    let channel = FlutterMethodChannel(
      name: "com.markun.tmhb/share_files", binaryMessenger: messenger)
    channel.setMethodCallHandler { call, result in
      switch call.method {
      case "shareFiles":
        let args = call.arguments as? [String: Any] ?? [:]
        let paths = args["paths"] as? [String] ?? []
        guard !paths.isEmpty else {
          result(
            FlutterError(
              code: "no_files", message: "no files to share", details: nil))
          return
        }
        guard let presenter = ShareHub.topViewController() else {
          result(
            FlutterError(
              code: "no_presenter",
              message: "no view controller to present from", details: nil))
          return
        }
        let urls = paths.map { URL(fileURLWithPath: $0) }
        let activity = UIActivityViewController(
          activityItems: urls, applicationActivities: nil)
        if let popover = activity.popoverPresentationController {
          popover.sourceView = presenter.view
          let x = args["originX"] as? Double ?? Double(presenter.view.bounds.midX)
          let y = args["originY"] as? Double ?? Double(presenter.view.bounds.midY)
          let width = args["originWidth"] as? Double ?? 0
          let height = args["originHeight"] as? Double ?? 0
          popover.sourceRect = CGRect(
            x: x, y: y, width: width, height: height)
        }
        presenter.present(activity, animated: true)
        result(nil)
      default:
        result(FlutterMethodNotImplemented)
      }
    }
  }

  private static func topViewController() -> UIViewController? {
    let window = UIApplication.shared.connectedScenes
      .compactMap { $0 as? UIWindowScene }
      .flatMap { $0.windows }
      .first { $0.isKeyWindow }
    var controller = window?.rootViewController
    while let presented = controller?.presentedViewController {
      controller = presented
    }
    return controller
  }
}

final class AribSoundHub {
  static let shared = AribSoundHub()
  private var player: AVAudioPlayer?

  func register(messenger: FlutterBinaryMessenger) {
    let channel = FlutterMethodChannel(
      name: "com.markun.tmhb/arib_sound", binaryMessenger: messenger)
    channel.setMethodCallHandler { [weak self] call, result in
      switch call.method {
      case "playWav":
        let args = call.arguments as? [String: Any] ?? [:]
        guard let typed = args["wav"] as? FlutterStandardTypedData else {
          result(false)
          return
        }
        do {
          let session = AVAudioSession.sharedInstance()
          try session.setCategory(.playback, options: [.mixWithOthers])
          try session.setActive(true)
          self?.player?.stop()
          let next = try AVAudioPlayer(data: typed.data)
          next.prepareToPlay()
          let ok = next.play()
          self?.player = next
          result(ok)
        } catch {
          result(false)
        }
      default:
        result(FlutterMethodNotImplemented)
      }
    }
  }
}
