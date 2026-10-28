import AVKit
import Flutter
import Accelerate

/// Shares the existing libmpv output and playback handle; never opens a second player.
@available(iOS 15.0, *)
final class VideoPictureInPictureBridge {
  private let channel: FlutterMethodChannel
  private let manager: VideoOutputManager
  private weak var view: UIView?
  private var active: VideoPictureInPicture?
  private var activeHandle: Int64?
  private var automatic = false

  init(registrar: FlutterPluginRegistrar, manager: VideoOutputManager) {
    self.manager = manager
    view = registrar.viewController?.view
    channel = FlutterMethodChannel(
      name: "com.meteor.kikoeruflutter/video_picture_in_picture",
      binaryMessenger: registrar.messenger())
    channel.setMethodCallHandler { [weak self] call, result in
      guard let self = self else { result(false); return }
      switch call.method {
      case "isSupported":
        result(AVPictureInPictureController.isPictureInPictureSupported())
      case "enterPictureInPicture":
        guard AVPictureInPictureController.isPictureInPictureSupported(),
              let args = call.arguments as? [String: Any],
              let raw = args["handle"] as? String, let handle = Int64(raw),
              let output = self.manager.output(for: handle), let view = self.view else {
          result(false)
          return
        }
        if self.activeHandle != handle { self.active?.invalidate() }
        let pip = output.preparePictureInPicture(channel: self.channel, view: view)
        self.active = pip
        self.activeHandle = handle
        pip.setAutomatic(self.automatic)
        pip.start(result: result)
      case "exitPictureInPicture":
        self.active?.invalidate()
        self.active = nil
        self.activeHandle = nil
        result(nil)
      case "setAutoPictureInPicture":
        guard let args = call.arguments as? [String: Any] else { result(nil); return }
        self.automatic = args["enabled"] as? Bool ?? false
        if self.automatic {
          guard let raw = args["handle"] as? String, let handle = Int64(raw),
                let output = self.manager.output(for: handle), let view = self.view else {
            result(FlutterError(code: "pip_unavailable", message: "Video output is not ready.", details: nil))
            return
          }
          if self.activeHandle != handle { self.active?.invalidate() }
          self.active = output.preparePictureInPicture(channel: self.channel, view: view)
          self.activeHandle = handle
        }
        self.active?.setAutomatic(self.automatic)
        result(nil)
      case "updateState":
        if let state = call.arguments as? [String: Any] { self.active?.updateState(state) }
        result(nil)
      default:
        result(FlutterMethodNotImplemented)
      }
    }
  }
}

