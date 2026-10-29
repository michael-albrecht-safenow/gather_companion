import AuthenticationServices
import Flutter
import UIKit
import WebKit

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
    // The Google Calendar OAuth channel. Registered off the same registry as the
    // plugins so it shares the implicit engine's messenger. See GoogleAuthChannel.
    if let registrar = engineBridge.pluginRegistry.registrar(forPlugin: "GatherOAuth") {
      GoogleAuthChannel.register(with: registrar.messenger())
    }
    // The in-app Gather login channel — an embedded WKWebView that harvests the
    // Firebase session, the native half of `lib/src/gather_web_login.dart`.
    if let registrar = engineBridge.pluginRegistry.registrar(forPlugin: "GatherWebLogin") {
      GatherWebLoginChannel.register(with: registrar.messenger())
    }
  }
}

/// The native half of `lib/src/google_calendar.dart`'s OAuth flow.
///
/// Wraps `ASWebAuthenticationSession` — part of iOS's own `AuthenticationServices`,
/// so it adds no CocoaPod and keeps this project SPM-only (see the pubspec pins and
/// the `google_sign_in` note in `google_calendar.dart`). The system session owns the
/// browser, the Safari cookie jar (so an already-signed-in Google user skips the
/// password) and the redirect capture; this class is only the `MethodChannel` seam
/// Dart reaches it through. Kept in this file rather than its own so it needs no
/// separate entry in the Xcode project's build sources.
final class GoogleAuthChannel: NSObject, ASWebAuthenticationPresentationContextProviding {
  private var session: ASWebAuthenticationSession?

  static func register(with messenger: FlutterBinaryMessenger) {
    let instance = GoogleAuthChannel()
    let channel = FlutterMethodChannel(name: "gather/oauth", binaryMessenger: messenger)
    channel.setMethodCallHandler { call, result in
      instance.handle(call, result: result)
    }
    // Held by the channel's closure capture above; kept alive for the app's life.
    objc_setAssociatedObject(channel, &Self.retainKey, instance, .OBJC_ASSOCIATION_RETAIN)
  }

  private static var retainKey = 0

  private func handle(_ call: FlutterMethodCall, result: @escaping FlutterResult) {
    guard call.method == "authenticate",
          let args = call.arguments as? [String: Any],
          let urlString = args["url"] as? String,
          let url = URL(string: urlString),
          let scheme = args["callbackScheme"] as? String
    else {
      result(FlutterError(code: "bad_args", message: "authenticate needs url + callbackScheme", details: nil))
      return
    }

    let session = ASWebAuthenticationSession(url: url, callbackURLScheme: scheme) { callbackURL, error in
      if let error = error as? ASWebAuthenticationSessionError,
         error.code == .canceledLogin {
        // A deliberate dismiss, not a failure — Dart maps this code to silence.
        result(FlutterError(code: "cancelled", message: "User cancelled", details: nil))
        return
      }
      if let error = error {
        result(FlutterError(code: "auth_failed", message: error.localizedDescription, details: nil))
        return
      }
      result(callbackURL?.absoluteString)
    }
    session.presentationContextProvider = self
    session.prefersEphemeralWebBrowserSession = false
    self.session = session
    session.start()
  }

  func presentationAnchor(for session: ASWebAuthenticationSession) -> ASPresentationAnchor {
    // The key window of the active foreground scene — where the sheet is anchored.
    let scene = UIApplication.shared.connectedScenes
      .compactMap { $0 as? UIWindowScene }
      .first { $0.activationState == .foregroundActive }
    return scene?.windows.first { $0.isKeyWindow } ?? ASPresentationAnchor()
  }
}

