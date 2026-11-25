import AVFoundation
import Cocoa
import FlutterMacOS
import IOKit.pwr_mgt

class MainFlutterWindow: NSWindow {
  override func awakeFromNib() {
    let flutterViewController = FlutterViewController()
    self.contentViewController = flutterViewController
    // Desktop is a large-screen target (plan 37): open at a size
    // where the rail + two-pane layout is in effect from the
    // start, centred on the screen, instead of the template's
    // 800x600.
    self.setContentSize(NSSize(width: 1280, height: 800))
    self.center()

    RegisterGeneratedPlugins(registry: flutterViewController)

    // Native AKE socket channels (IP TTL 3, plan 28 / 47.5): the
    // nasne refuses AKE connections whose IP TTL exceeds 3, and
    // dart:io cannot set the TTL, so macOS uses the same native
    // socket as iOS.
    let akeRegistrar = flutterViewController.registrar(
      forPlugin: "AkeSocketChannels")
    AkeSocketHub.shared.register(messenger: akeRegistrar.messenger)

    let windowRegistrar = flutterViewController.registrar(
      forPlugin: "WindowControlChannels")
    WindowControlHub.shared.register(
      messenger: windowRegistrar.messenger, window: self)

    let wakelockRegistrar = flutterViewController.registrar(
      forPlugin: "WakelockChannels")
    WakelockHub.shared.register(messenger: wakelockRegistrar.messenger)

    let aribSoundRegistrar = flutterViewController.registrar(
      forPlugin: "AribSoundChannels")
    AribSoundHub.shared.register(messenger: aribSoundRegistrar.messenger)

    super.awakeFromNib()
  }
}

final class WindowControlHub {
  static let shared = WindowControlHub()
  private weak var window: NSWindow?

  func register(messenger: FlutterBinaryMessenger, window: NSWindow) {
    self.window = window
    let channel = FlutterMethodChannel(
      name: "com.markun.tmhb/window_control", binaryMessenger: messenger)
    channel.setMethodCallHandler { [weak self] call, result in
      guard let window = self?.window else {
        result(false)
        return
      }
      let isFull = window.styleMask.contains(.fullScreen)
      switch call.method {
      case "isFullscreen":
        result(isFull)
      case "toggleFullscreen":
        window.toggleFullScreen(nil)
        result(!isFull)
      case "setFullscreen":
        let args = call.arguments as? [String: Any] ?? [:]
        let target = args["fullscreen"] as? Bool ?? false
        if isFull != target {
          window.toggleFullScreen(nil)
        }
        result(target)
      default:
        result(FlutterMethodNotImplemented)
      }
    }
  }
}

final class WakelockHub {
  static let shared = WakelockHub()
  private var assertionId: IOPMAssertionID = 0

  func register(messenger: FlutterBinaryMessenger) {
    let channel = FlutterMethodChannel(
      name: "com.markun.tmhb/wakelock", binaryMessenger: messenger)
    channel.setMethodCallHandler { [weak self] call, result in
      guard let self = self else {
        result(false)
        return
      }
      switch call.method {
      case "setKeepAwake":
        let args = call.arguments as? [String: Any] ?? [:]
        let keepAwake = args["keepAwake"] as? Bool ?? false
        if keepAwake {
          if self.assertionId == 0 {
            var id: IOPMAssertionID = 0
            let status = IOPMAssertionCreateWithName(
              kIOPMAssertionTypePreventUserIdleDisplaySleep as CFString,
              IOPMAssertionLevel(kIOPMAssertionLevelOn),
              "torne mobile HB playback" as CFString,
              &id)
            if status == kIOReturnSuccess {
              self.assertionId = id
            }
          }
        } else if self.assertionId != 0 {
          IOPMAssertionRelease(self.assertionId)
          self.assertionId = 0
        }
        result(self.assertionId != 0)
      case "getKeepAwake":
        result(self.assertionId != 0)
      default:
        result(FlutterMethodNotImplemented)
      }
    }
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
