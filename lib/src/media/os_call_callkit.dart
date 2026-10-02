/// The Dart half of the CallKit bridge. The Swift half is
/// `ios/Runner/CallKitController.swift`.
///
/// A deliberately thin [MethodChannel] rather than a plugin. The CallKit plugins
/// on pub are built around PushKit *incoming*-call delivery — a server pushes,
/// the phone rings — which this app does not do: a Gather call is app-initiated
/// off a socket we already hold. They also pull in CocoaPods, and this project is
/// SPM-only on purpose (`flutter_webrtc` is pinned precisely to stay off it). So
/// the bridge is a handful of methods written by hand, and no dependency.
///
/// The channel is two-way: Dart asks the OS to start, end and mute a call, and
/// the OS asks back — the End and mute buttons on the lock screen come in as
/// method calls the other direction.
library;

import 'dart:async';

import 'package:flutter/services.dart';

import 'media_engine.dart';
import 'os_call.dart';

/// Talks to `CallKitController` over `gather/os_call`. iOS only — built by
/// [defaultOsCall], never directly, so nothing drags a platform channel onto a
/// platform that has no handler for it.
class IosCallKit implements OsCall {
  IosCallKit({void Function(String)? log}) : _log = log ?? _noop {
    _channel.setMethodCallHandler(_onNativeCall);
  }

  static void _noop(String _) {}

  final void Function(String) _log;

  static const _channel = MethodChannel('gather/os_call');

  final _endRequested = StreamController<void>.broadcast();
  final _muteRequested = StreamController<bool>.broadcast();
  final _routeChanged = StreamController<AudioOutput>.broadcast();

  @override
  Stream<void> get onEndRequested => _endRequested.stream;

  @override
  Stream<bool> get onMuteRequested => _muteRequested.stream;

  @override
  Stream<AudioOutput> get onRouteChanged => _routeChanged.stream;

  @override
  Future<void> reportStarted({required String handle, required String id}) =>
      _invoke('reportStarted', {'handle': handle, 'id': id});

  @override
  Future<void> reportEnded() => _invoke('reportEnded');

  @override
  Future<void> reportMuted(bool muted) =>
      _invoke('reportMuted', {'muted': muted});

  @override
  bool get managesAudioRoute => true;

  @override
  Future<void> setSpeaker(bool on) => _invoke('setSpeaker', {'on': on});

  /// Swallows channel failures the way the media engine swallows route failures:
  /// a call that could not be reported to the OS should degrade to a call the OS
  /// does not know about, not a crash. The call itself is already running.
  Future<void> _invoke(String method, [Map<String, Object?>? args]) async {
    try {
      await _channel.invokeMethod<void>(method, args);
    } on Object catch (error) {
      _log('os_call: $method failed: $error');
    }
  }

  /// The OS asking us to do something — the lock-screen End and mute buttons.
  Future<void> _onNativeCall(MethodCall call) async {
    switch (call.method) {
      case 'endRequested':
        _endRequested.add(null);
      case 'muteRequested':
        final muted = (call.arguments as Map?)?['muted'] as bool? ?? false;
        _muteRequested.add(muted);
      case 'routeChanged':
        final route = (call.arguments as Map?)?['route'] as String?;
        final output = _routeFrom(route);
        if (output != null) _routeChanged.add(output);
      default:
        _log('os_call: ignoring unknown native call ${call.method}');
    }
  }

  /// The native route string → the four outputs the UI draws. An unknown string
  /// is dropped rather than guessed at — a route we cannot name is better left
  /// showing the last one we could than flipped to a wrong glyph.
  static AudioOutput? _routeFrom(String? route) => switch (route) {
        'speaker' => AudioOutput.speaker,
        'earpiece' => AudioOutput.earpiece,
        'bluetooth' => AudioOutput.bluetooth,
        'wired' => AudioOutput.wired,
        _ => null,
      };

  @override
  Future<void> dispose() async {
    _channel.setMethodCallHandler(null);
    await _endRequested.close();
    await _muteRequested.close();
    await _routeChanged.close();
  }
}
