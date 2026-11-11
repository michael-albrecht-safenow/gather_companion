// tool/release_artifact_check.sh, the guard CI runs on the release Dart binary
// before TestFlight and before the APKs are kept. A regression in it — dropping
// `LC_ALL=C`, `-a` or `-F`, inverting the control check — does not fail loudly:
// it shows up as a release that silently passes. So its verdicts are pinned here
// against fake binaries, with NUL and high bytes around the strings so the grep
// has to treat the file as binary the way it must on a real `App.framework/App`.
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

const _script = 'tool/release_artifact_check.sh';
const _control = 'Pair with your computer';

void main() {
  late Directory dir;
  setUp(() => dir = Directory.systemTemp.createTempSync('release_check_'));
  tearDown(() => dir.deleteSync(recursive: true));

  String binary(String name, String text) {
    final f = File('${dir.path}/$name')..writeAsBytesSync([0, 0xff, 0xfe, 0x7f, ...text.codeUnits, 0, 0xc3, 0x28, 0]);
    return f.path;
  }

  Future<ProcessResult> run(List<String> paths) => Process.run('bash', [_script, ...paths]);

  test('a clean binary carrying the control passes', () async {
    final r = await run([binary('clean', 'xx $_control yy')]);
    expect(r.exitCode, 0, reason: '${r.stderr}');
  });

  test('a binary carrying an ext.gc. method name fails', () async {
    final r = await run([binary('drive', '$_control ext.gc.state.dump')]);
    expect(r.exitCode, 1);
    expect('${r.stderr}', contains('ext.gc.state.dump'));
  });

  test('a binary without the control fails as proving nothing', () async {
    final r = await run([binary('nocontrol', 'nothing to see')]);
    expect(r.exitCode, 1);
    expect('${r.stderr}', contains('control'));
  });

  test('one bad binary among clean ones fails the whole run', () async {
    final r = await run([binary('a', _control), binary('b', '$_control ext.gc.op.result')]);
    expect(r.exitCode, 1);
  });

  test('a missing file fails', () async {
    final r = await run(['${dir.path}/absent']);
    expect(r.exitCode, 1);
  });

  test('no arguments is a usage error', () async {
    final r = await run([]);
    expect(r.exitCode, 64);
  });
}
