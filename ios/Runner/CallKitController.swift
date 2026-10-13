import AVFoundation
import CallKit
import Flutter
import Foundation

/// The native half of the `gather/os_call` bridge. The Dart half is
/// `lib/src/media/os_call_callkit.dart`.
///
/// Registers a Gather call with the OS through CallKit so it behaves like a phone
/// call: the screen can lock and audio keeps running, the system draws its own
/// in-call UI, and the call lands in the Phone app's Recents. The call is
/// *app-initiated* — Gather connects off a socket it already holds, there is no
/// incoming ring — so this reports an outgoing call that is immediately
/// connected, and never uses PushKit.
///
/// Two directions cross the channel. Dart asks the OS to start, end and mute a
/// call; the OS asks back when the person taps End or the mute toggle on the lock
/// screen or the system call sheet. An end or a mute that *we* requested must not
/// echo back to Dart as if the person had asked for it — the `selfEnding` /
/// `selfMuting` flags below are what tell the two apart.
///
/// Audio-session ownership note: `flutter_webrtc`'s AVAudioEngine audio device
/// module manages activation itself, and the Dart engine sets the call category
/// (`setAppleAudioIOMode`). So `didActivate` / `didDeactivate` here only log — the
/// route is left to the system call sheet's picker, which is the whole point of
/// letting CallKit own it. If device testing shows the route not following the
/// picker, this is where manual `RTCAudioSession` activation would be added.
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

  init(messenger: FlutterBinaryMessenger) {
    channel = FlutterMethodChannel(name: "gather/os_call", binaryMessenger: messenger)

    let config = CXProviderConfiguration()
    config.supportsVideo = true
    config.maximumCallGroups = 1
    config.maximumCallsPerCallGroup = 1
    config.supportedHandleTypes = [.generic]
    provider = CXProvider(configuration: config)

    super.init()

    provider.setDelegate(self, queue: nil)
    channel.setMethodCallHandler { [weak self] call, result in
      self?.handle(call, result: result)
    }
  }

  private func handle(_ call: FlutterMethodCall, result: @escaping FlutterResult) {
    switch call.method {
    case "reportStarted":
      let args = call.arguments as? [String: Any]
      let handle = args?["handle"] as? String ?? "Gather"
      reportStarted(handle: handle, result: result)
    case "reportEnded":
      reportEnded(result: result)
    case "reportMuted":
      let args = call.arguments as? [String: Any]
      let muted = args?["muted"] as? Bool ?? false
      reportMuted(muted, result: result)
    default:
      result(FlutterMethodNotImplemented)
    }
  }

  private func reportStarted(handle: String, result: @escaping FlutterResult) {
    // Idempotent: one engagement is one call however many doors reported it.
    if callUUID != nil {
      result(nil)
      return
    }
    let uuid = UUID()
    callUUID = uuid

    let cxHandle = CXHandle(type: .generic, value: handle)
    let startAction = CXStartCallAction(call: uuid, handle: cxHandle)
    startAction.isVideo = false
    // A failed start must not leave `callUUID` set, or every later start is a
    // no-op against a call the OS never accepted.
    requestTransaction(
      CXTransaction(action: startAction),
      rollback: { [weak self] in self?.callUUID = nil },
      result: result)
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
    selfMuting = true
    let action = CXSetMutedCallAction(call: uuid, muted: muted)
    // Same as end: a failed mute must clear `selfMuting` so a later real toggle
    // is not swallowed as our own echo.
    requestTransaction(
      CXTransaction(action: action),
      rollback: { [weak self] in self?.selfMuting = false },
      result: result)
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
}

extension CallKitController: CXProviderDelegate {
  func providerDidReset(_ provider: CXProvider) {
    // CallKit threw the call away out from under us (a reset). Forget it; nothing
    // to end, because it is already gone.
    let hadCall = callUUID != nil
    callUUID = nil
    selfEnding = false
    selfMuting = false
    // The OS call is gone but Dart still thinks it is engaged — its media call
    // runs on with no OS protection, and its engagement guard blocks a
    // replacement. Treat the reset like the person pressing End so Dart tears
    // down and clears engagement, the same path the lock-screen End takes.
    if hadCall {
      channel.invokeMethod("endRequested", arguments: nil)
    }
  }

  func provider(_ provider: CXProvider, perform action: CXStartCallAction) {
    action.fulfill()
    // App-initiated and already up: mark it connected so the system shows an
    // active call and Recents records it, with no "calling…" limbo.
    provider.reportOutgoingCall(with: action.callUUID, connectedAt: nil)
  }

  func provider(_ provider: CXProvider, perform action: CXEndCallAction) {
    action.fulfill()
    let wasSelf = selfEnding
    selfEnding = false
    callUUID = nil
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
  }

  func provider(_ provider: CXProvider, didDeactivate audioSession: AVAudioSession) {
    NSLog("os_call: audio session deactivated by CallKit")
  }
}
