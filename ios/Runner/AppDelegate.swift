import Flutter
import UIKit

@main
@objc class AppDelegate: FlutterAppDelegate, FlutterImplicitEngineDelegate {
  /// The CallKit bridge. Held for the life of the app — a channel, not a per-call
  /// object — so its method-call handler outlives any one call.
  private var callKit: CallKitController?

  override func application(
    _ application: UIApplication,
    didFinishLaunchingWithOptions launchOptions: [UIApplication.LaunchOptionsKey: Any]?
  ) -> Bool {
    return super.application(application, didFinishLaunchingWithOptions: launchOptions)
  }

  func didInitializeImplicitFlutterEngine(_ engineBridge: FlutterImplicitEngineBridge) {
    GeneratedPluginRegistrant.register(with: engineBridge.pluginRegistry)
    // Same registry the generated plugins use, for the one hand-written channel.
    if let registrar = engineBridge.pluginRegistry.registrar(forPlugin: "CallKitController") {
      callKit = CallKitController(messenger: registrar.messenger())
    }
  }
}
