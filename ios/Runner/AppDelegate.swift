import AVFoundation
import Flutter
import UIKit

@main
@objc class AppDelegate: FlutterAppDelegate, FlutterImplicitEngineDelegate {
  private let audio = MeltdownAudio()

  override func application(
    _ application: UIApplication,
    didFinishLaunchingWithOptions launchOptions: [UIApplication.LaunchOptionsKey: Any]?
  ) -> Bool {
    return super.application(application, didFinishLaunchingWithOptions: launchOptions)
  }

  func didInitializeImplicitFlutterEngine(_ engineBridge: FlutterImplicitEngineBridge) {
    GeneratedPluginRegistrant.register(with: engineBridge.pluginRegistry)

    let channel = FlutterMethodChannel(
      name: "meltdown/audio",
      binaryMessenger: engineBridge.applicationMessenger)
    channel.setMethodCallHandler { [weak self] call, result in
      guard let self = self else {
        result(nil)
        return
      }
      switch call.method {
      case "init":
        let rate = (call.arguments as? [String: Any])?["rate"] as? Double ?? 22050
        result(self.audio.start(rate: rate))
      case "play":
        guard
          let args = call.arguments as? [String: Any],
          let data = args["pcm"] as? FlutterStandardTypedData
        else {
          result(FlutterError(code: "bad_args", message: "pcm missing", details: nil))
          return
        }
        self.audio.play(pcm: data.data)
        result(nil)
      default:
        result(FlutterMethodNotImplemented)
      }
    }
  }
}

/// Plays 16-bit mono PCM handed over from Dart.
///
/// Deliberately dumb: every waveform in the game is synthesised in Dart, so
/// the only job here is to take a buffer and make a noise with it. Each sound
/// gets its own player node so short effects overlap instead of queueing
/// behind one another, and the node is detached once it finishes.
final class MeltdownAudio {
  private let engine = AVAudioEngine()
  private var format: AVAudioFormat?
  private var started = false
  private let lock = NSLock()
  private var live = 0

  /// More overlap than this is inaudible anyway, and the cap stops a stuck
  /// annunciator spawning nodes without limit.
  private let maxVoices = 12

  func start(rate: Double) -> Bool {
    lock.lock()
    defer { lock.unlock() }
    if started { return true }
    do {
      // .ambient so the game respects the ring/silent switch and mixes with
      // whatever the player already had playing. A control room is not a media
      // player and has no business seizing the audio session.
      try AVAudioSession.sharedInstance().setCategory(
        .ambient, mode: .default, options: [.mixWithOthers])
      try AVAudioSession.sharedInstance().setActive(true)

      guard
        let fmt = AVAudioFormat(
          commonFormat: .pcmFormatFloat32, sampleRate: rate,
          channels: 1, interleaved: false)
      else { return false }
      format = fmt
      // The engine will not start without a connection made first.
      engine.connect(engine.mainMixerNode, to: engine.outputNode, format: fmt)
      engine.prepare()
      try engine.start()
      started = true
      return true
    } catch {
      return false
    }
  }

  func play(pcm: Data) {
    guard started, let fmt = format else { return }

    lock.lock()
    if live >= maxVoices {
      lock.unlock()
      return
    }
    live += 1
    lock.unlock()

    func release() {
      lock.lock()
      live -= 1
      lock.unlock()
    }

    let sampleCount = pcm.count / 2
    guard
      sampleCount > 0,
      let buffer = AVAudioPCMBuffer(
        pcmFormat: fmt, frameCapacity: AVAudioFrameCount(sampleCount)),
      let channel = buffer.floatChannelData?[0]
    else {
      release()
      return
    }
    buffer.frameLength = AVAudioFrameCount(sampleCount)

    // 16-bit little-endian to float, which is what the mixer wants.
    //
    // Assembled a byte at a time rather than by binding the buffer to Int16:
    // the bytes arrive from the method channel at whatever offset the codec
    // left them at, and binding a misaligned pointer to a 2-byte type is
    // undefined behaviour. The Dart-side test hits exactly this.
    pcm.withUnsafeBytes { raw in
      for i in 0..<sampleCount {
        let lo = UInt16(raw[i * 2])
        let hi = UInt16(raw[i * 2 + 1])
        let bits = lo | (hi << 8)
        channel[i] = Float(Int16(bitPattern: bits)) / 32768.0
      }
    }

    let node = AVAudioPlayerNode()
    engine.attach(node)
    engine.connect(node, to: engine.mainMixerNode, format: fmt)
    node.scheduleBuffer(buffer, at: nil, options: []) { [weak self] in
      // Tear down on the main queue: detaching a node from inside the
      // completion handler, which runs on the audio thread, is not safe.
      DispatchQueue.main.async {
        guard let self = self else { return }
        node.stop()
        self.engine.detach(node)
        release()
      }
    }
    node.play()
  }
}
