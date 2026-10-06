import 'package:shared_preferences/shared_preferences.dart';

/// The handful of look-and-feel switches that are the app's own, kept in
/// [SharedPreferences] rather than the keychain.
///
/// The pairing records live in the keychain because they have to *survive* a
/// reinstall (see [BridgeSettingsStore]); a preference about how the office is
/// drawn is the opposite — it is cheap to lose, carries nothing dangerous, and
/// is read on the hot path at boot, so plain preferences are exactly right.
///
/// Every call is wrapped: a simulator with no preferences plugin, or a platform
/// that fails the channel, should fall back to the default look rather than take
/// the app down on launch.
class UiPreferences {
  // ignore: prefer_initializing_formals
  UiPreferences({SharedPreferences? prefs}) : _prefs = prefs;

  /// Cached after the first touch so repeated reads do not re-enter the plugin.
  SharedPreferences? _prefs;

  static const _gameboyKey = 'ui.gameboyMode';

  Future<SharedPreferences?> _store() async {
    if (_prefs != null) return _prefs;
    try {
      return _prefs = await SharedPreferences.getInstance();
    } on Object {
      return null;
    }
  }

  /// Whether the office tab wears the retro handheld shell. Off by default: the
  /// normal interface is what somebody who has never heard of the mode should
  /// see first.
  Future<bool> loadGameboyMode() async {
    try {
      return (await _store())?.getBool(_gameboyKey) ?? false;
    } on Object {
      return false;
    }
  }

  Future<void> saveGameboyMode(bool on) async {
    try {
      await (await _store())?.setBool(_gameboyKey, on);
    } on Object {
      /* nothing useful to do; the next toggle writes it again */
    }
  }
}