@available(iOS 15.0, *)
final class VideoPictureInPicture: NSObject,
  AVPictureInPictureControllerDelegate, AVPictureInPictureSampleBufferPlaybackDelegate {
  private let channel: FlutterMethodChannel
  private let layer = AVSampleBufferDisplayLayer()
  private var controller: AVPictureInPictureController!
  private var observation: NSKeyValueObservation?
  private var pending: FlutterResult?
  private var timeout: DispatchWorkItem?
  private var wanted = false
  private var valid = true
  private var timebase: CMTimebase?
  private var lastPaused: Bool?
  private var lastDuration: Double = 0
  private var playing = false
  private var duration = 0.0
  private var pixelBufferPool: CVPixelBufferPool?
  private var pixelBufferSize = CGSize.zero
  private var automatic = false

  init(channel: FlutterMethodChannel, view: UIView) {
    self.channel = channel
    super.init()
    layer.frame = CGRect(x: 0, y: 0, width: 1, height: 1)
    layer.videoGravity = .resizeAspect
    CMTimebaseCreateWithSourceClock(allocator: kCFAllocatorDefault,
      sourceClock: CMClockGetHostTimeClock(), timebaseOut: &timebase)
    layer.controlTimebase = timebase
    view.layer.addSublayer(layer)
    controller = AVPictureInPictureController(contentSource: .init(
      sampleBufferDisplayLayer: layer, playbackDelegate: self))
    controller.delegate = self
    observation = controller.observe(\.isPictureInPicturePossible, options: [.new]) {
      [weak self] _, _ in
      DispatchQueue.main.async { self?.startWhenPossible() }
    }
  }

  deinit {
    timeout?.cancel()
    observation?.invalidate()
    controller.stopPictureInPicture()
    layer.removeFromSuperlayer()
  }

  func start(result: @escaping FlutterResult) {
    guard valid else { result(false); return }
    guard !controller.isPictureInPictureActive else { result(true); return }
    complete(false)
    pending = result
    wanted = true
    let work = DispatchWorkItem { [weak self] in self?.stop() }
    timeout = work
    DispatchQueue.main.asyncAfter(deadline: .now() + 5, execute: work)
    startWhenPossible()
  }

  private func startWhenPossible() {
    if pending != nil && controller.isPictureInPicturePossible {
      controller.startPictureInPicture()
    }
  }

  func stop() {
    wanted = false
    complete(false)
    controller.stopPictureInPicture()
  }

  func invalidate() {
    guard valid else { return }
    stop()
    valid = false
    controller.delegate = nil
    controller.contentSource = nil
    layer.removeFromSuperlayer()
    channel.invokeMethod("pictureInPictureChanged", arguments: false)
  }

  private func complete(_ active: Bool) {
    timeout?.cancel()
    timeout = nil
    let result = pending
    pending = nil
    result?(active)
  }

  func enqueue(_ buffer: CVPixelBuffer) {
    guard needsFrames else { return }
    if layer.status == .failed { layer.flush() }
    guard let copy = copyForPictureInPicture(buffer) else { return }
    let position = timebase.map { CMTimebaseGetTime($0) } ?? .zero
    var description: CMVideoFormatDescription?
    guard CMVideoFormatDescriptionCreateForImageBuffer(
      allocator: kCFAllocatorDefault, imageBuffer: copy,
      formatDescriptionOut: &description) == noErr, let format = description else { return }
    var timing = CMSampleTimingInfo(
      duration: .invalid,
      presentationTimeStamp: position,
      decodeTimeStamp: .invalid)
    var sample: CMSampleBuffer?
    guard CMSampleBufferCreateReadyWithImageBuffer(
      allocator: kCFAllocatorDefault, imageBuffer: copy, formatDescription: format,
      sampleTiming: &timing, sampleBufferOut: &sample) == noErr,
      let sample = sample, layer.isReadyForMoreMediaData else { return }
    layer.enqueue(sample)
  }

  var needsFrames: Bool { valid && (pending != nil || controller.isPictureInPictureActive || (automatic && playing)) }
  var isValid: Bool { valid }

  func setAutomatic(_ enabled: Bool) {
    automatic = enabled
    controller.canStartPictureInPictureAutomaticallyFromInline = enabled
  }

  func updateState(_ state: [String: Any]) {
    guard valid, let position = state["position"] as? Double, position.isFinite,
          let duration = state["duration"] as? Double, duration.isFinite,
          let rate = state["rate"] as? Double, rate.isFinite,
          let playing = state["playing"] as? Bool else { return }
    self.playing = playing
    self.duration = duration
    if let timebase = timebase {
      if abs(CMTimeGetSeconds(CMTimebaseGetTime(timebase)) - position) > 0.25 || lastPaused != !playing {
        layer.flush()
        CMTimebaseSetTime(timebase, time: CMTime(seconds: position, preferredTimescale: 600))
      }
      CMTimebaseSetRate(timebase, rate: playing ? rate : 0)
    }
    if lastPaused != !playing || lastDuration != duration {
      lastPaused = !playing
      lastDuration = duration
      controller.invalidatePlaybackState()
    }
  }

  /// AVKit retains frames asynchronously, while Flutter's pool reuses its buffers.
  private func copyForPictureInPicture(_ source: CVPixelBuffer) -> CVPixelBuffer? {
    let width = CVPixelBufferGetWidth(source)
    let height = CVPixelBufferGetHeight(source)
    if pixelBufferPool == nil || pixelBufferSize != CGSize(width: width, height: height) {
      let attributes = [
        kCVPixelBufferPixelFormatTypeKey: kCVPixelFormatType_32BGRA,
        kCVPixelBufferWidthKey: width, kCVPixelBufferHeightKey: height,
        kCVPixelBufferIOSurfacePropertiesKey: [:]
      ] as CFDictionary
      guard CVPixelBufferPoolCreate(kCFAllocatorDefault, nil, attributes, &pixelBufferPool) == kCVReturnSuccess else { return nil }
      pixelBufferSize = CGSize(width: width, height: height)
    }
    guard let pool = pixelBufferPool else { return nil }
    var destination: CVPixelBuffer?
    let limit = [kCVPixelBufferPoolAllocationThresholdKey: 6] as CFDictionary
    guard CVPixelBufferPoolCreatePixelBufferWithAuxAttributes(kCFAllocatorDefault, pool, limit, &destination) == kCVReturnSuccess,
          let destination = destination else { return nil }
    guard CVPixelBufferLockBaseAddress(source, .readOnly) == kCVReturnSuccess else { return nil }
    defer { CVPixelBufferUnlockBaseAddress(source, .readOnly) }
    guard CVPixelBufferLockBaseAddress(destination, []) == kCVReturnSuccess else { return nil }
    defer { CVPixelBufferUnlockBaseAddress(destination, []) }
    guard let src = CVPixelBufferGetBaseAddress(source), let dst = CVPixelBufferGetBaseAddress(destination) else { return nil }
    var srcImage = vImage_Buffer(data: src, height: vImagePixelCount(height), width: vImagePixelCount(width),
      rowBytes: CVPixelBufferGetBytesPerRow(source))
    var dstImage = vImage_Buffer(data: dst, height: vImagePixelCount(height), width: vImagePixelCount(width),
      rowBytes: CVPixelBufferGetBytesPerRow(destination))
    // libmpv bgr0 leaves the fourth byte undefined; AVKit needs opaque BGRA.
    guard vImageOverwriteChannelsWithScalar_ARGB8888(255, &srcImage, &dstImage, 0x1,
      vImage_Flags(kvImageDoNotTile)) == kvImageNoError else { return nil }
    CVBufferSetAttachment(destination, kCVImageBufferCGColorSpaceKey,
      CGColorSpaceCreateDeviceRGB(), .shouldPropagate)
    if #available(iOS 13.0, *) {
      CVBufferSetAttachment(destination, kCVImageBufferAlphaChannelIsOpaque,
        kCFBooleanTrue, .shouldPropagate)
    }
    return destination
  }

  func pictureInPictureControllerDidStartPictureInPicture(_ controller: AVPictureInPictureController) {
    guard (wanted || automatic) && valid else { controller.stopPictureInPicture(); return }
    channel.invokeMethod("pictureInPictureChanged", arguments: true)
    complete(true)
  }

  func pictureInPictureControllerDidStopPictureInPicture(_ controller: AVPictureInPictureController) {
    channel.invokeMethod("pictureInPictureChanged", arguments: false)
    complete(false)
  }

  func pictureInPictureController(_ controller: AVPictureInPictureController,
    failedToStartPictureInPictureWithError error: Error) {
    channel.invokeMethod("pictureInPictureChanged", arguments: false)
    complete(false)
  }

  func pictureInPictureController(_ controller: AVPictureInPictureController,
    restoreUserInterfaceForPictureInPictureStopWithCompletionHandler completionHandler: @escaping (Bool) -> Void) {
    completionHandler(true)
  }

  func pictureInPictureController(_ controller: AVPictureInPictureController, setPlaying playing: Bool) {
    channel.invokeMethod("setPlaying", arguments: playing)
  }

  func pictureInPictureControllerTimeRangeForPlayback(_ controller: AVPictureInPictureController) -> CMTimeRange {
    return duration > 0
      ? CMTimeRange(start: .zero,
                    duration: CMTime(seconds: duration, preferredTimescale: 600))
      : CMTimeRange(start: .zero, duration: .positiveInfinity)
  }

  func pictureInPictureControllerIsPlaybackPaused(_ controller: AVPictureInPictureController) -> Bool {
    !playing
  }

  func pictureInPictureController(_ controller: AVPictureInPictureController,
    didTransitionToRenderSize newRenderSize: CMVideoDimensions) {}

  func pictureInPictureController(_ controller: AVPictureInPictureController,
    skipByInterval skipInterval: CMTime, completion completionHandler: @escaping () -> Void) {
    channel.invokeMethod("skipByInterval", arguments: skipInterval.seconds) { _ in completionHandler() }
  }
}
