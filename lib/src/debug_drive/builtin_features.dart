/// The two features every drive carries: `drive` (what does this build expose)
/// and `op` (how did that long action end).
///
/// `drive.list` is the first call an agent should make. Actions differ between
/// builds and between entrypoints — the harness will carry levers the live app
/// does not — and guessing a name produces an "unknown method" that reads like a
/// broken channel. The list also says which actions are `outward` and whether
/// this is the harness or the live wire, so an agent knows before it acts
/// whether anyone else would see it, and never mistakes a scripted result for a
/// real one.
library;

import 'debug_drive.dart';
import 'drive_ops.dart';
import 'drive_result.dart';

/// `ext.gc.drive.list` → `{actions: [{name, outward}], boot}`.
DriveFeature driveFeature(DebugDrive drive) => DriveFeature('drive', [
      DriveAction('list', (_) async => DriveResult.ok({
            'actions': [
              for (final a in drive.actions) {'name': a.name, 'outward': a.outward},
            ],
            'boot': drive.boot,
          })),
    ]);

/// `ext.gc.op.status {id}` and `ext.gc.op.result {id}`.
DriveFeature opFeature(DriveOps ops) => DriveFeature('op', [
      DriveAction('status', (args) async => DriveResult.ok(ops.status(args.requireString('id')))),
      DriveAction('result', (args) async => DriveResult.ok(ops.result(args.requireString('id')))),
    ]);