/// The native half of `lib/src/gather_web_login.dart`.
///
/// An embedded `WKWebView` loading Gather's real login page. The user signs in
/// against Gather's own origin — Google, email, SSO, none of it our concern — and
/// after each navigation this injects JS that reads the webview's *own* same-origin
/// IndexedDB (`firebaseLocalStorageDb` → store `firebaseLocalStorage`), finds the
/// `firebase:authUser:…:[DEFAULT]` record the web app persisted, and posts back the
/// `refreshToken` + `uid`. That is the same session the desktop bridge scrapes off
/// the Mac, now read from the phone's own webview — so no Mac, nothing to register.
///
/// `WebKit` is an iOS system framework, so this adds no CocoaPod and keeps the
/// project SPM-only, exactly like `GoogleAuthChannel` above. Kept in this file so it
/// needs no separate Xcode build-sources entry.
final class GatherWebLoginChannel: NSObject, WKNavigationDelegate, WKScriptMessageHandler {
  /// Gather's web app. Its login redirects stay inside this origin, so there is no
  /// callback to catch — we read the session it persists on success.
  // The sign-in form directly, not the app root. The root ("/") resolves to the
  // logged-out home, which shows an empty "no spaces" list and buries the sign-in —
  // a confusing first screen in a webview with no address bar. `/signin` lands the
  // user on the login form; Gather redirects to the app (and persists the session we
  // harvest) once they finish. The webview is non-persistent, so it is always a
  // fresh, logged-out load — `/signin` never bounces to the app.
  private static let loginURL = URL(string: "https://app.v2.gather.town/signin")!

  /// The IndexedDB record key the Firebase web SDK writes the session under. The
  /// suffix is Gather's public Firebase web API key (see `tool/probe-google-auth.mjs`).
  private static let authUserKeyNeedle = "firebase:authUser:"

  private static let messageName = "gatherToken"

  private var result: FlutterResult?
  private var controller: UIViewController?
  private weak var webView: WKWebView?
  /// Re-probes IndexedDB while the login is on screen. Firebase persists the session
  /// asynchronously, and an SPA login can complete with no further navigation to
  /// fire `didFinish` — so a one-shot probe can miss the write entirely.
  private var harvestTimer: Timer?

  static func register(with messenger: FlutterBinaryMessenger) {
    let instance = GatherWebLoginChannel()
    let channel = FlutterMethodChannel(name: "gather/web_login", binaryMessenger: messenger)
    channel.setMethodCallHandler { call, result in
      instance.handle(call, result: result)
    }
    objc_setAssociatedObject(channel, &Self.retainKey, instance, .OBJC_ASSOCIATION_RETAIN)
  }

  private static var retainKey = 0

  private func handle(_ call: FlutterMethodCall, result: @escaping FlutterResult) {
    guard call.method == "signIn" else {
      result(FlutterMethodNotImplemented)
      return
    }
    if self.result != nil {
      // A sign-in is already on screen; refuse a second rather than orphan the first.
      result(FlutterError(code: "busy", message: "A sign-in is already in progress", details: nil))
      return
    }
    self.result = result
    present()
  }

