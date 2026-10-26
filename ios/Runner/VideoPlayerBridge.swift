import Flutter
import UIKit

final class ScreenAwakeRequests {
  var app = false { didSet { apply() } }
  var video = false { didSet { apply() } }
  private func apply() { UIApplication.shared.isIdleTimerDisabled = app || video }
}

final class VideoPlayerBridge {
  private let channel: FlutterMethodChannel
  private var originalBrightness: CGFloat?
  private var originalBatteryMonitoring: Bool?

  init(controller: FlutterViewController, screenAwake: ScreenAwakeRequests) {
    channel = FlutterMethodChannel(name: "com.meteor.kikoeruflutter/video_player",
      binaryMessenger: controller.binaryMessenger)
    channel.setMethodCallHandler { [weak self, weak controller] call, result in
      guard let self = self else { result(nil); return }
      switch call.method {
      case "initialize":
        result(["brightness": true, "pictureInPicture": false])
      case "getBatteryStatus":
        let device = UIDevice.current
        if self.originalBatteryMonitoring == nil {
          self.originalBatteryMonitoring = device.isBatteryMonitoringEnabled
          device.isBatteryMonitoringEnabled = true
        }
        let level = device.batteryLevel
        guard level.isFinite, level >= 0, level <= 1, device.batteryState != .unknown else {
          result(nil)
          return
        }
        result(["level": Int((level * 100).rounded()),
          "charging": device.batteryState == .charging || device.batteryState == .full])
      case "getBrightness":
        result(Double(UIScreen.main.brightness))
      case "setBrightness":
        guard let args = call.arguments as? [String: Any],
              let value = args["value"] as? Double, value.isFinite else {
          result(FlutterError(code: "invalid_brightness", message: "Brightness must be finite.", details: nil))
          return
        }
        if self.originalBrightness == nil { self.originalBrightness = UIScreen.main.brightness }
        UIScreen.main.brightness = CGFloat(min(1, max(0, value)))
        result(nil)
      case "resetBrightness":
        self.resetBrightness()
        result(nil)
      case "setKeepScreenOn":
        let args = call.arguments as? [String: Any]
        screenAwake.video = args?["enabled"] as? Bool ?? false
        result(nil)
      case "waitForWindowLayout":
        DispatchQueue.main.async { [weak controller] in
          guard let controller = controller,
                controller.isViewLoaded, controller.view.window != nil else {
            result(nil)
            return
          }
          let complete = {
            controller.view.layoutIfNeeded()
            let size = controller.view.bounds.size
            result(size.height >= size.width)
          }
          if let transition = controller.transitionCoordinator {
            transition.animate(alongsideTransition: nil, completion: { _ in complete() })
          } else {
            complete()
          }
        }
      case "dispose":
        self.resetBrightness()
        if let original = self.originalBatteryMonitoring {
          UIDevice.current.isBatteryMonitoringEnabled = original
          self.originalBatteryMonitoring = nil
        }
        screenAwake.video = false
        result(nil)
      default:
        result(FlutterMethodNotImplemented)
      }
    }
  }

  private func resetBrightness() {
    if let original = originalBrightness { UIScreen.main.brightness = original }
    originalBrightness = nil
  }
}
