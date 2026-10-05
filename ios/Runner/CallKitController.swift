import AVFoundation
import CallKit
import Flutter
import Foundation
import WebRTC

/// The native half of the `gather/os_call` bridge. The Dart half is
/// `lib/src/media/os_call_callkit.dart`.
///
/// Registers a Gather call with the OS through CallKit so it behaves like a phone
/// call: the screen can lock and audio keeps running, the system draws its own
/// in-call UI, and the call lands in the Phone app's Recents. The call is
/// *app-initiated* — Gather connects off a socket it already holds, there is no
/// real incoming ring — but it is reported to CallKit as an **incoming** call that
/// is then immediately answered. iOS 14 removed the rich lock-screen UI for
/// *outgoing* calls; only incoming calls get the full call sheet (caller name,
/// End, mute, speaker) and a reliable Recents entry. The brief ring is silenced
/// with a bundled `silence.caf`. No PushKit is involved.
///
/// Two directions cross the channel. Dart asks the OS to start, end and mute a
/// call, and to pick the speaker; the OS asks back when the person taps End or the
/// mute toggle on the lock screen or system call sheet, and reports audio-route
/// changes. An end or a mute that *we* requested must not echo back to Dart as if
/// the person had asked for it — the `selfEnding` / `selfMuting` flags below are
/// what tell the two apart.
///
/// Audio-session ownership note: once CallKit answers the call it, not WebRTC,
/// owns when the audio session goes active. `flutter_webrtc`'s audio device module
/// would otherwise try to activate the session itself and the two collide — the
/// symptom was the mic track collapsing the instant you unmuted (the audio unit
/// reconfigures for `voiceProcessing` mute exactly as CallKit activates). So we put
/// WebRTC in manual-audio mode (`RTCAudioSession.useManualAudio = true`) and hand it
/// the session lifecycle from the CallKit delegate: `didActivate` tells WebRTC the
/// session is live, `didDeactivate` that it is not. The Dart engine still sets the
/// call category (`setAppleAudioIOMode`). The speaker route is driven by
/// `setSpeaker` (an `overrideOutputAudioPort`, the same mechanism as the system call
/// sheet's own speaker button), and the current route is observed and reported back
/// to Dart so the in-app icon tracks the truth.
class CallKitController: NSObject {
  private let channel: FlutterMethodChannel
  private let provider: CXProvider
  private let callController = CXCallController()

  /// The one call we track. CallKit allows many; a presence app needs exactly one
  /// at a time, so a second start replaces rather than stacks.
  private var callUUID: UUID?

  /// Set while we are the ones ending or muting, so the delegate callback that
  /// CallKit fires in response is not mistaken for the person pressing the
  /// system button and bounced back to Dart.
  private var selfEnding = false
  private var selfMuting = false

  /// True once CallKit has answered the call, so it exists and transactions on it
  /// will take. A mute reported before this (the unmute door reports a start and a
  /// mute back to back) is held in `pendingMuted` and applied at answer, rather
  /// than fired at a call CallKit has not connected yet — which fails.
  private var connected = false
  private var pendingMuted: Bool?

  init(messenger: FlutterBinaryMessenger) {
    channel = FlutterMethodChannel(name: "gather/os_call", binaryMessenger: messenger)

    let config = CXProviderConfiguration()
    config.supportsVideo = true
    config.maximumCallGroups = 1
    config.maximumCallsPerCallGroup = 1
    // Email-address handles group reliably in Recents on iOS 26, where the
    // `.generic` type does not. The stable grouping id rides in the handle; the
    // human-readable name goes in `localizedCallerName`.
    config.supportedHandleTypes = [.emailAddress]
    // Suppress the brief incoming ring: the call is app-initiated and answered
    // immediately, so the ringtone would only be a blip of noise.
    config.ringtoneSound = "silence.caf"
    provider = CXProvider(configuration: config)

    super.init()

    // Hand the VoIP audio unit's lifetime to us: WebRTC stops starting the session
    // on its own, and instead waits to be told it is live in `didActivate`. This is
    // what stops WebRTC and CallKit from both trying to own the session.
    RTCAudioSession.sharedInstance().useManualAudio = true

    provider.setDelegate(self, queue: nil)
    channel.setMethodCallHandler { [weak self] call, result in
      self?.handle(call, result: result)
    }

    // Watch the audio route so the in-app speaker icon reflects reality however
    // the route changed — in-app, the system button, or a headset being plugged.
    NotificationCenter.default.addObserver(
      self,
      selector: #selector(audioRouteChanged(_:)),
      name: AVAudioSession.routeChangeNotification,
      object: nil)
  }