  private func present() {
    let config = WKWebViewConfiguration()
    // Nonpersistent: the session we harvest is saved to the keychain, so nothing of
    // value is lost by not persisting cookies/IndexedDB here. It also makes "Sign out
    // of Gather" (AppState.unpair, which clears only the native stores) stick — the
    // next sign-in starts clean instead of silently re-harvesting the old account.
    config.websiteDataStore = .nonPersistent()
    config.userContentController.add(self, name: Self.messageName)

    let webView = WKWebView(frame: .zero, configuration: config)
    webView.navigationDelegate = self
    webView.translatesAutoresizingMaskIntoConstraints = false
    self.webView = webView

    let vc = UIViewController()
    vc.view.backgroundColor = .systemBackground

    // A minimal cancel affordance: an embedded webview has no browser chrome, so
    // without this a user who changes their mind is trapped.
    let bar = UINavigationBar()
    bar.translatesAutoresizingMaskIntoConstraints = false
    let item = UINavigationItem(title: "Sign in to Gather")
    item.leftBarButtonItem = UIBarButtonItem(
      barButtonSystemItem: .cancel, target: self, action: #selector(cancelTapped))
    bar.items = [item]

    // A notice strip: Google and SSO sign-in silently fail inside an embedded
    // WKWebView (Google refuses its OAuth in an embedded user-agent), leaving the
    // user on a page that never completes. Only the email + one-time-code path works
    // here, so say so up front rather than letting them hit the dead end.
    let notice = UILabel()
    notice.text =
      "⚠️ Sign in with Email and a one-time code. Google and SSO sign-in don’t work in this window."
    notice.numberOfLines = 0
    notice.textAlignment = .center
    // Semibold on a warning-yellow strip: the grey version read as chrome and got
    // skipped, so this is meant to catch the eye before the user reaches for Google.
    // Scaled through `UIFontMetrics` so it still honours Dynamic Type.
    let noticeBase = UIFont.systemFont(
      ofSize: UIFont.preferredFont(forTextStyle: .subheadline).pointSize, weight: .semibold)
    notice.font = UIFontMetrics(forTextStyle: .subheadline).scaledFont(for: noticeBase)
    notice.adjustsFontForContentSizeCategory = true
    // A fixed dark ink, not `.label`: on a yellow strip `.label` would turn white in
    // dark mode and wash out. Dark-on-yellow stays legible in either appearance.
    notice.textColor = UIColor(white: 0.12, alpha: 1.0)
    notice.translatesAutoresizingMaskIntoConstraints = false

    // A UILabel has no padding, so inset it inside a tinted strip.
    let noticeBar = UIView()
    noticeBar.backgroundColor = .systemYellow
    noticeBar.translatesAutoresizingMaskIntoConstraints = false
    noticeBar.addSubview(notice)

    vc.view.addSubview(bar)
    vc.view.addSubview(noticeBar)
    vc.view.addSubview(webView)
    NSLayoutConstraint.activate([
      bar.topAnchor.constraint(equalTo: vc.view.safeAreaLayoutGuide.topAnchor),
      bar.leadingAnchor.constraint(equalTo: vc.view.leadingAnchor),
      bar.trailingAnchor.constraint(equalTo: vc.view.trailingAnchor),

      noticeBar.topAnchor.constraint(equalTo: bar.bottomAnchor),
      noticeBar.leadingAnchor.constraint(equalTo: vc.view.leadingAnchor),
      noticeBar.trailingAnchor.constraint(equalTo: vc.view.trailingAnchor),
      notice.topAnchor.constraint(equalTo: noticeBar.topAnchor, constant: 10),
      notice.bottomAnchor.constraint(equalTo: noticeBar.bottomAnchor, constant: -10),
      notice.leadingAnchor.constraint(equalTo: noticeBar.leadingAnchor, constant: 16),
      notice.trailingAnchor.constraint(equalTo: noticeBar.trailingAnchor, constant: -16),

      webView.topAnchor.constraint(equalTo: noticeBar.bottomAnchor),
      webView.leadingAnchor.constraint(equalTo: vc.view.leadingAnchor),
      webView.trailingAnchor.constraint(equalTo: vc.view.trailingAnchor),
      webView.bottomAnchor.constraint(equalTo: vc.view.bottomAnchor),
    ])

    vc.modalPresentationStyle = .fullScreen
    vc.isModalInPresentation = true
    self.controller = vc

    webView.load(URLRequest(url: Self.loginURL))
    topViewController()?.present(vc, animated: true)

    // The write can land after the last navigation's probe, so keep probing while the
    // view is up. `finish` invalidates this on success, cancel or the Dart timeout.
    harvestTimer = Timer.scheduledTimer(withTimeInterval: 1.0, repeats: true) { [weak self] _ in
      self?.webView?.evaluateJavaScript(Self.harvestScript, completionHandler: nil)
    }
  }

  @objc private func cancelTapped() {
    finish(with: nil)
  }

  // Login completes on a later navigation, not the first load. Probe the session
  // store after each one; it stays absent until Firebase has written it.
  func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
    webView.evaluateJavaScript(Self.harvestScript, completionHandler: nil)
  }

