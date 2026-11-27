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

    let pipRegistrar = flutterViewController.registrar(
      forPlugin: "PipChannels")
    PipHub.shared.register(
      messenger: pipRegistrar.messenger, window: self)

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

final class PipHub: NSObject, FlutterStreamHandler {
  static let shared = PipHub()
  private weak var window: NSWindow?
  private var eventSink: FlutterEventSink?
  private var inPip = false
  private var savedFrame: NSRect?
  private var savedLevel: NSWindow.Level = .normal
  private var savedCollectionBehavior: NSWindow.CollectionBehavior = []
  private var savedMovableByBackground = false

  func register(messenger: FlutterBinaryMessenger, window: NSWindow) {
    self.window = window
    let methodChannel = FlutterMethodChannel(
      name: "com.markun.tmhb/pip", binaryMessenger: messenger)
    methodChannel.setMethodCallHandler { [weak self] call, result in
      guard let self = self else {
        result(false)
        return
      }
      switch call.method {
      case "isSupported":
        result(true)
      case "enterPip":
        let args = call.arguments as? [String: Any] ?? [:]
        let width = args["aspectWidth"] as? Int ?? 16
        let height = args["aspectHeight"] as? Int ?? 9
        result(self.enterPip(aspectWidth: width, aspectHeight: height))
      case "exitPip":
        result(self.exitPip())
      case "setAutoPipEnabled":
        result(true)
      case "isInPipMode":
        result(self.inPip)
      default:
        result(FlutterMethodNotImplemented)
      }
    }
    let eventChannel = FlutterEventChannel(
      name: "com.markun.tmhb/pip_events", binaryMessenger: messenger)
    eventChannel.setStreamHandler(self)
  }

  func onListen(
    withArguments arguments: Any?, eventSink events: @escaping FlutterEventSink
  ) -> FlutterError? {
    self.eventSink = events
    if inPip {
      events(true)
    }
    return nil
  }

  func onCancel(withArguments arguments: Any?) -> FlutterError? {
    self.eventSink = nil
    return nil
  }

  private func enterPip(aspectWidth: Int, aspectHeight: Int) -> Bool {
    guard let window = self.window else { return false }
    if inPip { return true }
    if window.styleMask.contains(.fullScreen) {
      window.toggleFullScreen(nil)
    }
    savedFrame = window.frame
    savedLevel = window.level
    savedCollectionBehavior = window.collectionBehavior
    savedMovableByBackground = window.isMovableByWindowBackground

    let wRatio = max(1, aspectWidth)
    let hRatio = max(1, aspectHeight)
    let targetWidth: CGFloat = 480
    let targetHeight = round(targetWidth * CGFloat(hRatio) / CGFloat(wRatio))
    let visible = (window.screen ?? NSScreen.main)?.visibleFrame
      ?? NSRect(x: 0, y: 0, width: 1280, height: 800)
    let margin: CGFloat = 24
    let targetFrame = NSRect(
      x: visible.maxX - targetWidth - margin,
      y: visible.minY + margin,
      width: targetWidth,
      height: targetHeight
    )

    window.level = .floating
    window.collectionBehavior = savedCollectionBehavior.union(.canJoinAllSpaces)
    window.aspectRatio = NSSize(width: wRatio, height: hRatio)
    window.isMovableByWindowBackground = true
    window.setFrame(targetFrame, display: true, animate: true)
    inPip = true
    eventSink?(true)
    return true
  }

  private func exitPip() -> Bool {
    guard let window = self.window else { return false }
    if !inPip { return false }
    window.level = savedLevel
    window.collectionBehavior = savedCollectionBehavior
    window.aspectRatio = NSSize.zero
    window.isMovableByWindowBackground = savedMovableByBackground
    if let frame = savedFrame {
      window.setFrame(frame, display: true, animate: true)
    }
    savedFrame = nil
    inPip = false
    eventSink?(false)
    return true
  }
}
