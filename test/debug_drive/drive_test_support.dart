/// Shared fixtures for the debug-drive suites: a registrar that records instead
/// of reaching the VM, response decoders, and a catcher for
/// `FlutterError.reportError` so "it was reported" is an assertion rather than
/// console noise.
library;

import 'dart:convert';
import 'dart:developer';

import 'package:flutter/foundation.dart';
import 'package:flutter_test/flutter_test.dart';

/// Records every `registerExtension` the drive makes, in order.
class RecordingRegistrar {
  final methods = <String>[];
  final handlers = <String, ServiceExtensionHandler>{};

  void call(String method, ServiceExtensionHandler handler) {
    methods.add(method);
    handlers[method] = handler;
  }
}

/// The JSON body of a successful response, failing the test on an RPC error.
Map<String, Object?> resultOf(ServiceExtensionResponse response) {
  expect(response.isError(), isFalse, reason: 'expected a result, got ${response.errorCode}: ${response.errorDetail}');
  return (jsonDecode(response.result!) as Map).cast<String, Object?>();
}

/// The code and decoded detail of an error response, failing on a result.
({int code, Map<String, Object?> detail}) errorOf(ServiceExtensionResponse response) {
  expect(response.isError(), isTrue, reason: 'expected an error, got ${response.result}');
  return (
    code: response.errorCode!,
    detail: (jsonDecode(response.errorDetail!) as Map).cast<String, Object?>(),
  );
}

/// Captures every `FlutterError.reportError` for the rest of the test.
List<FlutterErrorDetails> captureFlutterErrors() {
  final seen = <FlutterErrorDetails>[];
  final previous = FlutterError.onError;
  FlutterError.onError = seen.add;
  addTearDown(() => FlutterError.onError = previous);
  return seen;
}
