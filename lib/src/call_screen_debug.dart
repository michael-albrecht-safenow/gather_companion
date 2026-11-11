/// The debug drive's door to the call screen: the same push the "In a call with …"
/// banner makes, and the pop back to the office.
///
/// `call.spotlight` reads the call screen's own controller, so with a call up and
/// the screen closed it can only answer `call_screen_closed` — and before this the
/// one way to open the screen was to tap the banner by coordinate. The banner's
/// `onTap` is `openCallScreen(context, state)`, which needs a `BuildContext` under
/// the app's navigator; the drive has none. So `HomeShell`, which is always
/// mounted under that navigator while the banner can exist, lends the drive a
/// [CallScreenDebug] whose [CallScreenDebug.open] is that exact call.
///
/// [callScreenDebugActive] is written by `HomeShell` only under `kDebugMode` (set
/// on mount, cleared on dispose if still its own), so release never writes it and
/// the drive's reader shakes out with the drive.
library;

/// What the mounted shell lends the drive. Local navigation only: opening or
/// closing the faces changes what this phone shows, nothing on the wire.
class CallScreenDebug {
  const CallScreenDebug({required this.open, required this.close});

  /// Push the call screen, exactly as the banner does. Does not wait for the
  /// route — that future completes when the screen is popped.
  final void Function() open;

  /// Pop the call screen (and anything stacked on it) back to the office.
  /// False when no call-screen route was found to pop.
  final bool Function() close;
}

/// The shell on display, for the debug drive. See the file header.
CallScreenDebug? callScreenDebugActive;