  func userContentController(
    _ userContentController: WKUserContentController, didReceive message: WKScriptMessage
  ) {
    // Script handlers are exposed to every frame and origin in the webview. Only our
    // own probe, running in the Gather main frame, may hand back a session — otherwise
    // an off-origin iframe reached during login could inject its own credentials.
    guard message.frameInfo.isMainFrame,
          message.frameInfo.securityOrigin.host.hasSuffix("gather.town")
    else {
      return
    }
    guard message.name == Self.messageName,
          let body = message.body as? [String: Any],
          let refreshToken = body["refreshToken"] as? String,
          !refreshToken.isEmpty
    else {
      return // not ready yet; a later navigation's probe will carry it
    }
    var payload: [String: Any] = ["refreshToken": refreshToken]
    if let uid = body["uid"] as? String { payload["uid"] = uid }
    finish(with: payload)
  }

  /// Resolves the pending Flutter call once and tears the webview down. Null is a
  /// user cancel — Dart maps it to silence.
  private func finish(with payload: [String: Any]?) {
    guard let result = self.result else { return }
    self.result = nil
    harvestTimer?.invalidate()
    harvestTimer = nil
    webView?.configuration.userContentController
      .removeScriptMessageHandler(forName: Self.messageName)
    controller?.dismiss(animated: true)
    controller = nil
    webView = nil
    if let payload = payload {
      result(payload)
    } else {
      result(FlutterError(code: "cancelled", message: "User cancelled", details: nil))
    }
  }

  private func topViewController() -> UIViewController? {
    let scene = UIApplication.shared.connectedScenes
      .compactMap { $0 as? UIWindowScene }
      .first { $0.activationState == .foregroundActive }
    var top = scene?.windows.first { $0.isKeyWindow }?.rootViewController
    while let presented = top?.presentedViewController { top = presented }
    return top
  }

  /// Reads the Firebase session out of the page's own IndexedDB and posts it back.
  /// The web SDK stores one record per signed-in user in `firebaseLocalStorage`,
  /// keyed `firebase:authUser:<apiKey>:[DEFAULT]`, whose `value` carries
  /// `stsTokenManager.refreshToken` and `uid`. Absent until the user has logged in.
  private static let harvestScript = """
  (function () {
    try {
      var open = indexedDB.open('firebaseLocalStorageDb');
      open.onsuccess = function () {
        var db = open.result;
        if (!db.objectStoreNames.contains('firebaseLocalStorage')) return;
        var tx = db.transaction('firebaseLocalStorage', 'readonly');
        var req = tx.objectStore('firebaseLocalStorage').getAll();
        req.onsuccess = function () {
          var rows = req.result || [];
          for (var i = 0; i < rows.length; i++) {
            var row = rows[i];
            var key = row && row.fbase_key;
            if (typeof key === 'string' && key.indexOf('\(authUserKeyNeedle)') === 0) {
              var v = row.value || {};
              // Gather bootstraps a throwaway session to *request* the code — and,
              // measured against the live service 2026-10-28, it is NOT flagged
              // `isAnonymous` (both the throwaway and the real user read false). The
              // one field that separates them is `email`: the pre-OTP throwaway has
              // `email: null`; the real user, once the code is verified (or any
              // provider sign-in completes), carries the account's address. So the
              // refresh-token-bearing record alone is not enough — harvesting it tore
              // the webview down on the throwaway before the user ever finished the
              // code, adopting a spaceless identity. Require an email, and keep
              // probing until the real record lands. (`isAnonymous` kept as a cheap
              // extra guard for any future provider that does use it.)
              if (v.isAnonymous === true) continue;
              var email = typeof v.email === 'string' ? v.email : '';
              if (!email) continue;
              var tm = v.stsTokenManager || {};
              if (tm.refreshToken) {
                window.webkit.messageHandlers.\(messageName).postMessage({
                  refreshToken: tm.refreshToken,
                  uid: v.uid || null
                });
                return;
              }
            }
          }
        };
      };
    } catch (e) { /* not ready; a later navigation retries */ }
  })();
  """
}
