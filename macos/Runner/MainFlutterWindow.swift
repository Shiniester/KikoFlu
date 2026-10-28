import Cocoa
import FlutterMacOS
import IOKit.pwr_mgt

class MainFlutterWindow: NSWindow {
  private var videoScreenAssertion: IOPMAssertionID = 0
  override func awakeFromNib() {
    let flutterViewController = FlutterViewController.init()
    let windowFrame = self.frame
    self.contentViewController = flutterViewController
    self.setFrame(windowFrame, display: true)

    // Set minimum window size
    self.minSize = NSSize(width: 350, height: 600)

    RegisterGeneratedPlugins(registry: flutterViewController)
    let videoChannel = FlutterMethodChannel(
      name: "com.meteor.kikoeruflutter/video_player",
      binaryMessenger: flutterViewController.engine.binaryMessenger)
    videoChannel.setMethodCallHandler { [weak self] call, result in
      guard let self = self else { result(nil); return }
      switch call.method {
      case "setKeepScreenOn", "dispose":
        let args = call.arguments as? [String: Any]
        let enabled = call.method != "dispose" && args?["enabled"] as? Bool == true
        if enabled && self.videoScreenAssertion == 0 {
          let status = IOPMAssertionCreateWithName(
            kIOPMAssertionTypePreventUserIdleDisplaySleep as CFString,
            IOPMAssertionLevel(kIOPMAssertionLevelOn), "KikoFlu video playback" as CFString,
            &self.videoScreenAssertion)
          if status != kIOReturnSuccess {
            result(FlutterError(code: "screen_awake_failed", message: nil, details: status))
            return
          }
        } else if !enabled && self.videoScreenAssertion != 0 {
          IOPMAssertionRelease(self.videoScreenAssertion)
          self.videoScreenAssertion = 0
        }
        result(nil)
      default:
        result(FlutterMethodNotImplemented)
      }
    }

    super.awakeFromNib()
  }
}