  deinit {
    NotificationCenter.default.removeObserver(self)
  }

  private func handle(_ call: FlutterMethodCall, result: @escaping FlutterResult) {
    switch call.method {
    case "reportStarted":
      let args = call.arguments as? [String: Any]
      let handle = args?["handle"] as? String ?? "Gather"
      let id = args?["id"] as? String ?? handle
      reportStarted(handle: handle, id: id, result: result)
    case "reportEnded":
      reportEnded(result: result)
    case "reportMuted":
      let args = call.arguments as? [String: Any]
      let muted = args?["muted"] as? Bool ?? false
      reportMuted(muted, result: result)
    case "setSpeaker":
      let args = call.arguments as? [String: Any]
      let on = args?["on"] as? Bool ?? false
      setSpeaker(on, result: result)
    default:
      result(FlutterMethodNotImplemented)
    }
  }

  private func reportStarted(handle: String, id: String, result: @escaping FlutterResult) {
    // Idempotent: one engagement is one call however many doors reported it.
    if callUUID != nil {
      result(nil)
      return
    }
    let uuid = UUID()
    callUUID = uuid

    let update = CXCallUpdate()
    update.remoteHandle = CXHandle(type: .emailAddress, value: id)
    update.localizedCallerName = handle
    update.hasVideo = false

    // Report an incoming call, then answer it *inside* the completion block — the
    // call is not yet known to CallKit until the completion fires, so requesting
    // the answer before then would race. A failed report must not leave `callUUID`
    // set, or every later start is a no-op against a call the OS never accepted.
    provider.reportNewIncomingCall(with: uuid, update: update) { [weak self] error in
      guard let self = self else { return }
      if let error = error {
        NSLog("os_call: reportNewIncomingCall failed: \(error.localizedDescription)")
        self.callUUID = nil
        result(
          FlutterError(
            code: "report_failed",
            message: error.localizedDescription,
            details: nil))
        return
      }
      // Answering connects the call: the system shows an active call and Recents
      // records it, with no "calling…" limbo.
      self.requestTransaction(
        CXTransaction(action: CXAnswerCallAction(call: uuid)),
        rollback: { [weak self] in self?.callUUID = nil },
        result: result)
    }
  }

  private func reportEnded(result: @escaping FlutterResult) {
    guard let uuid = callUUID else {
      result(nil)
      return
    }
    selfEnding = true
    // A failed end must clear `selfEnding`, or a later real End button is read as
    // our own echo and never reaches Dart.
    requestTransaction(
      CXTransaction(action: CXEndCallAction(call: uuid)),
      rollback: { [weak self] in self?.selfEnding = false },
      result: result)
  }

  private func reportMuted(_ muted: Bool, result: @escaping FlutterResult) {
    guard let uuid = callUUID else {
      result(nil)
      return
    }
    // Reported before the answer connected the call: hold it and let the answer
    // apply it. Firing a set-muted at a not-yet-connected call fails the transaction.
    if !connected {
      pendingMuted = muted
      result(nil)
      return
    }
    selfMuting = true
    let action = CXSetMutedCallAction(call: uuid, muted: muted)
    // Same as end: a failed mute must clear `selfMuting` so a later real toggle
    // is not swallowed as our own echo.
    requestTransaction(
      CXTransaction(action: action),
      rollback: { [weak self] in self?.selfMuting = false },
      result: result)
  }

  /// Picks the output route the same way the system call sheet's speaker button
  /// does. `.none` falls back to the session's default (earpiece, or whatever
  /// accessory is attached). Not routed through CallKit — this is an
  /// AVAudioSession override that coexists with the system button.
  private func setSpeaker(_ on: Bool, result: @escaping FlutterResult) {
    try? AVAudioSession.sharedInstance().overrideOutputAudioPort(on ? .speaker : .none)
    result(nil)
  }

  /// Requests a CallKit transaction. On failure, rolls the operation's committed
  /// state back and surfaces the error to Dart (which logs and degrades to a call
  /// the OS does not know about); on success, replies nil.
  private func requestTransaction(
    _ transaction: CXTransaction,
    rollback: @escaping () -> Void,
    result: @escaping FlutterResult
  ) {
    callController.request(transaction) { error in
      if let error = error {
        NSLog("os_call: transaction failed: \(error.localizedDescription)")
        rollback()
        result(
          FlutterError(
            code: "transaction_failed",
            message: error.localizedDescription,
            details: nil))
        return
      }
      result(nil)
    }
  }

