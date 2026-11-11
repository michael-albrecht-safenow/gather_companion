/// `bin/e2e_bot.dart serve` as the simulator suite will use it: a separate
/// process, scripted line by line on stdin, watched by a real collector.
///
/// The bot is the sim suite's second person, so a regression in it would show
/// up there as an app bug. This pins the part the sim relies on — the
/// one-JSON-reply-per-line protocol and that its moves and waves land.
///
/// The budget is above the 90 s allowed for the bot's first `ready` (which
/// includes compiling it via `dart run`), so a slow compile fails on that wait's
/// own message instead of a bare "test timed out".
@Tags(['e2e'])
@Timeout(Duration(minutes: 4))
@TestOn('vm')
library;

import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:gather_client/gather_client.dart';
import 'package:test/test.dart';

import 'harness.dart';
import 'suite.dart';

void main() {
  group('bether E2E: bot peer', skip: e2eSkip(), () {
    late E2eEnv env;
    late BackendConfig config;
    final sockets = Sockets();
    Process? bot;

    setUpAll(() async {
      env = e2eEnv!;
      config = await discover(env.base);
    });

    tearDown(() async {
      bot?.kill();
      await bot?.exitCode.timeout(
        const Duration(seconds: 10),
        onTimeout: () => -1,
      );
      bot = null;
      await sockets.closeAll();
    });

    test(
      'serve: join, move, walk, wave, roster, quit — each answered on stdout',
      () async {
        final watcher = await signUp(env, config, 'botwatch');
        final spaceId = await watcher.rest.createSpace('Bot ${randomTag()}');
        final w = sockets.start(watcher, spaceId: spaceId, label: 'watcher');
        final watcherId = (await connected(w)).selfId!;

        // `dart run` from the package root, so the bot resolves this package.
        final process = bot = await Process.start(
          Platform.resolvedExecutable,
          [
            'run',
            'bin/e2e_bot.dart',
            '--register',
            '--email',
            uniqueEmail('bot'),
            '--password',
            'pw-${randomTag(8)}',
            'serve',
          ],
          environment: {'BETHER_E2E_URL': env.base.toString()},
        );
        final stderrLines = <String>[];
        process.stderr
            .transform(utf8.decoder)
            .transform(const LineSplitter())
            .listen(stderrLines.add);
        addTearDown(
          () => printOnFailure('bot stderr:\n${stderrLines.join('\n')}'),
        );
        final replies = StreamIterator(
          process.stdout
              .transform(utf8.decoder)
              .transform(const LineSplitter())
              .map((line) => (jsonDecode(line) as Map).cast<String, Object?>()),
        );

        // One reply per line, in order. Generous: the first includes compiling the bot.
        Future<Map<String, Object?>> reply(
          String cmd, {
          Duration timeout = const Duration(seconds: 20),
        }) async {
          final more = await replies.moveNext().timeout(timeout);
          expect(more, isTrue, reason: 'bot exited before answering $cmd');
          final r = replies.current;
          expect(r['cmd'], cmd);
          expect(r['ok'], isTrue, reason: 'bot answered $r');
          return r;
        }

        void send(String line) => process.stdin.writeln(line);

        final ready = await reply(
          'serve',
          timeout: const Duration(seconds: 90),
        );
        expect(ready['event'], 'ready');

        send('join $spaceId');
        final joined = await reply('join');
        final botId = joined['spaceUserId']! as String;
        expect(joined['selfId'], botId);
        await sees(w, botId);

        send('move 10 8');
        expect(await reply('move'), containsPair('x', 10));
        await sees(w, botId, x: 10, y: 8);

        send('walk right 2');
        final walked = await reply('walk');
        expect([walked['x'], walked['y'], walked['blocked']], [12, 8, false]);
        await sees(w, botId, x: 12, y: 8);

        // Into the border wall (x = 0 on the demo map): stops, says so.
        send('move 2 8');
        await reply('move');
        send('walk Left 5');
        final blocked = await reply('walk');
        expect(
          [blocked['x'], blocked['steps'], blocked['blocked']],
          [1, 1, true],
        );

        final waved = w.interactions
            .firstWhere((e) => e.name == 'WaveEvent' && e.isFor(watcherId))
            .timeout(const Duration(seconds: 10));
        send('wave $watcherId');
        await reply('wave');
        expect((await waved).senderId, botId);

        send('roster');
        final roster = await reply('roster');
        expect(
          (roster['rows']! as List).map((r) => (r as Map)['id']),
          containsAll([botId, watcherId]),
        );

        // A bad line is answered, not fatal.
        send('fly away');
        expect(await replies.moveNext(), isTrue);
        expect(replies.current['ok'], isFalse);

        send('quit');
        await reply('quit');
        expect(await process.exitCode.timeout(const Duration(seconds: 10)), 0);
        bot = null;
      },
    );
  });
}
