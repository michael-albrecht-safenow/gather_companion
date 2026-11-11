/// `bin/e2e_bot.dart`'s argument and stdin-line parsing — offline, no stack.
///
/// The parsing is the bot's whole contract with the simulator suite, which
/// scripts it line by line; a word it misreads is a sim test that silently
/// drives the wrong thing. The live half is `test/e2e/bot_peer_test.dart`.
library;

import 'package:test/test.dart';

import '../bin/e2e_bot.dart'
    show
        BotUsageException,
        JoinCommand,
        LoginCommand,
        MoveCommand,
        QuitCommand,
        RosterCommand,
        ServeCommand,
        WalkCommand,
        WaveCommand,
        parseBotArgs,
        parseBotLine;

const _env = {
  'BETHER_E2E_URL': 'http://127.0.0.1:13000',
  'BETHER_E2E_SPACE_ID': 'space-seeded',
  'BETHER_E2E_BOB_EMAIL': 'bob@e2e.bether.test',
  'BETHER_E2E_BOB_PASSWORD': 'e2e-password-123',
};

Matcher _usage(Object message) => throwsA(
  isA<BotUsageException>().having((e) => e.message, 'message', message),
);

void main() {
  group('parseBotArgs', () {
    test('defaults the backend from the environment and signs up fresh', () {
      final o = parseBotArgs(['login'], _env);
      expect(o.url, Uri.parse('http://127.0.0.1:13000'));
      expect(o.command, isA<LoginCommand>());
      expect(o.email, isNull, reason: 'no --as/--email: a fresh OTP account');
      expect(o.password, isNull);
      expect(o.spaceId, isNull);
    });

    test('--as takes the seeded credentials and the seeded space', () {
      final o = parseBotArgs(['--as', 'Bob', 'serve'], _env);
      expect(o.email, 'bob@e2e.bether.test');
      expect(o.password, 'e2e-password-123');
      expect(o.spaceId, 'space-seeded');
      expect(o.command, isA<ServeCommand>());
    });

    test('explicit flags win and trailing slashes are dropped', () {
      final o = parseBotArgs([
        '--url',
        'http://h:1/',
        '--email',
        'x@y.z',
        '--password',
        'pw',
        '--register',
        '--space',
        's1',
        'roster',
      ], _env);
      expect(o.url, Uri.parse('http://h:1'));
      expect(o.email, 'x@y.z');
      expect(o.password, 'pw');
      expect(o.register, isTrue);
      expect(o.spaceId, 's1');
      expect(o.command, isA<RosterCommand>());
    });

    test('commands and their arguments', () {
      expect(
        (parseBotArgs(['join', 'abc'], _env).command as JoinCommand).spaceId,
        'abc',
      );
      final move =
          parseBotArgs(['move', '6', '-1'], _env).command as MoveCommand;
      expect(
        (move.x, move.y),
        (6, -1),
        reason: 'a negative after the verb is an argument, not a flag',
      );
      final walk =
          parseBotArgs(['walk', 'left', '3'], _env).command as WalkCommand;
      expect(
        (walk.direction, walk.steps),
        ('Left', 3),
        reason: 'the wire wants Gather\'s capitalisation',
      );
      expect(
        (parseBotArgs(['walk', 'Up'], _env).command as WalkCommand).steps,
        1,
      );
      expect(
        (parseBotArgs(['wave', 'su-1'], _env).command as WaveCommand).target,
        'su-1',
      );
    });

    test('refuses what it cannot run, with a reason', () {
      expect(
        () => parseBotArgs(['login'], const {}),
        _usage(contains('no backend')),
      );
      expect(
        () => parseBotArgs(['--url', 'not a url', 'login'], const {}),
        _usage(contains('not an http')),
      );
      expect(() => parseBotArgs([], _env), _usage('no command'));
      expect(
        () => parseBotArgs(['--bogus', 'login'], _env),
        _usage('unknown option --bogus'),
      );
      expect(
        () => parseBotArgs(['--email'], _env),
        _usage('--email needs a value'),
      );
      expect(
        () => parseBotArgs(['--as', 'carol', 'login'], _env),
        _usage(contains('no seeded account "carol"')),
      );
      expect(
        () => parseBotArgs(['--as', 'bob', '--email', 'a@b.c', 'login'], _env),
        _usage(contains('exclusive')),
      );
      expect(
        () => parseBotArgs(['--register', 'login'], _env),
        _usage('--register needs --password'),
      );
      expect(
        () => parseBotArgs(['fly'], _env),
        _usage('unknown command "fly"'),
      );
      expect(
        () => parseBotArgs(['move', '1'], _env),
        _usage(contains('takes 2 arguments, got 1')),
      );
      expect(
        () => parseBotArgs(['move', '1', 'y'], _env),
        _usage('y must be an integer, got "y"'),
      );
      expect(
        () => parseBotArgs(['walk', 'north'], _env),
        _usage(contains('one of Up, Down, Left, Right')),
      );
      expect(
        () => parseBotArgs(['walk', 'Up', '0'], _env),
        _usage(contains('at least 1')),
      );
      expect(
        () => parseBotArgs(['quit'], _env),
        _usage(contains('unknown command')),
        reason: 'quit only means something inside serve',
      );
      expect(() => parseBotArgs(['-h'], _env), _usage('help'));
    });
  });

  group('parseBotLine (serve)', () {
    test('the same verbs, whitespace-tolerant', () {
      expect((parseBotLine('  move   3 4 ') as MoveCommand).x, 3);
      expect(parseBotLine('roster'), isA<RosterCommand>());
      expect(parseBotLine('quit'), isA<QuitCommand>());
      expect(parseBotLine('exit'), isA<QuitCommand>());
    });

    test('blank lines and comments are nothing', () {
      expect(parseBotLine(''), isNull);
      expect(parseBotLine('   '), isNull);
      expect(parseBotLine('# step two'), isNull);
    });

    test('process-level commands are not lines', () {
      expect(() => parseBotLine('serve'), _usage(contains('unknown command')));
      expect(() => parseBotLine('login'), _usage(contains('unknown command')));
      expect(
        () => parseBotLine('wave'),
        _usage(contains('takes 1 argument, got 0')),
      );
    });
  });
}