  /// The audio route changed. While a call is live, tell Dart which output is now
  /// active so the in-app speaker icon tracks the truth. Only emit during a call
  /// to avoid noise from unrelated route changes.
  @objc private func audioRouteChanged(_ notification: Notification) {
    guard callUUID != nil else { return }
    let outputs = AVAudioSession.sharedInstance().currentRoute.outputs
    let route: String
    switch outputs.first?.portType {
    case .some(.builtInSpeaker):
      route = "speaker"
    case .some(.builtInReceiver):
      route = "earpiece"
    case .some(.bluetoothA2DP), .some(.bluetoothHFP), .some(.bluetoothLE):
      route = "bluetooth"
    case .some(.headphones), .some(.headsetMic), .some(.usbAudio), .some(.carAudio):
      route = "wired"
    default:
      // Unknown or no output — treat as earpiece, the default handset route.
      route = "earpiece"
    }
    DispatchQueue.main.async { [weak self] in
      self?.channel.invokeMethod("routeChanged", arguments: ["route": route])
    }
  }
}

extension CallKitController: CXProviderDelegate {
  func providerDidReset(_ provider: CXProvider) {
    // CallKit threw the call away out from under us (a reset). Forget it; nothing
    // to end through a transaction, because it is already gone.
    guard let uuid = callUUID else { return }
    callUUID = nil
    connected = false
    pendingMuted = nil
    selfEnding = false
    selfMuting = false
    // Log the call to Recents: a reset is an abnormal end that never went through
    // a user CXEndCallAction, so without this the entry would be missing or
    // zero-duration.
    provider.reportCall(with: uuid, endedAt: nil, reason: .remoteEnded)
    // The OS call is gone but Dart still thinks it is engaged — its media call
    // runs on with no OS protection, and its engagement guard blocks a
    // replacement. Treat the reset like the person pressing End so Dart tears
    // down and clears engagement, the same path the lock-screen End takes.
    channel.invokeMethod("endRequested", arguments: nil)
  }

  func provider(_ provider: CXProvider, perform action: CXAnswerCallAction) {
    // App-initiated calls are answered immediately after being reported incoming;
    // fulfilling connects the call.
    action.fulfill()
    connected = true
    // Apply any mute reported before the call connected (the unmute door's
    // back-to-back start+mute, or the faces door opening while muted).
    if let muted = pendingMuted, let uuid = callUUID {
      pendingMuted = nil
      selfMuting = true
      requestTransaction(
        CXTransaction(action: CXSetMutedCallAction(call: uuid, muted: muted)),
        rollback: { [weak self] in self?.selfMuting = false },
        result: { _ in })
    }
  }

  func provider(_ provider: CXProvider, perform action: CXEndCallAction) {
    action.fulfill()
    let wasSelf = selfEnding
    selfEnding = false
    callUUID = nil
    connected = false
    pendingMuted = nil
    // Only when the *person* ended it — the lock-screen End button — does the app
    // need telling. Our own `reportEnded` already tore the call down.
    if !wasSelf {
      channel.invokeMethod("endRequested", arguments: nil)
    }
  }

  func provider(_ provider: CXProvider, perform action: CXSetMutedCallAction) {
    action.fulfill()
    let wasSelf = selfMuting
    selfMuting = false
    if !wasSelf {
      channel.invokeMethod("muteRequested", arguments: ["muted": action.isMuted])
    }
  }

  func provider(_ provider: CXProvider, didActivate audioSession: AVAudioSession) {
    NSLog("os_call: audio session activated by CallKit")
    // CallKit has made the session active; hand that to WebRTC, which is in manual
    // mode and was waiting for exactly this before starting its audio unit.
    let rtc = RTCAudioSession.sharedInstance()
    rtc.audioSessionDidActivate(audioSession)
    rtc.isAudioEnabled = true
  }

  func provider(_ provider: CXProvider, didDeactivate audioSession: AVAudioSession) {
    NSLog("os_call: audio session deactivated by CallKit")
    let rtc = RTCAudioSession.sharedInstance()
    rtc.audioSessionDidDeactivate(audioSession)
    rtc.isAudioEnabled = false
  }
}
